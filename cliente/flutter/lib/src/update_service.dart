import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:apk_server/apk_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// `instalando` = Android ya está instalando sin preguntar: la app se va a
/// cerrar sola en unos segundos.
enum UpdateFase { idle, verificando, descargando, listo, instalando, error }

/// Lo que se le dice a la persona antes de instalar. La app NO vuelve a
/// abrirse sola: Android no deja abrir una pantalla desde el aviso de que
/// terminó de instalar (probado en Android 15), así que hay que decírselo.
const kUpdateTextoListo =
    'Al instalar, la app se cierra. Ábrela de nuevo y ya estará en la versión '
    'nueva.';

/// Mientras Android instala sin preguntar.
const kUpdateTextoInstalando =
    'La app se va a cerrar sola en unos segundos. Ábrela de nuevo y ya estará '
    'en la versión nueva.';

@immutable
class UpdateEstado {
  final UpdateFase fase;
  final double progreso; // 0..1
  final String? version;
  final bool requerido;
  final String? apkPath;
  final String? error;
  const UpdateEstado({
    this.fase = UpdateFase.idle,
    this.progreso = 0,
    this.version,
    this.requerido = false,
    this.apkPath,
    this.error,
  });

  UpdateEstado _conFase(UpdateFase fase) => UpdateEstado(
        fase: fase,
        progreso: progreso,
        version: version,
        requerido: requerido,
        apkPath: apkPath,
        error: error,
      );
}

/// Capa de plataforma: baja un paquete a disco y lo entrega al instalador de
/// Android. No sabe de dónde salió la URL ni quién decidió que había versión
/// nueva; por eso sirve igual con apk-server ([UpdateService]) que con
/// cualquier otra cosa que sepa dar una URL y un nombre de versión.
class UpdateInstalador {
  UpdateInstalador({
    required this.appId,
    Future<void> Function(String apk)? abrirDialogo,
  }) : _abrirDialogo = abrirDialogo ?? _abrirConOpenFilex;

  /// Prefijo del archivo en el temporal (`<appId>_<version>.apk`).
  final String appId;

  final estado = ValueNotifier<UpdateEstado>(const UpdateEstado());

  /// APK ya descargado en este proceso, con la versión a la que corresponde.
  /// Sobrevive a los resets de [estado], que es lo que antes hacía re-bajar el
  /// mismo APK una y otra vez.
  String? _apkListo;
  String? _apkListoVersion;

  Future<String>? _descargaEnCurso;

  /// Baja [url] como [version]. Si esa versión ya se bajó en este proceso y el
  /// archivo sigue ahí, la reusa. Reentrante: una segunda llamada mientras
  /// baja se acopla a la descarga en vuelo (dos a la vez escribían el mismo
  /// archivo y el progreso saltaba entre ambas).
  Future<String> descargar(
    String url, {
    required String version,
    bool requerido = false,
  }) {
    final enCurso = _descargaEnCurso;
    if (enCurso != null) return enCurso;
    final f = _descargar(url, version, requerido).whenComplete(() {
      _descargaEnCurso = null;
    });
    _descargaEnCurso = f;
    return f;
  }

  Future<String> _descargar(String url, String version, bool requerido) async {
    final previo = _apkListoVersion == version ? _apkListo : null;
    if (previo != null && await File(previo).exists()) {
      estado.value = UpdateEstado(
        fase: UpdateFase.listo,
        version: version,
        requerido: requerido,
        apkPath: previo,
      );
      return previo;
    }
    estado.value = UpdateEstado(
      fase: UpdateFase.descargando,
      version: version,
      requerido: requerido,
    );
    try {
      final apk = await _bajar(url, version, (p) {
        estado.value = UpdateEstado(
          fase: UpdateFase.descargando,
          progreso: p,
          version: version,
          requerido: requerido,
        );
      });
      _apkListo = apk;
      _apkListoVersion = version;
      estado.value = UpdateEstado(
        fase: UpdateFase.listo,
        version: version,
        requerido: requerido,
        apkPath: apk,
      );
      return apk;
    } catch (e) {
      estado.value = UpdateEstado(fase: UpdateFase.error, error: e.toString());
      rethrow;
    }
  }

