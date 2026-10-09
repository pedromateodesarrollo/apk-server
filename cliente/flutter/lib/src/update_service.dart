import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// `instalando` = Android ya está instalando sin preguntar: la app se va a
/// cerrar sola en unos segundos.
enum UpdateFase { idle, verificando, descargando, listo, instalando, error }

/// Lo que se le dice a la persona antes de instalar. La app NO vuelve a
/// abrirse sola: Android no deja abrir una pantalla desde el aviso de que
/// terminó de instalar (probado en Android 15), así que hay que decírselo.
const kUpdateTextoListo =
    'Al instalar, la app se cierra. Ábrela de nuevo y ya estará en la versión '
    'nueva.';

/// Las esperas por defecto entre un corte de la descarga y el siguiente
/// intento ([UpdateService.esperasReintento]).
const kUpdateEsperasReintento = [
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
];

/// Mientras Android instala sin preguntar.
const kUpdateTextoInstalando =
    'La app se va a cerrar sola en unos segundos. Ábrela de nuevo y ya estará '
    'en la versión nueva.';

@immutable
class UpdateEstado {
  final UpdateFase fase;
  final double progreso; // 0..1
  final String? version;
  final int build;
  final bool requerido;
  final String? apkPath;
  final String? error;

  /// Con [UpdateFase.listo], por qué no se instala sin preguntar: `permiso`
  /// (falta «Permitir de esta fuente»), `confirmar` (Android pidió que
  /// alguien confirme) o null.
  final String? falta;

  const UpdateEstado({
    this.fase = UpdateFase.idle,
    this.progreso = 0,
    this.version,
    this.build = 0,
    this.requerido = false,
    this.apkPath,
    this.error,
    this.falta,
  });

