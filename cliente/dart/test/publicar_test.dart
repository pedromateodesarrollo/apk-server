import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_server/apk_info.dart';
import 'package:apk_server/apk_sintetico.dart';
import 'package:apk_server/publicar.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer hub;
  late String url;
  late Directory carpeta;
  final pedidos = <(String, Map<String, String>, int, String?)>[];
  var respuesta = (201, <String, Object?>{'paquete': 'com.ejemplo.inv', 'version': '1.5.0', 'build': 84, 'avisadas': 3});

  setUp(() async {
    pedidos.clear();
    respuesta = (201, {'paquete': 'com.ejemplo.inv', 'version': '1.5.0', 'build': 84, 'avisadas': 3});
    hub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${hub.port}';
    hub.listen((r) async {
      final cuerpo = await r.fold<List<int>>([], (a, b) => a..addAll(b));
      pedidos.add((r.uri.path, r.uri.queryParameters, cuerpo.length, r.headers.value('authorization')));
      r.response
        ..statusCode = respuesta.$1
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(respuesta.$2));
      await r.response.close();
    });
    carpeta = await Directory.systemTemp.createTemp('publicar');
  });

  tearDown(() async {
    await hub.close(force: true);
    await carpeta.delete(recursive: true);
  });

  /// Un APK de la app [app] que pregunta a [hubApk] (null = sin la biblioteca).
  String apk(String nombre, {String? hubApk, String app = 'inventario', int build = 84}) {
    final f = File('${carpeta.path}/$nombre');
    f.writeAsBytesSync(apkSintetico({
      'AndroidManifest.xml': manifiestoSintetico(
        paquete: 'com.ejemplo.inv',
        build: build,
        version: '1.5.0',
        metadatos: hubApk == null ? const {} : {ApkInfo.metaHub: hubApk, ApkInfo.metaApp: app},
      ),
    }));
    return f.path;
  }

  Future<(int, String, String)> correr(List<String> args, {String? llave = 'cak_prueba'}) async {
    final out = StringBuffer(), err = StringBuffer();
    final c = await publicarCli(
      args,
      entorno: {if (llave != null) 'APK_SERVER_LLAVE': llave},
      salida: out,
      errores: err,
    );
    return (c, '$out', '$err');
  }

  test('sube al hub y a la app que dice el APK, con la llave y la build', () async {
    final a = apk('app.apk', hubApk: '$url/');
    final (c, out, err) = await correr(['--apk', a, '--notas', 'Arreglos de la toma', '--requerido']);
    expect(c, 0, reason: err);
    expect(pedidos, hasLength(1));
    final (ruta, q, bytes, auth) = pedidos.single;
    expect(ruta, '/v1/apps/inventario/versiones');
    expect(q, {'build': '84', 'version': '1.5.0', 'notas': 'Arreglos de la toma', 'requerido': '1'});
    expect(bytes, File(a).lengthSync());
    expect(auth, 'Bearer cak_prueba');
    expect(out, contains('avisados: 3'));
    expect(out, contains('$url/i/inventario'));
  });

  test('dos sabores: cada uno a su app', () async {
    final uno = apk('chalona.apk', hubApk: url, app: 'wms');
    final otro = apk('duralon.apk', hubApk: url, app: 'wms-duralon');
    final (c, _, err) = await correr(['--apk', uno, '--apk', otro]);
    expect(c, 0, reason: err);
    expect(pedidos.map((p) => p.$1), ['/v1/apps/wms/versiones', '/v1/apps/wms-duralon/versiones']);
  });

  test('si uno no cuadra, no se sube ninguno', () async {
    final uno = apk('chalona.apk', hubApk: url, app: 'wms');
    final malo = apk('viejo.apk', hubApk: url, app: 'wms', build: 80);
    final (c, _, err) = await correr(['--apk', uno, '--apk', malo, '--build', '84']);
    expect(c, isNot(0));
    expect(err, contains('versionCode 80, no 84'));
    expect(pedidos, isEmpty);
  });

  test('--app distinto del APK: no sube', () async {
    final a = apk('app.apk', hubApk: url, app: 'wms-duralon');
    final (c, _, err) = await correr(['--apk', a, '--app', 'wms']);
    expect(c, isNot(0));
    expect(err, contains('es de la app «wms-duralon», no de «wms»'));
    expect(pedidos, isEmpty);
  });

  test('un APK sin la biblioteca pide --hub y --app', () async {
    final a = apk('viejo.apk');
    var (c, _, err) = await correr(['--apk', a]);
    expect(c, isNot(0));
    expect(err, contains('manifestPlaceholders["apkServerHub"]'));
    (c, _, err) = await correr(['--apk', a, '--hub', url, '--app', 'inventario']);
    expect(c, 0, reason: err);
    expect(pedidos.single.$1, '/v1/apps/inventario/versiones');
  });

  test('compilado sin hub: no se publica', () async {
    final a = apk('sin-hub.apk', hubApk: '');
    final (c, _, err) = await correr(['--apk', a]);
    expect(c, isNot(0));
    expect(err, contains('sin hub'));
  });

  test('sin llave no sube; con --simular no hace falta', () async {
    final a = apk('app.apk', hubApk: url);
    var (c, out, err) = await correr(['--apk', a], llave: null);
    expect(c, 64);
    expect(err, contains('Falta la llave'));
    (c, out, err) = await correr(['--apk', a, '--simular'], llave: null);
    expect(c, 0);
    expect(out, contains('a $url, app «inventario»'));
    expect(pedidos, isEmpty);
  });

  test('lo que rechaza el hub sale con su motivo', () async {
    respuesta = (409, {'error': 'firma_distinta', 'mensaje': 'Ese APK está firmado con otra llave.'});
    final a = apk('app.apk', hubApk: url);
    final (c, _, err) = await correr(['--apk', a]);
    expect(c, 1);
    expect(err, contains('firma_distinta'));
    expect(err, contains('otra llave'));
  });

  test('repetir la misma publicación lo dice', () async {
    respuesta = (200, {'paquete': 'com.ejemplo.inv', 'version': '1.5.0', 'build': 84, 'ya_estaba': true});
    final (c, out, _) = await correr(['--apk', apk('app.apk', hubApk: url)]);
    expect(c, 0);
    expect(out, contains('(ya estaba)'));
  });

  test('lo que no es un APK', () async {
    final f = File('${carpeta.path}/nada.apk')..writeAsBytesSync(Uint8List(100));
    final (c, _, err) = await correr(['--apk', f.path]);
    expect(c, isNot(0));
    expect(err, contains('No es un APK'));
  });
}
