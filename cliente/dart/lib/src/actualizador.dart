import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'avisos.dart';
import 'version.dart';

/// Lo que un equipo cuenta de sí mismo en cada consulta: `huella` (el
/// ANDROID_ID), `modelo`, `fabricante`, `android` (nivel de SDK) y `version`
/// (el versionName instalado). Todo opcional.
typedef DatosEquipo = Future<Map<String, Object?>> Function();

/// Pregunta al hub si hay versión nueva y se entera por WebSocket de que se
/// publicó algo. NO descarga ni instala: entrega la versión en [disponible] y
/// la plataforma hace el resto.
///
/// Tres caminos, todos desembocan en [verificar]:
///  - [iniciar]: pregunta ya y cada [intervalo] (el respaldo).
///  - [conectarAvisos]: abre el WebSocket; cada aviso de esta app dispara una
///    verificación inmediata, y también cada reconexión (el aviso se reparte
///    una sola vez a los sockets vivos, y en Android el socket se cae cada vez
///    que la app pasa a segundo plano).
///  - La app llama [verificar] cuando quiera (volver al frente, un botón).
///
/// [disponible] emite una sola vez por build: doce verificaciones que
/// encuentran la misma versión no son doce avisos.
class ApkActualizador {
  ApkActualizador({
    required String servidor,
    required this.app,
    required this.buildActual,
    this.instalacion,
    this.equipo,
    this.contexto,
    this.intervalo = const Duration(hours: 1),
    this.minEntreChequeos = const Duration(minutes: 5),
    HttpClient? http,
  })  : servidor = servidor.trim().replaceAll(RegExp(r'/+$'), ''),
        _http = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 20));

  /// `https://apk.ejemplo.com`
  final String servidor;

  /// Slug de la app en el hub.
  final String app;

  /// `versionCode` de lo que está corriendo.
  final Future<int> Function() buildActual;

  /// Clave de esta instalación (8–100 caracteres). La genera la app la primera
  /// vez y la guarda. Sin ella el hub contesta igual, pero no anota el equipo.
  final String? instalacion;

  final DatosEquipo? equipo;

  /// Lo que la app quiera contar en cada consulta (empresa, usuario…). Lo ve
  /// quien administra el hub, en la pestaña Equipos.
  final Map<String, Object?> Function()? contexto;

  final Duration intervalo;
  final Duration minEntreChequeos;

  final HttpClient _http;

  final _disponible = StreamController<VersionDisponible>.broadcast();

  /// Versión nueva encontrada. Una emisión por build.
  Stream<VersionDisponible> get disponible => _disponible.stream;

  /// La última versión nueva vista, o null si estamos al día (o sin verificar).
  VersionDisponible? get ultima => _ultima;
  VersionDisponible? _ultima;

  /// Último fallo (red, servidor). Se limpia al acertar.
  Object? get ultimoError => _ultimoError;
  Object? _ultimoError;

  /// El socket de avisos, si se conectó.
  AvisosWs? get avisos => _avisos;
  AvisosWs? _avisos;

  Future<VersionDisponible?>? _enCurso;
  DateTime? _ultimoChequeo;
  Timer? _sondeo;
  int? _ultimoBuildEmitido;
  StreamSubscription<Map<String, dynamic>>? _subEventos;
  StreamSubscription<bool>? _subEstado;

  /// Arranca el sondeo de respaldo (y verifica ya). Idempotente.
  void iniciar() {
    _sondeo?.cancel();
    _sondeo = Timer.periodic(intervalo, (_) => unawaited(verificar()));
    unawaited(verificar());
  }

  void detener() {
    _sondeo?.cancel();
    _sondeo = null;
  }

  /// Abre el WebSocket de avisos. Idempotente.
  void conectarAvisos() {
    if (_avisos != null) {
      _avisos!.conectar();
      return;
    }
    final ws = AvisosWs(servidor: servidor, app: app, instalacion: instalacion);
    _avisos = ws;
    _subEventos = ws.eventos.listen((e) {
      if (e['tipo'] != 'version') return;
      final de = e['app']?.toString();
      if (de != null && de.isNotEmpty && de != app) return;
      unawaited(verificar(forzar: true));
    });
    _subEstado = ws.estado.listen((conectado) {
      if (conectado) unawaited(verificar(forzar: true));
    });
    ws.conectar();
  }

  Future<void> desconectarAvisos() async {
    await _subEventos?.cancel();
    await _subEstado?.cancel();
    await _avisos?.dispose();
    _avisos = null;
  }

  /// Pregunta al hub. Reentrante: si ya hay una consulta en vuelo se acopla a
  /// ella. Salta si la anterior fue hace menos de [minEntreChequeos], salvo
  /// [forzar]. Devuelve la versión nueva o null (al día, o falló: ver
  /// [ultimoError]).
  Future<VersionDisponible?> verificar({bool forzar = false}) {
    final actual = _enCurso;
    if (actual != null) return actual;
    final ultimo = _ultimoChequeo;
    if (!forzar && ultimo != null && DateTime.now().difference(ultimo) < minEntreChequeos) {
      return Future.value(_ultima);
    }
    final f = _verificar().whenComplete(() {
      _enCurso = null;
      _ultimoChequeo = DateTime.now();
    });
    _enCurso = f;
    return f;
  }

  Future<VersionDisponible?> _verificar() async {
    try {
      final r = await consultar();
      _ultimoError = null;
      final v = VersionDisponible.deRespuesta(r, servidor);
      _ultima = v;
      if (v != null && _ultimoBuildEmitido != v.build) {
        _ultimoBuildEmitido = v.build;
        _disponible.add(v);
      }
      return v;
    } catch (e) {
      _ultimoError = e;
      return null;
    }
  }

  /// La consulta cruda (`POST /v1/apps/:app/consulta`). Lanza si el hub no
  /// contesta bien.
  Future<Map<String, Object?>> consultar() async {
    final cuerpo = <String, Object?>{
      'build': await buildActual(),
      if (instalacion != null) 'instalacion': instalacion,
      if (equipo != null) ...await equipo!(),
      if (contexto != null) 'contexto': contexto!(),
    };
    final req = await _http.postUrl(Uri.parse('$servidor/v1/apps/${Uri.encodeComponent(app)}/consulta'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(cuerpo));
    final res = await req.close().timeout(const Duration(seconds: 30));
    final texto = await utf8.decodeStream(res);
    if (res.statusCode != 200) {
      throw HttpException('El hub contestó ${res.statusCode}: $texto');
    }
    final d = jsonDecode(texto);
    if (d is! Map) throw const FormatException('Respuesta inesperada del hub');
    return Map<String, Object?>.from(d);
  }

  Future<void> dispose() async {
    detener();
    await desconectarAvisos();
    await _disponible.close();
    _http.close(force: true);
  }
}