  /// Desde lo que manda la biblioteca de Android. `esperando_wifi` se enseña
  /// como reposo: no hay nada que la persona tenga que hacer.
  factory UpdateEstado.deMapa(Map<Object?, Object?> m) {
    final fase = switch (m['fase']) {
      'verificando' => UpdateFase.verificando,
      'descargando' => UpdateFase.descargando,
      'listo' => UpdateFase.listo,
      'instalando' => UpdateFase.instalando,
      'error' => UpdateFase.error,
      _ => UpdateFase.idle,
    };
    return UpdateEstado(
      fase: fase,
      progreso: (m['progreso'] as num?)?.toDouble() ?? 0,
      version: m['version'] as String?,
      build: (m['build'] as num?)?.toInt() ?? 0,
      requerido: m['requerido'] == true,
      apkPath: m['apk'] as String?,
      error: m['error'] as String?,
      falta: m['falta'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateEstado &&
      other.fase == fase &&
      other.progreso == progreso &&
      other.version == version &&
      other.build == build &&
      other.requerido == requerido &&
      other.apkPath == apkPath &&
      other.error == error &&
      other.falta == falta;

  @override
  int get hashCode => Object.hash(fase, progreso, version, build, requerido, apkPath, error, falta);

  @override
  String toString() => 'UpdateEstado(${fase.name}${version != null ? ' $version' : ''})';
}

/// Auto-actualización de una app Flutter con apk-server.
///
/// Todo lo hace la biblioteca de Android del paquete (`cliente/android`):
/// pregunta al hub (ya, cada hora y cuando avisa por WebSocket), baja el APK
/// en segundo plano —sigue con la pantalla apagada y retoma lo cortado—, saca
/// una notificación cuando está lista y la instala sin diálogo en Android 12+
/// si la persona ya le dio «Permitir de esta fuente» a la app. Esto es el
/// puente: dice cuándo y enseña el estado en [estado].
///
/// El hub y el slug de la app salen del manifiesto, que los pone la app en su
/// `android/app/build.gradle.kts`:
///
/// ```kotlin
/// manifestPlaceholders["apkServerHub"] = "https://apk.ejemplo.com"
/// manifestPlaceholders["apkServerApp"] = "inventario"
/// ```
///
/// El mismo dato le dice a `dart run apk_server_flutter:publicar` a dónde
/// subir el APK. [servidor] y [app] lo pisan, pero no hace falta.
///
/// Lo único que la app controla es el MOMENTO de instalar, con [autoInstalar]
/// y [puedeInstalar]: la instalación sin preguntar CIERRA la app al momento,
/// así que a mitad de una tarea no puede pasar.
///
/// En otra plataforma que no es Android no hace nada: [estado] se queda en
/// reposo.
class UpdateService {
  UpdateService({
    this.servidor,
    this.app,
    this.contexto,
    this.autoInstalar = false,
    this.puedeInstalar,
    this.avisos = true,
    this.minEntreChequeos = const Duration(minutes: 5),
    this.intervaloSondeo = const Duration(hours: 1),
    this.esperasReintento = kUpdateEsperasReintento,
  }) {
    _activo = this;
  }

  /// El hub. Null = el del manifiesto (lo normal).
  final String? servidor;

  /// El slug de la app en el hub. Null = el del manifiesto (lo normal).
  final String? app;

  /// Lo que la app quiera contar en cada consulta (empresa, usuario con
  /// sesión, almacén…). Lo ve quien administra el hub. Se pide en cada
  /// consulta; si la app está cerrada, va lo último que contó.
  final Map<String, Object?> Function()? contexto;

  /// Si `true`, al terminar la descarga instala sola. En Android 12+ con
  /// «Permitir de esta fuente» eso es SIN PREGUNTAR: la app se cierra (y no se
  /// vuelve a abrir sola). Si Android pide confirmar, abre su diálogo, pero
  /// solo con la app al frente. Una vez por versión y por proceso.
  final bool autoInstalar;

  /// Con [autoInstalar], además tiene que devolver `true` en el momento de
  /// instalar. Si devuelve `false` el APK queda listo y esperando a que la app
  /// llame [instalarSiListo].
  final bool Function()? puedeInstalar;

  /// Abrir el WebSocket del hub en [iniciar]. Con él, una versión publicada
  /// llega al instante y el panel ve el equipo conectado.
  final bool avisos;

  final Duration minEntreChequeos;
  final Duration intervaloSondeo;

  /// Cuánto se espera para volver a intentar una descarga que se cortó: la
  /// primera espera tras el primer corte… y la última, de ahí en adelante.
  final List<Duration> esperasReintento;

  final estado = ValueNotifier<UpdateEstado>(const UpdateEstado());

  /// El hub y el slug con que quedó (los del manifiesto si no se dieron). Null
  /// hasta [iniciar], o si no es Android.
  String? get hub => _hub;
  String? get appId => _appId;

  /// La página para instalar la app en un equipo nuevo (`<hub>/i/<app>`).
  String? get urlInstalar => _urlInstalar;

  /// La clave de esta instalación (la del panel, en Equipos).
  String? get instalacion => _instalacion;

  String? _hub, _appId, _urlInstalar, _instalacion;

  static const _canal = MethodChannel('apk_server');

  /// El que recibe lo que manda Android. Una app tiene uno.
  static UpdateService? _activo;

  Future<bool>? _preparando;

  /// Última versión para la que ya se lanzó el instalador en este proceso.
  int? _autoLanzada;
  bool _instalando = false;

  /// Le pasa los ajustes a la biblioteca. Una vez; devuelve false si no es
  /// Android (o el plugin no está).
  Future<bool> _prepara() => _preparando ??= () async {
        _canal.setMethodCallHandler(_alLlamar);
        try {
          final r = await _canal.invokeMapMethod<String, Object?>('configurar', {
            if (servidor != null) 'hub': servidor,
            if (app != null) 'app': app,
            'avisos': avisos,
            'intervaloMs': intervaloSondeo.inMilliseconds,
            'minEntreChequeosMs': minEntreChequeos.inMilliseconds,
            'esperasMs': [for (final d in esperasReintento) d.inMilliseconds],
          });
          if (r == null) return false;
          _hub = (r['hub'] as String?)?.nullSiVacio;
          _appId = (r['app'] as String?)?.nullSiVacio;
          _urlInstalar = r['urlInstalar'] as String?;
          _instalacion = r['instalacion'] as String?;
          final e = r['estado'];
          if (e is Map) _alEstado(UpdateEstado.deMapa(e));
          if (_hub == null || _appId == null) {
            debugPrint('apk_server: la app no dice de qué hub se actualiza: pon '
                'manifestPlaceholders["apkServerHub"] y ["apkServerApp"] en '
                'android/app/build.gradle.kts');
          }
          return true;
        } on MissingPluginException {
          return false; // no es Android
        } on PlatformException catch (e) {
          debugPrint('apk_server: $e');
          return false;
        }
      }();

  static Future<Object?> _alLlamar(MethodCall c) async {
    final s = _activo;
    if (s == null) return null;
    switch (c.method) {
      case 'estado':
        final m = c.arguments;
        if (m is Map) s._alEstado(UpdateEstado.deMapa(m));
        return null;
      case 'contexto':
        try {
          return s.contexto?.call();
        } catch (e) {
          debugPrint('apk_server: contexto: $e');
          return null;
        }
    }
    return null;
  }

  void _alEstado(UpdateEstado e) {
    final antes = estado.value;
    estado.value = e;
    // Recién lista: es el momento de [autoInstalar].
    if (e.fase == UpdateFase.listo && (antes.fase != UpdateFase.listo || antes.build != e.build)) {
      unawaited(instalarSiListo());
    }
  }

  Future<void> _llamar(String metodo, [Map<String, Object?>? args]) async {
    if (!await _prepara()) return;
    try {
      await _canal.invokeMethod<void>(metodo, args);
    } on PlatformException catch (e) {
      debugPrint('apk_server: $metodo: $e');
    }
  }

  /// Pregunta ya, cada hora y —con [avisos]— en cuanto el hub avise.
  Future<void> iniciar() => _llamar('iniciar');

  /// Para el sondeo, cierra el WebSocket y deja de reintentar.
  Future<void> detener() => _llamar('detener');

  /// Para colgarlo de «la app volvió al frente»: reconecta el WebSocket si
  /// estaba esperando y pregunta (con el freno de [minEntreChequeos]). Si
  /// había una descarga cortada, sigue ya.
  Future<void> alVolverAlFrente() => _llamar('alVolverAlFrente');

  /// Verifica y, si hay versión nueva, la baja en segundo plano. Vuelve
  /// cuando el hub contestó (la descarga sigue sola). Con freno; [forzar] lo
  /// salta, para el botón manual.
  Future<void> verificarYDescargar({bool forzar = false}) =>
      _llamar('verificar', {'forzar': forzar, 'manual': forzar});

  /// ¿Instalar ahora iría sin preguntar? Android 12+ y la persona con
  /// «Permitir de esta fuente» activado para la app.
  Future<bool> sinPreguntar() async {
    if (!await _prepara()) return false;
    try {
      return await _canal.invokeMethod<bool>('sinPreguntar') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Si hay un APK listo, [autoInstalar] está activo, [puedeInstalar] lo
  /// permite y aún no se lanzó para esa versión, instala. La app lo llama al
  /// llegar a la pantalla donde sí conviene interrumpir.
  ///
  /// Con la app detrás solo instala si va sin preguntar: el diálogo del
  /// sistema no se abre encima de otra app.
  Future<void> instalarSiListo() async {
    if (!autoInstalar) return;
    final e = estado.value;
    if (e.fase != UpdateFase.listo || e.apkPath == null) return;
    if (puedeInstalar != null && !puedeInstalar!()) return;
    if (e.build == _autoLanzada) return;
    final alFrente = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _autoLanzada = e.build;
    final lanzada = await _instalar(conDialogo: alFrente);
    if (!lanzada) _autoLanzada = null;
  }

  /// Instala el APK descargado: sin preguntar si Android lo deja (la app se
  /// cierra), si no con el diálogo del sistema. Es el botón: ignora
  /// [puedeInstalar] y el «una vez por versión».
  Future<void> instalar() async {
    await _instalar(conDialogo: true);
  }

  /// `true` si arrancó una instalación —sin preguntar o con el diálogo—.
  /// Reentrante: dos toques al botón no arman dos instalaciones.
  Future<bool> _instalar({required bool conDialogo}) async {
    if (estado.value.apkPath == null) return false;
    if (_instalando) return true;
    // La marca va antes del primer await: si no, el segundo toque pasa.
    _instalando = true;
    try {
      if (!await _prepara()) return false;
      final r = await _canal.invokeMapMethod<String, Object?>('instalar', {'conDialogo': conDialogo});
      final resultado = r?['resultado'] as String? ?? 'error';
      if (resultado == 'error') debugPrint('apk_server: la instalación falló');
      return const {'instalada', 'dialogo', 'sin_respuesta', 'en_curso'}.contains(resultado);
    } on PlatformException catch (e) {
      debugPrint('apk_server: $e');
      return false;
    } finally {
      _instalando = false;
    }
  }

  Future<void> dispose() async {
    if (identical(_activo, this)) {
      _activo = null;
      await detener();
    }
    estado.dispose();
  }
}

extension on String {
  String? get nullSiVacio => isEmpty ? null : this;
}
