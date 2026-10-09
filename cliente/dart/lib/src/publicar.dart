import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'apk_info.dart';

/// Algo impide publicar. [motivo] va tal cual a quien publica.
class PublicarError implements Exception {
  PublicarError(this.motivo, {this.codigo = 65});
  final String motivo;

  /// El código de salida del comando.
  final int codigo;

  @override
  String toString() => motivo;
}

/// Un APK listo para subir: a qué hub y a qué app va, y qué trae.
class Publicacion {
  Publicacion(this.apk, this.info, this.hub, this.app);
  final File apk;
  final ApkInfo info;
  final String hub;
  final String app;

  Uri get url => Uri.parse('$hub/v1/apps/${Uri.encodeComponent(app)}/versiones');
}

/// Lee el APK y decide a dónde va: lo que dice su manifiesto (la biblioteca
/// de Android lo pone desde `manifestPlaceholders["apkServerHub"]` y
/// `["apkServerApp"]` del `build.gradle.kts` de la app). Así la app y su
/// publicación no pueden decir cosas distintas: el APK que pregunta a un hub
/// por la app «wms» se sube a ese hub, en «wms».
///
/// [hub] y [app] solo hacen falta con un APK sin la biblioteca; con ella, si
/// se dan, tienen que coincidir. [build] y [version], si se dan, también.
Future<Publicacion> prepararPublicacion(
  File apk, {
  String? hub,
  String? app,
  int? build,
  String? version,
}) async {
  if (!await apk.exists()) throw PublicarError('No existe ${apk.path}', codigo: 66);
  final ApkInfo info;
  try {
    info = await ApkInfo.deArchivo(apk);
  } on ApkInvalido catch (e) {
    throw PublicarError('${apk.path}: ${e.motivo}');
  }
  final nombre = apk.uri.pathSegments.last;
  hub = _sinBarra(hub);
  app = app?.trim();
  if (hub != null && hub.isEmpty) hub = null;
  if (app != null && app.isEmpty) app = null;

  final hubApk = info.hub, appApk = info.app;
  String destinoHub, destinoApp;
  if (hubApk == null || appApk == null) {
    if (hub == null || app == null) {
      throw PublicarError(
        '$nombre no dice a qué hub ni a qué app va (no trae la biblioteca de apk-server, '
        'o es de antes de la 0.2). Pon en android/app/build.gradle.kts:\n'
        '    manifestPlaceholders["apkServerHub"] = "https://tu-hub"\n'
        '    manifestPlaceholders["apkServerApp"] = "tu-app"\n'
        'o di --hub y --app.',
      );
    }
    destinoHub = hub;
    destinoApp = app;
  } else {
    if (hubApk.isEmpty || appApk.isEmpty) {
      throw PublicarError(
        '$nombre está compilado sin hub (apkServerHub vacío): no se actualiza solo, '
        'y no tiene caso publicarlo.',
      );
    }
    if (hub != null && hub != hubApk) {
      throw PublicarError('$nombre pregunta a $hubApk, no a $hub: los equipos no lo encontrarían.');
    }
    if (app != null && app != appApk) {
      throw PublicarError('$nombre es de la app «$appApk», no de «$app» (lo dice su manifiesto).');
    }
    destinoHub = hubApk;
    destinoApp = appApk;
  }
  if (build != null && build != info.build) {
    throw PublicarError('$nombre trae el versionCode ${info.build}, no $build. ¿Es el APK que querías?');
  }
  if (version != null && version.isNotEmpty && info.version.isNotEmpty && version != info.version) {
    throw PublicarError('$nombre trae el versionName ${info.version}, no $version.');
  }
  return Publicacion(apk, info, destinoHub, destinoApp);
}

/// Sube [p] al hub. Devuelve lo que contestó (la versión, con `ya_estaba` o
/// `avisadas`). Lanza [PublicarError] con el motivo del hub si lo rechaza.
Future<Map<String, Object?>> subir(
  Publicacion p, {
  required String llave,
  String notas = '',
  bool requerido = false,
  HttpClient? http,
}) async {
  final cliente = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 30));
  try {
    final url = p.url.replace(queryParameters: {
      'build': '${p.info.build}',
      if (p.info.version.isNotEmpty) 'version': p.info.version,
      if (notas.isNotEmpty) 'notas': notas,
      if (requerido) 'requerido': '1',
    });
    final req = await cliente.postUrl(url);
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $llave')
      ..contentType = ContentType('application', 'vnd.android.package-archive')
      ..contentLength = await p.apk.length();
    await req.addStream(p.apk.openRead());
    final res = await req.close();
    final texto = await utf8.decodeStream(res);
    Object? d;
    try {
      d = jsonDecode(texto);
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final m = d is Map ? d : const {};
      final error = m['error'] ?? 'HTTP ${res.statusCode}';
      final mensaje = m['mensaje'] ?? (texto.length > 300 ? texto.substring(0, 300) : texto);
      throw PublicarError('El hub no lo aceptó ($error): $mensaje', codigo: 1);
    }
    if (d is! Map) throw PublicarError('Respuesta inesperada del hub: $texto', codigo: 1);
    return Map<String, Object?>.from(d);
  } on SocketException catch (e) {
    throw PublicarError('No se pudo llegar a ${p.hub}: ${e.message}', codigo: 1);
  } finally {
    if (http == null) cliente.close(force: true);
  }
}

