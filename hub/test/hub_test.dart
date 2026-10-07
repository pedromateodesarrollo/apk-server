@Tags(['bd'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_server_hub/hub.dart';
import 'package:apk_server_hub/src/http/rutas_auth.dart';
import 'package:apk_server_hub/src/seguridad.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'apk_sintetico.dart';

/// El hub de punta a punta contra un Postgres de verdad.
///
/// Necesita `APK_PRUEBA_DATABASE_URL` apuntando a una base DESECHABLE: la
/// prueba borra el esquema `apk` al empezar. Sin la variable, se salta.
///
///   docker run -d --name apk-bd -e POSTGRES_PASSWORD=apk -p 55432:5432 postgres:16-alpine
///   APK_PRUEBA_DATABASE_URL='postgres://postgres:apk@127.0.0.1:55432/postgres?sslmode=disable' dart test
void main() {
  final url = Platform.environment['APK_PRUEBA_DATABASE_URL'] ?? '';
  if (url.isEmpty) {
    test('hub contra Postgres', () {}, skip: 'Falta APK_PRUEBA_DATABASE_URL');
    return;
  }

  late Hub hub;
  late Directory dir;
  late String base;
  late String llave;

  final certA = Uint8List.fromList(utf8.encode('certificado A'));
  final certB = Uint8List.fromList(utf8.encode('certificado B'));

  Uint8List apk(int build, {String paquete = 'com.ejemplo.inventario', Uint8List? cert}) =>
      apkSintetico(
        {'AndroidManifest.xml': manifiestoSintetico(paquete: paquete, build: build, version: '1.$build.0')},
        certificado: cert ?? certA,
      );

  Future<(int, Map<String, dynamic>)> pide(
    String metodo,
    String ruta, {
    Object? json,
    List<int>? cuerpo,
    String? token,
  }) async {
    final c = HttpClient();
    try {
      final r = await c.openUrl(metodo, Uri.parse('$base$ruta'));
      r.followRedirects = false;
      if (token != null) r.headers.set('authorization', 'Bearer $token');
      if (json != null) {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(json));
      } else if (cuerpo != null) {
        r.add(cuerpo);
      }
      final res = await r.close();
      final texto = await utf8.decodeStream(res);
      final d = texto.isEmpty || res.headers.contentType?.mimeType != 'application/json'
          ? <String, dynamic>{'_cuerpo': texto, '_location': res.headers.value('location')}
          : Map<String, dynamic>.from(jsonDecode(texto) as Map);
      return (res.statusCode, d);
    } finally {
      c.close();
    }
  }

  setUpAll(() async {
    final bd = await Bd.abrir(url);
    await bd.ejecuta('drop schema if exists apk cascade');
    await bd.cerrar();
    dir = await Directory.systemTemp.createTemp('apk_hub');
    hub = await Hub.arranca(Config.desdeEntorno({
      'APK_DATABASE_URL': url,
      'APK_HOST': '127.0.0.1',
      'APK_PUERTO': '0',
      'APK_ARCHIVOS': '${dir.path}/archivos',
      'APK_MANAGER': '${dir.path}/sin-manager',
      'APK_SECRETO_JWT': 'secreto-de-prueba',
    }));
    base = 'http://127.0.0.1:${hub.puerto}';
    final org = await creaOrg(hub.bd, 'Prueba');
    final prefijo = Seguridad.hex(4);
    final secreto = Seguridad.token();
    await hub.bd.ejecuta(
      '''insert into apk.llave (org, nombre, prefijo, clave_hash, permisos)
         values (@o, 'admin', @p, @h, '{admin}')''',
      {'o': org, 'p': prefijo, 'h': Seguridad.hashToken(secreto)},
    );
    llave = 'cak_${prefijo}_$secreto';
  });

  tearDownAll(() async {
    await hub.detiene();
    await dir.delete(recursive: true);
  });

  test('publicar, consultar y bajar', () async {
    var (st, d) = await pide('POST', '/v1/apps', json: {'slug': 'inventario', 'nombre': 'Inventario'}, token: llave);
    expect(st, 201);

    (st, d) = await pide('POST', '/v1/apps/inventario/versiones?requerido=1', cuerpo: apk(10), token: llave);
    expect(st, 201, reason: '$d');
    expect(d['build'], 10);
    expect(d['paquete'], 'com.ejemplo.inventario');
    expect(d['firma'], sha256.convert(certA).toString());

    // La misma publicación otra vez: no es error.
    (st, d) = await pide('POST', '/v1/apps/inventario/versiones', cuerpo: apk(10), token: llave);
    expect(st, 200);
    expect(d['ya_estaba'], isTrue);

    (st, d) = await pide('POST', '/v1/apps/inventario/versiones', cuerpo: apk(11), token: llave);
    expect(st, 201);

    // Desde la 9 hay que pasar por la 10, que es obligatoria; desde la 10, no.
    (st, d) = await pide('POST', '/v1/apps/inventario/consulta', json: {'build': 9, 'instalacion': 'equipo-0001'});
    expect(d['actualizar'], isTrue);
    expect(d['requerido'], isTrue);
    expect(d['version']['build'], 11);
    (st, d) = await pide('GET', '/v1/apps/inventario/ultima?build=10');
    expect(d['actualizar'], isTrue);
    expect(d['requerido'], isFalse);

    // El APK que se baja es el que se subió.
    (st, d) = await pide('GET', '/install/inventario');
    expect(st, 302);
    final ruta = d['_location'] as String;
    final c = HttpClient();
    final res = await (await c.getUrl(Uri.parse('$base$ruta'))).close();
    final bajado = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    c.close();
    expect(sha256.convert(bajado).toString(), sha256.convert(apk(11)).toString());
  });

  test('rechaza otro paquete, otra firma y una build repetida con otro APK', () async {
    var (st, d) = await pide('POST', '/v1/apps/inventario/versiones',
        cuerpo: apk(12, paquete: 'com.ejemplo.otra'), token: llave);
    expect((st, d['error']), (409, 'paquete_distinto'));

    (st, d) = await pide('POST', '/v1/apps/inventario/versiones', cuerpo: apk(12, cert: certB), token: llave);
    expect((st, d['error']), (409, 'firma_distinta'));

    (st, d) = await pide('POST', '/v1/apps/inventario/versiones', cuerpo: apk(11, cert: certA)..[40] ^= 1, token: llave);
    expect(st, anyOf(409, 400));

    (st, d) = await pide('POST', '/v1/apps/inventario/versiones', cuerpo: apk(12));
    expect(st, 401);
  });

  test('retirar una versión la deja de ofrecer y de servir', () async {
    var (st, d) = await pide('GET', '/v1/apps/inventario/versiones', token: llave);
    final once = (d['versiones'] as List).firstWhere((v) => v['build'] == 11);
    (st, d) = await pide('PATCH', '/v1/apps/inventario/versiones/11', json: {'retirada': true}, token: llave);
    expect(st, 200);
    (st, d) = await pide('GET', '/v1/apps/inventario/ultima?build=0');
    expect(d['version']['build'], 10);
    (st, d) = await pide('GET', once['ruta'] as String);
    expect(st, 410);
    (st, d) = await pide('PATCH', '/v1/apps/inventario/versiones/11', json: {'retirada': false}, token: llave);
    expect(d['retirada'], isNull);
  });

  test('un equipo nuevo que abre el socket antes de su primera consulta queda conectado', () async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${hub.puerto}/v1/ws?app=inventario&instalacion=equipo-nuevo-01',
    );
    ws.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pide('POST', '/v1/apps/inventario/consulta', json: {'build': 1, 'instalacion': 'equipo-nuevo-01'});
    final (_, d) = await pide('GET', '/v1/apps/inventario/instalaciones', token: llave);
    final nuevo = (d['instalaciones'] as List).firstWhere((i) => i['clave'] == 'equipo-nuevo-01');
    expect(nuevo['conectado'], isTrue);
    await ws.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await hub.bd.ejecuta("delete from apk.instalacion where clave = 'equipo-nuevo-01'");
  });

  test('el WebSocket avisa al publicar y marca el equipo conectado', () async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${hub.puerto}/v1/ws?app=inventario&instalacion=equipo-0001',
    );
    final frames = <Map<String, dynamic>>[];
    final versionLlego = Completer<void>();
    ws.listen((m) {
      final f = Map<String, dynamic>.from(jsonDecode(m as String) as Map);
      frames.add(f);
      if (f['tipo'] == 'version' && !versionLlego.isCompleted) versionLlego.complete();
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    var (_, d) = await pide('GET', '/v1/apps/inventario/instalaciones', token: llave);
    expect((d['instalaciones'] as List).single['conectado'], isTrue);

    await pide('POST', '/v1/apps/inventario/versiones', cuerpo: apk(13), token: llave);
    await versionLlego.future.timeout(const Duration(seconds: 5));
    expect(frames.firstWhere((f) => f['tipo'] == 'version')['build'], 13);

    await ws.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    (_, d) = await pide('GET', '/v1/apps/inventario/instalaciones', token: llave);
    expect((d['instalaciones'] as List).single['conectado'], isFalse);
  });

  test('invitación: la persona pone su clave y entra', () async {
    var (st, d) = await pide('POST', '/v1/usuarios', json: {'correo': 'ana@prueba.test', 'rol': 'admin'}, token: llave);
    expect(st, 201);
    final token = (d['enlace'] as String).split('/activar/').last;

    (st, d) = await pide('POST', '/v1/auth/login', json: {'correo': 'ana@prueba.test', 'clave': 'lo-que-sea-123'});
    expect(st, 401, reason: 'sin activar no entra');

    (st, d) = await pide('GET', '/v1/auth/invitacion/$token');
    expect(d, {'correo': 'ana@prueba.test', 'vigente': true});

    (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'una-clave-larga'});
    expect(st, 200);
    (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'otra-clave-larga'});
    expect(st, 410, reason: 'el enlace es de un solo uso');

    (st, d) = await pide('POST', '/v1/auth/login', json: {'correo': 'ana@prueba.test', 'clave': 'una-clave-larga'});
    expect(st, 200);
    (st, d) = await pide('GET', '/v1/apps', token: d['token'] as String);
    expect((d['apps'] as List).single['slug'], 'inventario');
  });
}