  /// Baja el APK a `<appId>_<version>.apk`. Escribe primero en un `.part` y
  /// renombra al terminar: así un archivo con ese nombre siempre es un APK
  /// completo, nunca uno a medias de una descarga interrumpida.
  Future<String> _bajar(
    String url,
    String version,
    void Function(double) onProgreso,
  ) async {
    final dir = await getTemporaryDirectory();
    final nombre = '${appId}_$version.apk';
    final file = File('${dir.path}/$nombre');
    final parcial = File('${file.path}.part');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
      }
      final total = resp.contentLength;
      final sink = parcial.openWrite();
      var recibido = 0;
      try {
        await for (final chunk in resp) {
          recibido += chunk.length;
          sink.add(chunk);
          if (total > 0) onProgreso(recibido / total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await file.exists()) await file.delete();
      await parcial.rename(file.path);
      await _limpiarViejos(dir, nombre);
      return file.path;
    } catch (_) {
      if (await parcial.exists()) await parcial.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Borra APKs de versiones anteriores (y `.part` huérfanos) del temporal:
  /// cada uno pesa decenas de MB y ya no sirve de nada.
  Future<void> _limpiarViejos(Directory dir, String conservar) async {
    try {
      await for (final f in dir.list()) {
        if (f is! File) continue;
        final n = f.uri.pathSegments.last;
        if (n == conservar) continue;
        if (!n.startsWith('${appId}_')) continue;
        if (!n.endsWith('.apk') && !n.endsWith('.apk.part')) continue;
        await f.delete();
      }
    } catch (_) {
      // Limpieza best-effort: no debe tumbar una descarga que ya terminó bien.
    }
  }

  static const _canal = MethodChannel('apk_server');

  /// El instalador de siempre, con el diálogo del sistema. Se cambia solo en
  /// las pruebas: en el escritorio OpenFilex abre el archivo de verdad.
  final Future<void> Function(String apk) _abrirDialogo;

  static Future<void> _abrirConOpenFilex(String apk) async {
    await OpenFilex.open(apk, type: 'application/vnd.android.package-archive');
  }

  /// Cuánto se espera a que Android conteste antes de devolver el botón. Si
  /// instala sin preguntar no contesta: cierra la app.
  static const _esperaInstalacion = Duration(minutes: 2);

  /// ¿Instalar ahora iría sin preguntar? Android 12+ y la persona con
  /// «Permitir de esta fuente» activado para la app.
  Future<bool> sinPreguntar() async {
    try {
      return await _canal.invokeMethod<bool>('sinPreguntar') ?? false;
    } on MissingPluginException {
      return false; // no es Android
    } on PlatformException {
      return false;
    }
  }

  /// Instala el APK descargado.
  ///
  /// Primero SIN PREGUNTAR (lo nativo del paquete, PackageInstaller): Android
  /// cierra la app y la reemplaza, sin diálogo. Si no se puede —Android 11 o
  /// menos, sin «Permitir de esta fuente», o Android pide confirmar igual—,
  /// con [conDialogo] abre el instalador de siempre y la persona confirma; sin
  /// él no hace nada (es lo que se quiere con la app detrás: un diálogo que
  /// salta encima de otra app no lo entiende nadie).
  ///
  /// Devuelve `true` si arrancó una instalación —sin preguntar o con el
  /// diálogo—; `false` si no había APK o hacía falta el diálogo y no se pidió.
  ///
  /// Reentrante: mientras una instalación está en curso, otra llamada no hace
  /// nada (dos toques al botón no arman dos instalaciones).
  Future<bool> instalar({bool conDialogo = true}) async {
    final e = estado.value;
    final p = e.apkPath;
    if (p == null) return false;
    if (_instalando) return true; // ya va
    _instalando = true;
    try {
      if (!conDialogo && !await sinPreguntar()) return false;

      estado.value = e._conFase(UpdateFase.instalando);
      final r = await _instalarSinPreguntar(p);
      if (r == 'instalada') return true;
      // Hace falta la persona, falló o Android no contestó: el APK sigue
      // listo y el botón vuelve.
      if (estado.value.fase == UpdateFase.instalando) {
        estado.value = e._conFase(UpdateFase.listo);
      }
      // Sin respuesta la instalación sí arrancó y puede que Android siga en
      // ella: no se le abre encima otro instalador.
      if (r == 'sin_respuesta') return true;
      if (!conDialogo) return false;
      await _abrirDialogo(p);
      return true;
    } finally {
      _instalando = false;
    }
  }

  bool _instalando = false;

  /// `confirmar | permiso | no_soportado | error | sin_respuesta | instalada`.
  /// Si Android instala sin preguntar, normalmente no vuelve: cierra la app
  /// antes.
  Future<String> _instalarSinPreguntar(String ruta) async {
    try {
      final r = await _canal
          .invokeMapMethod<String, Object?>('instalar', {'ruta': ruta})
          .timeout(_esperaInstalacion);
      final resultado = r?['resultado'] as String? ?? 'error';
      if (resultado == 'error') {
        debugPrint('apk_server: instalar sin preguntar falló: '
            '${r?['mensaje']}');
      }
      return resultado;
    } on MissingPluginException {
      return 'no_soportado'; // no es Android
    } on PlatformException catch (e) {
      debugPrint('apk_server: $e');
      return 'error';
    } on TimeoutException {
      debugPrint('apk_server: Android no contestó la instalación');
      return 'sin_respuesta';
    }
  }

  void dispose() => estado.dispose();
}

/// Auto-actualización de una app Flutter con apk-server: cuelga un
/// [UpdateInstalador] de un [ApkActualizador]. El actualizador (Dart puro)
/// decide CUÁNDO hay versión nueva —sondeo, WebSocket, a mano—; el instalador
/// la baja y la entrega a Android.
///
/// Funciona desde cualquier pantalla: el objeto vive por encima del
/// `Navigator` y la descarga corre sola donde sea. Lo único que la app
/// controla es el MOMENTO de instalar, con [autoInstalar] y [puedeInstalar]:
/// desde Android 12 la instalación va sin preguntar ([UpdateInstalador.instalar])
/// y CIERRA la app al momento, así que a mitad de una tarea no puede pasar.
///
/// En cada consulta va la clave de esta instalación (se genera la primera vez
/// y se guarda en el almacenamiento de la app), lo que el equipo dice de sí
/// (ANDROID_ID, modelo, fabricante, Android) y lo que devuelva [contexto]. Es
/// lo que se ve en la pestaña Equipos del panel.
class UpdateService {
  UpdateService({
    required String servidor,
    required String app,
    this.contexto,
    this.autoInstalar = false,
    this.puedeInstalar,
    this.avisos = true,
    Duration minEntreChequeos = const Duration(minutes: 5),
    Duration intervaloSondeo = const Duration(hours: 1),
  })  : instalador = UpdateInstalador(appId: app),
        _servidor = servidor,
        _app = app,
        _minEntreChequeos = minEntreChequeos,
        _intervaloSondeo = intervaloSondeo;

  final String _servidor;
  final String _app;
  final Duration _minEntreChequeos;
  final Duration _intervaloSondeo;

  /// Lo que la app quiera contar en cada consulta (empresa, usuario con
  /// sesión, almacén…). Lo ve quien administra el hub. Se llama en cada
  /// consulta: puede cambiar con la sesión.
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

  final UpdateInstalador instalador;

  /// El actualizador, una vez [iniciar]. Antes es null: necesita la clave de la
  /// instalación, que se lee de disco.
  ApkActualizador? get actualizador => _actualizador;
  ApkActualizador? _actualizador;
  Future<ApkActualizador>? _preparando;

  ValueNotifier<UpdateEstado> get estado => instalador.estado;

  StreamSubscription<VersionDisponible>? _sub;

  /// Última versión para la que ya se lanzó el instalador en este proceso.
  String? _autoLanzadaVersion;

  static const _canal = MethodChannel('apk_server');

  Future<ApkActualizador> _prepara() => _preparando ??= () async {
        final clave = await _clave();
        final info = await PackageInfo.fromPlatform();
        final a = ApkActualizador(
          servidor: _servidor,
          app: _app,
          buildActual: () async => int.tryParse(info.buildNumber) ?? 0,
          instalacion: clave,
          equipo: () async => {...await _equipo(), 'version': info.version},
          contexto: contexto,
          minEntreChequeos: _minEntreChequeos,
          intervalo: _intervaloSondeo,
        );
        _sub = a.disponible.listen(_alHaberVersion);
        _actualizador = a;
        return a;
      }();

  /// La clave de esta instalación: se genera una vez y queda en el
  /// almacenamiento de la app. Desinstalar la borra; para eso está la huella.
  Future<String> _clave() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/apk_server_instalacion');
      if (await f.exists()) {
        final c = (await f.readAsString()).trim();
        if (c.length >= 8) return c;
      }
      final r = Random.secure();
      final c = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await f.writeAsString(c, flush: true);
      return c;
    } catch (_) {
      // Sin disco (una prueba, otra plataforma): una clave por proceso.
      return 'proceso-${DateTime.now().microsecondsSinceEpoch}';
    }
  }

