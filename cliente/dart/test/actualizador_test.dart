import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apk_server/apk_server.dart';
import 'package:test/test.dart';

/// Un hub de mentira en un puerto local: contesta la consulta con la build que
/// diga la prueba y deja mandar avisos por el WebSocket.
class _HubFalso {
  late HttpServer _srv;
  int ultima = 84;
  bool requerido = false;
  final consultas = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];

  String get url => 'http://127.0.0.1:${_srv.port}';

  Future<void> arranca() async {
    _srv = await HttpServer.bind('127.0.0.1', 0);
    _srv.listen((r) async {
      if (r.uri.path == '/v1/ws') {
        final ws = await WebSocketTransformer.upgrade(r);
        sockets.add(ws);
        ws.listen((_) {});
        return;
      }
      if (r.uri.path == '/v1/apps/inventario/consulta') {
        final c = jsonDecode(await utf8.decodeStream(r)) as Map<String, dynamic>;
        consultas.add(c);
        final build = c['build'] as int;
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode({
          'build_actual': build,
          'actualizar': ultima > build,
          'requerido': requerido && ultima > build,
          'version': {
            'build': ultima,
            'version': '1.$ultima.0',
            'notas': 'Lo nuevo',
            'ruta': '/archivos/abc.apk',
            'url': '$url/archivos/abc.apk',
            'sha256': 'abc',
            'bytes': 123,
          },
        }));
        await r.response.close();
        return;
      }
      r.response.statusCode = 404;
      await r.response.close();
    });
  }

  void avisa(Map<String, Object?> m) {
    for (final s in sockets) {
      s.add(jsonEncode(m));
    }
  }

  Future<void> cierra() => _srv.close(force: true);
}

void main() {
  late _HubFalso hub;

  setUp(() async {
    hub = _HubFalso();
    await hub.arranca();
  });
  tearDown(() => hub.cierra());

  test('pregunta con lo que sabe del equipo y entrega la versión una sola vez', () async {
    final a = ApkActualizador(
      servidor: '${hub.url}/',
      app: 'inventario',
      buildActual: () async => 80,
      instalacion: 'equipo-0001',
      equipo: () async => {'modelo': 'TC56', 'android': 27},
      contexto: () => {'empresa': 7},
    );
    final emitidas = <VersionDisponible>[];
    a.disponible.listen(emitidas.add);

    final v = await a.verificar();
    expect(v?.build, 84);
    expect(v?.url, '${hub.url}/archivos/abc.apk');
    expect(v?.notas, 'Lo nuevo');
    await a.verificar(forzar: true);
    await Future<void>.delayed(Duration.zero);
    expect(emitidas.length, 1, reason: 'la misma build no se avisa dos veces');

    expect(hub.consultas.first, {
      'build': 80,
      'instalacion': 'equipo-0001',
      'modelo': 'TC56',
      'android': 27,
      'contexto': {'empresa': 7},
    });
    await a.dispose();
  });

  test('al día no entrega nada', () async {
    final a = ApkActualizador(servidor: hub.url, app: 'inventario', buildActual: () async => 84);
    expect(await a.verificar(), isNull);
    expect(a.ultimoError, isNull);
    await a.dispose();
  });

  test('sin red no revienta: deja el error', () async {
    final a = ApkActualizador(
      servidor: 'http://127.0.0.1:1',
      app: 'inventario',
      buildActual: () async => 1,
    );
    expect(await a.verificar(), isNull);
    expect(a.ultimoError, isNotNull);
    await a.dispose();
  });

  test('un aviso por el WebSocket hace preguntar en el acto', () async {
    final a = ApkActualizador(
      servidor: hub.url,
      app: 'inventario',
      buildActual: () async => 84,
      instalacion: 'equipo-0001',
      minEntreChequeos: const Duration(hours: 1),
    );
    final llego = Completer<VersionDisponible>();
    a.disponible.listen(llego.complete);
    a.conectarAvisos();
    // Al conectar ya pregunta una vez (por si se publicó mientras no había socket).
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(hub.sockets, hasLength(1));
    expect(hub.consultas, hasLength(1));

    hub.ultima = 85;
    hub.avisa({'tipo': 'version', 'app': 'inventario', 'build': 85});
    final v = await llego.future.timeout(const Duration(seconds: 3));
    expect(v.build, 85);
    expect(a.avisos?.uri.toString(), contains('instalacion=equipo-0001'));
    await a.dispose();
  });

  test('el aviso de otra app no hace nada', () async {
    final a = ApkActualizador(servidor: hub.url, app: 'inventario', buildActual: () async => 84);
    a.conectarAvisos();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final antes = hub.consultas.length;
    hub.avisa({'tipo': 'version', 'app': 'otra', 'build': 99});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hub.consultas.length, antes);
    await a.dispose();
  });
}