const _ayuda = '''
Publica APK en el hub de apk-server al que pertenecen: hub y app salen del
propio APK (los meta-data que pone la biblioteca de Android desde
manifestPlaceholders["apkServerHub"] y ["apkServerApp"] del build.gradle.kts).

  dart run apk_server_flutter:publicar [--apk <archivo>]… [opciones]

  --apk <archivo>     el APK (se puede repetir: un sabor por APK). Sin él, el
                      de `flutter build apk --release`.
  --build <N>         comprueba que el APK traiga ese versionCode
  --version <X.Y.Z>   comprueba que traiga ese versionName
  --notas "<texto>"   lo que cambió (lo ve el panel)
  --requerido         obligatoria: todos los equipos tienen que pasar a esta
  --hub, --app        solo para un APK sin la biblioteca; con ella tienen que
                      coincidir con lo que dice el APK
  --llave-archivo <f> un archivo con la llave (si no, APK_SERVER_LLAVE)
  --simular           dice qué subiría y a dónde, sin subir nada

La llave (cak_…, con permiso de publicar) sale de APK_SERVER_LLAVE o de
--llave-archivo: nunca por argumento, que queda en el historial y en `ps`.
''';

/// El comando. Devuelve el código de salida.
Future<int> publicarCli(
  List<String> args, {
  Map<String, String>? entorno,
  StringSink? salida,
  StringSink? errores,
  HttpClient? http,
}) async {
  final env = entorno ?? Platform.environment;
  final out = salida ?? stdout;
  final err = errores ?? stderr;

  final apks = <String>[];
  String? hub, app, notas, version, archivoLlave;
  int? build;
  var requerido = false, simular = false;
  try {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String valor() {
        if (i + 1 >= args.length) throw PublicarError('Falta el valor de $a', codigo: 64);
        return args[++i];
      }

      switch (a) {
        case '--apk':
          apks.add(valor());
        case '--hub':
          hub = valor();
        case '--app':
          app = valor();
        case '--build':
          final v = valor();
          build = int.tryParse(v) ?? (throw PublicarError('--build $v no es un número', codigo: 64));
        case '--version':
          version = valor();
        case '--notas':
          notas = valor();
        case '--requerido':
          requerido = true;
        case '--llave-archivo':
          archivoLlave = valor();
        case '--simular':
          simular = true;
        case '-h' || '--help':
          out.write(_ayuda);
          return 0;
        default:
          throw PublicarError('No sé qué es $a (ver --help)', codigo: 64);
      }
    }
    if (apks.isEmpty) {
      const porDefecto = 'build/app/outputs/flutter-apk/app-release.apk';
      if (!File(porDefecto).existsSync()) {
        throw PublicarError('Falta --apk (y no está $porDefecto)', codigo: 64);
      }
      apks.add(porDefecto);
    }

    // Todo se revisa antes de subir nada: con dos sabores, que no quede uno
    // publicado y el otro no por un error que se veía desde el principio.
    final listas = <Publicacion>[
      for (final a in apks)
        await prepararPublicacion(File(a), hub: hub, app: app, build: build, version: version),
    ];

    if (simular) {
      for (final p in listas) {
        out.writeln('subiría ${p.apk.path} (${p.info.paquete} ${p.info.version}+${p.info.build}) '
            'a ${p.hub}, app «${p.app}»');
      }
      return 0;
    }

    var llave = env['APK_SERVER_LLAVE']?.trim() ?? '';
    if (llave.isEmpty && archivoLlave != null) {
      llave = (await File(archivoLlave).readAsString()).trim();
    }
    if (llave.isEmpty) {
      throw PublicarError('Falta la llave: APK_SERVER_LLAVE o --llave-archivo', codigo: 64);
    }

    for (final p in listas) {
      final mb = await p.apk.length() / (1024 * 1024);
      err.writeln('→ ${p.app} ${p.info.version}+${p.info.build}: subiendo ${mb.toStringAsFixed(1)} MB a ${p.hub}…');
      final r = await subir(p, llave: llave, notas: notas ?? '', requerido: requerido, http: http);
      final ya = r['ya_estaba'] == true;
      out.writeln('✓ ${r['paquete']} ${r['version']}+${r['build']} en «${p.app}» '
          '${ya ? '(ya estaba)' : '(avisados: ${r['avisadas'] ?? 0} equipos)'}');
      out.writeln('  instalar: ${p.hub}/i/${p.app}');
    }
    return 0;
  } on PublicarError catch (e) {
    err.writeln('✘ ${e.motivo}');
    return e.codigo;
  }
}

String? _sinBarra(String? s) => s?.trim().replaceAll(RegExp(r'/+$'), '');
