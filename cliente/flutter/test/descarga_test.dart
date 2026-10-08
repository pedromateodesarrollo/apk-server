import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_server_flutter/apk_server_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// La descarga cuando la red falla a mitad: se corta, se queda colgada, el
/// servidor no atiende `Range`. Lo que se vio con la TC56 el 2026-10-08: la
/// conexión se cortó en 26 de 61 MB al cambiar de punto de acceso, la descarga
/// quedó en error y nada la volvió a arrancar hasta reabrir la app.
///
/// El hub es de mentira y de sockets crudos: con `HttpServer` no se puede
/// cortar una respuesta a la mitad.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Hub hub;
  late Directory dir;
  final apk = Uint8List.fromList(List.generate(100000, (i) => (i * 7 + i ~/ 256) & 0xff));

  setUpAll(() {
    // El binding de pruebas contesta 400 a todo HTTP; aquí hace falta la red
    // de verdad (la del hub de mentira, en 127.0.0.1).
    HttpOverrides.global = null;
  });

  setUp(() async {
    hub = _Hub(apk);
    await hub.abrir();
    dir = await Directory.systemTemp.createTemp('apk_server_prueba');
  });

  tearDown(() async {
    await hub.cerrar();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  List<String> pedazos() =>
      dir.listSync().map((f) => f.uri.pathSegments.last).where((n) => n.endsWith('.part')).toList();

  group('UpdateInstalador.descargar', () {
    late UpdateInstalador inst;

    setUp(() {
      inst = UpdateInstalador(
        appId: 'prueba',
        carpeta: () async => dir,
        sinDatos: const Duration(milliseconds: 400),
      );
    });

    tearDown(() => inst.dispose());

    test('se corta a mitad: queda el pedazo y la siguiente sigue desde ahí', () async {
      hub.envios.add(const _Envio.corta(40000));
      await expectLater(
        inst.descargar(hub.url, version: '1.0.1', bytes: apk.length),
        throwsA(isA<HttpException>()),
      );
      final e = inst.estado.value;
      expect(e.fase, UpdateFase.error);
      expect(e.version, '1.0.1');
      expect(e.progreso, closeTo(0.4, 0.01));
      expect(pedazos(), hasLength(1));

      final ruta = await inst.descargar(hub.url, version: '1.0.1', bytes: apk.length);
      expect(hub.rangos, [null, 'bytes=40000-']);
      expect(await File(ruta).readAsBytes(), apk);
      expect(pedazos(), isEmpty);
      expect(inst.estado.value.fase, UpdateFase.listo);
    });

    test('conexión colgada: se da por cortada y después sigue', () async {
      hub.envios.add(const _Envio.cuelga(30000));
      final antes = DateTime.now();
      await expectLater(
        inst.descargar(hub.url, version: '1.0.1', bytes: apk.length),
        throwsA(isA<TimeoutException>()),
      );
      expect(DateTime.now().difference(antes), lessThan(const Duration(seconds: 5)));

      final ruta = await inst.descargar(hub.url, version: '1.0.1', bytes: apk.length);
      expect(hub.rangos, [null, 'bytes=30000-']);
      expect(await File(ruta).readAsBytes(), apk);
    });

    test('si el servidor no atiende Range, empieza de cero y queda bien', () async {
      hub.envios.add(const _Envio.corta(40000));
      await expectLater(
        inst.descargar(hub.url, version: '1.0.1', bytes: apk.length),
        throwsA(anything),
      );
      hub.ignoraRango = true;
      final ruta = await inst.descargar(hub.url, version: '1.0.1', bytes: apk.length);
      expect(hub.rangos, [null, 'bytes=40000-']);
      expect(await File(ruta).readAsBytes(), apk);
    });

    test('un pedazo de otra URL no se pega', () async {
      hub.envios.add(const _Envio.corta(40000));
      await expectLater(
        inst.descargar(hub.url, version: '1.0.1', bytes: apk.length),
        throwsA(anything),
      );
      // Misma versión, otro archivo (otra build con el mismo nombre).
      final ruta = await inst.descargar('${hub.base}/archivos/otro.apk',
          version: '1.0.1', bytes: apk.length);
      expect(hub.rangos, [null, null]);
      expect(await File(ruta).readAsBytes(), apk);
      // El pedazo viejo se limpia al terminar bien.
      expect(pedazos(), isEmpty);
    });

    test('con otro tamaño que el dicho, no se da por bajada', () async {
      await expectLater(
        inst.descargar(hub.url, version: '1.0.1', bytes: apk.length - 10),
        throwsA(isA<HttpException>()),
      );
      expect(inst.estado.value.fase, UpdateFase.error);
      expect(dir.listSync().where((f) => f.path.endsWith('.apk')), isEmpty);
    });
  });

  group('UpdateService', () {
    late UpdateService servicio;

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'prueba',
        packageName: 'com.ejemplo.prueba',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      servicio = UpdateService(
        servidor: hub.base,
        app: 'prueba',
        avisos: false,
        esperasReintento: const [Duration(milliseconds: 50)],
        carpeta: () async => dir,
      );
    });

    tearDown(() => servicio.dispose());

    Future<UpdateEstado> hasta(bool Function(UpdateEstado) cond) {
      final listo = Completer<UpdateEstado>();
      void mira() {
        final e = servicio.estado.value;
        if (cond(e) && !listo.isCompleted) listo.complete(e);
      }

      servicio.estado.addListener(mira);
      mira();
      return listo.future
          .timeout(const Duration(seconds: 10))
          .whenComplete(() => servicio.estado.removeListener(mira));
    }

    test('una descarga cortada se reintenta sola hasta llegar', () async {
      hub.envios
        ..add(const _Envio.corta(40000))
        ..add(const _Envio.corta(20000));
      await servicio.iniciar();
      final e = await hasta((e) => e.fase == UpdateFase.listo);
      expect(e.version, '1.0.1');
      expect(await File(e.apkPath!).readAsBytes(), apk);
      // Cada reintento vuelve a preguntar y sigue desde donde quedó.
      expect(hub.rangos, [null, 'bytes=40000-', 'bytes=60000-']);
      expect(hub.consultas, 3);
    });

    test('si la versión deja de estar, deja de reintentar', () async {
      hub.envios.add(const _Envio.corta(40000));
      hub.alPedirArchivo = () => hub.ofrece = false;
      await servicio.iniciar();
      await hasta((e) => e.fase == UpdateFase.idle && hub.consultas >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hub.rangos, [null]);
      expect(hub.consultas, 2);
      expect(servicio.estado.value.fase, UpdateFase.idle);
    });

    test('sin red para preguntar, la versión sigue pendiente', () async {
      hub.envios.add(const _Envio.corta(40000));
      // El primer reintento no llega ni a preguntar: el hub está caído.
      hub.alPedirArchivo = () => hub.caidoProximas = 1;
      await servicio.iniciar();
      final e = await hasta((e) => e.fase == UpdateFase.listo);
      expect(await File(e.apkPath!).readAsBytes(), apk);
      expect(hub.rangos, [null, 'bytes=40000-']);
    });
  });
}

