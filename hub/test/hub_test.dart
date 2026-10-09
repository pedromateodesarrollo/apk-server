@Tags(['bd'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_server/apk_sintetico.dart';
import 'package:apk_server_hub/hub.dart';
import 'package:apk_server_hub/src/http/rutas_auth.dart';
import 'package:apk_server_hub/src/seguridad.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'smtp_falso.dart';

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
  late int org;

  final certA = Uint8List.fromList(utf8.encode('certificado A'));
  final certB = Uint8List.fromList(utf8.encode('certificado B'));

  Uint8List apk(
    int build, {
    String paquete = 'com.ejemplo.inventario',
    Uint8List? cert,
    Map<String, String> metadatos = const {},
  }) =>
      apkSintetico(
        {
          'AndroidManifest.xml':
              manifiestoSintetico(paquete: paquete, build: build, version: '1.$build.0', metadatos: metadatos),
        },
        certificado: cert ?? certA,
      );

  Future<(int, Map<String, dynamic>)> pide(
    String metodo,
    String ruta, {
    Object? json,
    List<int>? cuerpo,
    String? token,
    String? ip,
  }) async {
    final c = HttpClient();
    try {
      final r = await c.openUrl(metodo, Uri.parse('$base$ruta'));
      r.followRedirects = false;
      if (token != null) r.headers.set('authorization', 'Bearer $token');
      // Como si viniera por nginx desde otra IP: los frenos van por IP, y
      // todas las pruebas salen de 127.0.0.1.
      if (ip != null) r.headers.set('x-real-ip', ip);
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
    // La URL pública va fijada, como en producción (sin ella no hay
    // «¿Olvidaste tu clave?»), y con el puerto en que de verdad escucha: un
    // puerto libre que se reserva antes.
    final libre = await ServerSocket.bind('127.0.0.1', 0);
    final puerto = libre.port;
    await libre.close();
    hub = await Hub.arranca(Config.desdeEntorno({
      'APK_DATABASE_URL': url,
      'APK_HOST': '127.0.0.1',
      'APK_PUERTO': '$puerto',
      'APK_ARCHIVOS': '${dir.path}/archivos',
      'APK_MANAGER': '${dir.path}/sin-manager',
      'APK_SECRETO_JWT': 'secreto-de-prueba',
      'APK_URL_PUBLICA': 'http://127.0.0.1:$puerto',
    }));
    base = 'http://127.0.0.1:${hub.puerto}';
    org = await creaOrg(hub.bd, 'Prueba');
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

  test('el APK que dice de qué app y de qué hub es solo se publica ahí', () async {
    var (st, d) = await pide('POST', '/v1/apps', json: {'slug': 'almacen', 'nombre': 'Almacén'}, token: llave);
    expect(st, 201);
    Uint8List de(String app, String hubApk) => apk(
          5,
          paquete: 'com.ejemplo.almacen',
          metadatos: {ApkInfo.metaHub: hubApk, ApkInfo.metaApp: app},
        );

    (st, d) = await pide('POST', '/v1/apps/almacen/versiones', cuerpo: de('almacen-marca', base), token: llave);
    expect(st, 409);
    expect(d['error'], 'app_distinta');

    (st, d) = await pide('POST', '/v1/apps/almacen/versiones',
        cuerpo: de('almacen', 'https://otro-hub.ejemplo.com'), token: llave);
    expect(st, 409);
    expect(d['error'], 'hub_distinto');

    // Con la barra al final y el host en mayúsculas es el mismo hub.
    (st, d) = await pide('POST', '/v1/apps/almacen/versiones',
        cuerpo: de('almacen', '${base.toUpperCase().replaceFirst('HTTP', 'http')}/'), token: llave);
    expect(st, 201, reason: '$d');
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
    expect([for (final a in d['apps'] as List) a['slug']], contains('inventario'));
  });

  // ------------------------------------- correo de salida y «¿Olvidaste tu clave?»

  /// Una persona con su clave puesta y una sesión suya, sin pasar por el login
  /// (que tiene su propio freno).
  Future<(int, String)> persona(String correo, String rol, {String clave = 'clave-de-prueba', int? enOrg}) async {
    final o = enOrg ?? org;
    final u = await hub.bd.fila(
      '''insert into apk.usuario (org, correo, clave_hash, nombre, rol)
         values (@o, @c, @h, @n, @r) returning id''',
      {
        'o': o,
        'c': correo,
        'h': Seguridad.hashClave(clave, iteraciones: 1000),
        'n': correo.split('@').first,
        'r': rol,
      },
    );
    final id = u!['id'] as int;
    return (id, Seguridad.firmaJwt({'sub': id, 'org': o, 'rol': rol}, 'secreto-de-prueba'));
  }

  Future<String?> enlaceGuardado(int usuario) async =>
      (await hub.bd.fila('select invitacion_hash from apk.usuario where id = @i', {'i': usuario}))?['invitacion_hash']
          as String?;

  /// Pide «¿Olvidaste tu clave?» y comprueba que contesta lo de siempre: exista
  /// o no la cuenta, la respuesta es la misma.
  Future<void> recupera(String correo, {required String ip}) async {
    final (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': correo}, ip: ip);
    expect(st, 200, reason: '$d');
    expect(d, {'pedido': true});
  }

  /// El correo de «¿Olvidaste tu clave?» sale sin que la respuesta lo espere.
  Future<void> esperaCorreos(SmtpFalso smtp, int n) async {
    final fin = DateTime.now().add(const Duration(seconds: 5));
    while (smtp.mensajes.length < n) {
      if (DateTime.now().isAfter(fin)) fail('esperaba $n correos y llegaron ${smtp.mensajes.length}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('correo de salida: solo quien administra, la clave no vuelve, y la invitación sale por él', () async {
    final smtp = await SmtpFalso.arranca();
    try {
      final (_, admin) = await persona('jefa@prueba.test', 'admin');
      final (idEditor, editor) = await persona('editor@prueba.test', 'editor');

      // Sin correo de salida, invitar es solo el enlace.
      var (st, d) = await pide('POST', '/v1/usuarios', json: {'correo': 'sin-correo@prueba.test'}, token: admin);
      expect(st, 201, reason: '$d');
      expect(d['envio'], isNull);
      expect(d['enlace'], contains('/#/activar/'));
      (st, d) = await pide('GET', '/v1/org/correo', token: admin);
      expect(d, {'configurado': false});

      final config = {
        'host': '127.0.0.1',
        'puerto': smtp.puerto,
        'seguridad': 'ninguna',
        'remitente': 'Avisos@Prueba.test',
        'usuario': 'avisos',
        'clave': 'secreto-smtp',
        'nombre': 'apk-server de Prueba',
      };
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'host': 'smtp mal'}, token: admin);
      expect((st, d['error']), (400, 'host_invalido'));
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'seguridad': 'ssl3'}, token: admin);
      expect(d['error'], 'seguridad_invalida');
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'puerto': 0}, token: admin);
      expect(d['error'], 'puerto_invalido');
      (st, d) = await pide('PUT', '/v1/org/correo', json: {...config, 'remitente': 'avisos'}, token: admin);
      expect(d['error'], 'remitente_invalido');
      (st, _) = await pide('PUT', '/v1/org/correo', json: config, token: editor);
      expect(st, 403);
      (st, _) = await pide('GET', '/v1/org/correo', token: editor);
      expect(st, 403);

      (st, d) = await pide('PUT', '/v1/org/correo', json: config, token: admin);
      expect(st, 200, reason: '$d');
      expect(d['remitente'], 'avisos@prueba.test');
      expect(d['clave_puesta'], isTrue);
      expect(d['configurado'], isTrue);
      expect(jsonEncode(d), isNot(contains('secreto-smtp')));
      // Guardar sin clave deja la que estaba.
      (st, d) = await pide('PUT', '/v1/org/correo',
          json: {...config, 'clave': '', 'nombre': 'Avisos de Prueba'}, token: admin);
      expect(d['clave_puesta'], isTrue);
      (st, d) = await pide('GET', '/v1/org/correo', token: admin);
      expect(d['configurado'], isTrue);
      expect(d['nombre'], 'Avisos de Prueba');
      expect(d.containsKey('clave'), isFalse);
      expect(jsonEncode(d), isNot(contains('secreto-smtp')));

      // La prueba va a quien la pide (con la clave de antes); una llave no
      // tiene a quién.
      (st, d) = await pide('POST', '/v1/org/correo/prueba', token: admin);
      expect(st, 200, reason: '$d');
      expect(d['para'], 'jefa@prueba.test');
      expect(smtp.ordenes, contains('RCPT TO:<jefa@prueba.test>'));
      final auth = smtp.ordenes.lastWhere((o) => o.startsWith('AUTH PLAIN '));
      expect(utf8.decode(base64.decode(auth.substring(11))), '\u0000avisos\u0000secreto-smtp');
      (st, d) = await pide('POST', '/v1/org/correo/prueba', token: llave);
      expect((st, d['error']), (400, 'sin_destinatario'));

      (st, d) = await pide('POST', '/v1/usuarios',
          json: {'correo': 'nueva@prueba.test', 'nombre': 'Nueva'}, token: admin);
      expect(st, 201, reason: '$d');
      expect(d['envio'], {'enviado': true, 'para': 'nueva@prueba.test'});
      final enlace = d['enlace'] as String;
      final nueva = d['id'];
      var m = smtp.mensajes.last;
      expect(m, contains('From: "Avisos de Prueba" <avisos@prueba.test>'));
      expect(SmtpFalso.parte(m, 'text/plain'), allOf(contains(enlace), contains('Te invitaron'), contains('7 días')));
      expect(SmtpFalso.parte(m, 'text/html'), contains(enlace));

      // A quien ya entraba, el enlace de quien administra es para una clave nueva.
      (st, d) = await pide('POST', '/v1/usuarios/$idEditor/invitacion', token: admin);
      expect(d['envio'], {'enviado': true, 'para': 'editor@prueba.test'});
      m = smtp.mensajes.last;
      expect(m, contains('Subject: Clave nueva para el panel de apk-server'));
      expect(SmtpFalso.parte(m, 'text/plain'), contains(d['enlace'] as String));

      // Si el servidor rechaza, la invitación queda y el enlace sirve igual.
      smtp.rechazaAuth = true;
      (st, d) = await pide('POST', '/v1/usuarios/$nueva/invitacion', token: admin);
      expect(st, 200, reason: '$d');
      expect(d['envio']['enviado'], isFalse);
      expect(d['envio']['error'], 'correo_autenticacion');
      expect(d['enlace'], contains('/#/activar/'));

      (st, d) = await pide('PUT', '/v1/org/correo', json: {'quitar': true}, token: admin);
      expect(d, {'configurado': false});
      (st, d) = await pide('GET', '/v1/org/correo', token: admin);
      expect(d['configurado'], isFalse);
    } finally {
      await smtp.cierra();
    }
  });

  test('«¿Olvidaste tu clave?»: el enlace llega por el correo de salida de su organización', () async {
    final smtp = await SmtpFalso.arranca();
    try {
      // Ninguna organización con correo de salida: la entrada no lo ofrece, y
      // pedirlo contesta lo mismo que con un correo sin cuenta y no toca nada.
      var (st, d) = await pide('GET', '/salud');
      expect(d['recuperar'], isFalse);
      final (olvido, _) = await persona('olvido@prueba.test', 'editor', clave: 'la-clave-de-antes');
      await recupera('nadie@prueba.test', ip: '10.0.1.1');
      await recupera('olvido@prueba.test', ip: '10.0.1.1');
      expect(await enlaceGuardado(olvido), isNull);

      // Con correo de salida en una organización, la entrada lo ofrece; pero
      // a quien es de otra sin correo tampoco le llega nada.
      final otraOrg = await creaOrg(hub.bd, 'Sin correo');
      final (deOtra, _) = await persona('alguien@sin-correo.test', 'admin', enOrg: otraOrg);
      (st, d) = await pide('PUT', '/v1/org/correo',
          json: {'host': '127.0.0.1', 'puerto': smtp.puerto, 'seguridad': 'ninguna', 'remitente': 'avisos@prueba.test'},
          token: llave);
      expect(st, 200, reason: '$d');
      (st, d) = await pide('GET', '/salud');
      expect(d['recuperar'], isTrue);
      await recupera('alguien@sin-correo.test', ip: '10.0.1.2');
      await recupera('nadie@prueba.test', ip: '10.0.1.2');

      // A quien sí: un correo con el enlace, que vence en una hora.
      await recupera(' Olvido@Prueba.test ', ip: '10.0.1.2');
      await esperaCorreos(smtp, 1);
      final m = smtp.mensajes.single;
      expect(m, contains('Subject: Clave nueva para el panel de apk-server'));
      expect(smtp.ordenes.where((o) => o.startsWith('RCPT')), ['RCPT TO:<olvido@prueba.test>']);
      final texto = SmtpFalso.parte(m, 'text/plain');
      expect(texto, contains('Pediste poner una clave nueva'));
      expect(texto, contains('vence en 1 hora'));
      expect(texto, contains('Si no lo pediste tú, ignora este correo: tu clave sigue igual.'));
      final enlace = RegExp(r'\S+/#/activar/\S+').firstMatch(texto)!.group(0)!;
      expect(enlace, startsWith('$base/#/activar/'));
      expect(SmtpFalso.parte(m, 'text/html'), contains(enlace));
      final vence = (await hub.bd.fila('select invitacion_vence from apk.usuario where id = @i', {'i': olvido}))!
          ['invitacion_vence'] as DateTime;
      expect(vence.difference(DateTime.now()).inMinutes, inInclusiveRange(58, 60));
      expect(await enlaceGuardado(deOtra), isNull);

      // Con ese enlace pone la clave nueva y entra con ella; la de antes ya no vale.
      final token = enlace.split('/activar/').last;
      (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'la-clave-nueva'}, ip: '10.0.1.3');
      expect(st, 200, reason: '$d');
      (st, d) = await pide('POST', '/v1/auth/login',
          json: {'correo': 'olvido@prueba.test', 'clave': 'la-clave-de-antes'}, ip: '10.0.1.3');
      expect(st, 401);
      (st, d) = await pide('POST', '/v1/auth/login',
          json: {'correo': 'olvido@prueba.test', 'clave': 'la-clave-nueva'}, ip: '10.0.1.3');
      expect(st, 200, reason: '$d');
      expect(d['usuario']['id'], olvido);

      // De un solo uso, y el mensaje dice cómo pedir otro.
      (st, d) = await pide('POST', '/v1/auth/activar', json: {'token': token, 'clave': 'otra-clave-mas'}, ip: '10.0.1.3');
      expect(st, 410);
      expect(d['mensaje'], contains('«¿Olvidaste tu clave?»'));

      expect(smtp.mensajes, hasLength(1), reason: 'a nadie más le llegó nada');
      await pide('PUT', '/v1/org/correo', json: {'quitar': true}, token: llave);
      (st, d) = await pide('GET', '/salud');
      expect(d['recuperar'], isFalse);
    } finally {
      await smtp.cierra();
    }
  });

  test('«¿Olvidaste tu clave?» tiene freno: 3 por hora por correo y 5 por minuto por IP', () async {
    // El cuarto del mismo correo en la hora, aunque llegue de otra IP. Y sin
    // cuenta detrás: el freno no dice si el correo existe.
    for (var i = 1; i <= 3; i++) {
      await recupera('freno@prueba.test', ip: '10.0.2.$i');
    }
    var (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'freno@prueba.test'}, ip: '10.0.2.9');
    expect((st, d['error']), (429, 'demasiados_intentos'));
    expect(d['mensaje'], contains('una hora'));

    // Seis seguidos desde la misma IP, cada uno con otro correo: el sexto no.
    for (var i = 1; i <= 5; i++) {
      await recupera('ip$i@prueba.test', ip: '10.0.3.1');
    }
    (st, d) = await pide('POST', '/v1/auth/recuperar', json: {'correo': 'ip6@prueba.test'}, ip: '10.0.3.1');
    expect((st, d['error']), (429, 'demasiados_intentos'));
    expect(d['mensaje'], contains('un minuto'));
  });
}