  static Future<Map<String, Object?>> _equipo() async {
    try {
      final m = await _canal.invokeMapMethod<String, Object?>('equipo');
      return m ?? const {};
    } on MissingPluginException {
      return const {}; // no es Android
    } on PlatformException {
      return const {};
    }
  }

  /// Pregunta ya, cada hora y —con [avisos]— en cuanto el hub avise.
  Future<void> iniciar() async {
    final a = await _prepara();
    a.iniciar();
    if (avisos) a.conectarAvisos();
  }

  /// Para el sondeo y cierra el WebSocket.
  Future<void> detener() async {
    final a = _actualizador;
    if (a == null) return;
    a.detener();
    await a.desconectarAvisos();
  }

  /// Para colgarlo de «la app volvió al frente»: reconecta el WebSocket si
  /// estaba esperando y pregunta (respetando el freno de [minEntreChequeos]).
  Future<void> alVolverAlFrente() async {
    _actualizador?.avisos?.reconectarAhora();
    await verificarYDescargar();
  }

  /// Verifica y, si hay versión nueva, la baja en segundo plano. Reentrante y
  /// con freno; [forzar] lo salta, para el botón manual.
  Future<void> verificarYDescargar({bool forzar = false}) async {
    final prev = estado.value;
    if (prev.fase == UpdateFase.descargando) return;
    if (prev.fase == UpdateFase.instalando) return; // la app se va a cerrar
    estado.value = UpdateEstado(
      fase: UpdateFase.verificando,
      version: prev.version,
      requerido: prev.requerido,
      apkPath: prev.apkPath,
    );
    final a = await _prepara();
    final v = await a.verificar(forzar: forzar);
    if (v == null) {
      final err = a.ultimoError;
      // Al día (o sin poder saberlo): si ya había un APK listo, se conserva.
      if (prev.fase == UpdateFase.listo && prev.apkPath != null) {
        estado.value = prev;
      } else if (err != null) {
        estado.value = UpdateEstado(fase: UpdateFase.error, error: '$err');
      } else {
        estado.value = const UpdateEstado();
      }
      return;
    }
    // Si [disponible] ya la emitió, la descarga va en camino; si era una
    // versión ya emitida (misma build), bajarla de nuevo reusa el archivo.
    await _descargar(v);
  }

  void _alHaberVersion(VersionDisponible v) {
    if (estado.value.fase == UpdateFase.instalando) return;
    unawaited(_descargar(v));
  }

  Future<void> _descargar(VersionDisponible v) async {
    try {
      await instalador.descargar(v.url, version: v.version, requerido: v.requerido);
    } catch (_) {
      return; // el estado ya quedó en error
    }
    await instalarSiListo();
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
    if (e.version != null && e.version == _autoLanzadaVersion) return;
    final alFrente = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _autoLanzadaVersion = e.version;
    final lanzada = await instalador.instalar(conDialogo: alFrente);
    if (!lanzada) _autoLanzadaVersion = null;
  }

  /// Instala el APK descargado: sin preguntar si Android lo deja (la app se
  /// cierra), si no con el diálogo del sistema. Es el botón: ignora
  /// [puedeInstalar] y el «una vez por versión».
  Future<void> instalar() async {
    await instalador.instalar();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _actualizador?.dispose();
    instalador.dispose();
  }
}