/// Qué hace el hub de mentira con un pedido del APK.
class _Envio {
  const _Envio.corta(this.bytes) : cuelga = false;
  const _Envio.cuelga(this.bytes) : cuelga = true;

  /// Cuántos bytes manda antes de cortar (o de quedarse callado).
  final int bytes;
  final bool cuelga;
}

class _Hub {
  _Hub(this.apk);

  final Uint8List apk;
  late ServerSocket _srv;
  final _colgados = <Socket>[];

  /// Lo que se hace con cada pedido del APK, en orden; vacía = entero.
  final envios = <_Envio>[];

  /// La cabecera `Range` de cada pedido del APK (null = sin ella).
  final rangos = <String?>[];
  int consultas = 0;
  bool ofrece = true;
  bool ignoraRango = false;

  /// Cuántas consultas siguientes se cortan sin contestar.
  int caidoProximas = 0;
  void Function()? alPedirArchivo;

  String get base => 'http://127.0.0.1:${_srv.port}';
  String get url => '$base/archivos/abc.apk';

  Future<void> abrir() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen(_atiende);
  }

  Future<void> cerrar() async {
    for (final s in _colgados) {
      s.destroy();
    }
    await _srv.close();
  }

  void _atiende(Socket s) {
    final buf = BytesBuilder(copy: false);
    var atendido = false;
    s.listen(
      (d) {
        if (atendido) return;
        buf.add(d);
        final b = buf.toBytes();
        final fin = _finCabecera(b);
        if (fin < 0) return;
        final lineas = latin1.decode(b.sublist(0, fin)).split('\r\n');
        final h = <String, String>{};
        for (final l in lineas.skip(1)) {
          final i = l.indexOf(':');
          if (i > 0) h[l.substring(0, i).trim().toLowerCase()] = l.substring(i + 1).trim();
        }
        final largo = int.tryParse(h['content-length'] ?? '') ?? 0;
        if (b.length < fin + 4 + largo) return;
        atendido = true;
        final pedido = lineas.first.split(' ');
        unawaited(_responde(s, pedido[0], pedido[1], h));
      },
      onError: (_) {},
    );
  }

  Future<void> _responde(Socket s, String metodo, String ruta, Map<String, String> h) async {
    if (metodo == 'POST' && ruta == '/v1/apps/prueba/consulta') {
      if (caidoProximas > 0) {
        caidoProximas--;
        s.destroy();
        return;
      }
      consultas++;
      final cuerpo = utf8.encode(jsonEncode(ofrece
          ? {
              'build_actual': 1,
              'actualizar': true,
              'requerido': true,
              'version': {'build': 2, 'version': '1.0.1', 'bytes': apk.length, 'url': url},
            }
          : {'build_actual': 1, 'actualizar': false, 'requerido': false, 'version': null}));
      s.add(latin1.encode('HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n'
          'content-length: ${cuerpo.length}\r\nconnection: close\r\n\r\n'));
      s.add(cuerpo);
      await s.flush();
      s.destroy();
      return;
    }
    if (metodo == 'GET' && ruta.startsWith('/archivos/')) {
      final rango = h['range'];
      rangos.add(rango);
      alPedirArchivo?.call();
      var desde = 0;
      if (rango != null && !ignoraRango) {
        desde = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(rango)!.group(1)!);
      }
      final envio = envios.isEmpty ? null : envios.removeAt(0);
      final resto = apk.sublist(desde);
      s.add(latin1.encode(desde > 0
          ? 'HTTP/1.1 206 Partial Content\r\ncontent-range: bytes $desde-${apk.length - 1}/${apk.length}\r\n'
          : 'HTTP/1.1 200 OK\r\n'));
      s.add(latin1.encode('content-length: ${resto.length}\r\nconnection: close\r\n\r\n'));
      if (envio == null) {
        s.add(resto);
        await s.flush();
        s.destroy();
      } else {
        s.add(resto.sublist(0, envio.bytes));
        await s.flush();
        if (envio.cuelga) {
          _colgados.add(s);
        } else {
          s.destroy();
        }
      }
      return;
    }
    s.add(latin1.encode('HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n'));
    await s.flush();
    s.destroy();
  }

  static int _finCabecera(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }
}
