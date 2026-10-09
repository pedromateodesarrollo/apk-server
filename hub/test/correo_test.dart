import 'dart:convert';

import 'package:apk_server_hub/src/correo.dart';
import 'package:test/test.dart';

import 'smtp_falso.dart';

/// El cliente SMTP del hub (`lib/src/correo.dart`) contra un servidor falso:
/// no hace falta base ni red.
void main() {
  late SmtpFalso smtp;
  setUp(() async => smtp = await SmtpFalso.arranca());
  tearDown(() => smtp.cierra());

  ConfigCorreo config({String seguridad = 'ninguna', String usuario = 'avisos@ejemplo.do'}) => ConfigCorreo(
    host: '127.0.0.1',
    puerto: smtp.puerto,
    seguridad: seguridad,
    remitente: 'avisos@ejemplo.do',
    usuario: usuario,
    clave: 'clave-secreta',
    nombre: 'apk-server de Duralon',
  );

  test('manda el correo: autentica, y el mensaje lleva acentos y las dos partes', () async {
    await enviaCorreo(
      config(),
      para: 'ana@ejemplo.do',
      asunto: 'Invitación al panel',
      texto: 'Hola, Ana:\n.una línea que empieza con punto',
      html: '<p>Hola, <strong>Ana</strong></p>',
    );
    expect(smtp.ordenes.first, startsWith('EHLO '));
    final auth = smtp.ordenes.firstWhere((o) => o.startsWith('AUTH PLAIN '));
    expect(utf8.decode(base64.decode(auth.substring(11))), '\u0000avisos@ejemplo.do\u0000clave-secreta');
    expect(smtp.ordenes, containsAll(['MAIL FROM:<avisos@ejemplo.do>', 'RCPT TO:<ana@ejemplo.do>', 'DATA']));
    final m = smtp.mensajes.single;
    expect(m, contains('Subject: =?UTF-8?B?${base64.encode(utf8.encode('Invitación al panel'))}?='));
    expect(m, contains('From: "apk-server de Duralon" <avisos@ejemplo.do>'));
    expect(SmtpFalso.parte(m, 'text/plain'), 'Hola, Ana:\n.una línea que empieza con punto');
    expect(SmtpFalso.parte(m, 'text/html'), '<p>Hola, <strong>Ana</strong></p>');
  });

  test('sin usuario no autentica', () async {
    await enviaCorreo(config(usuario: ''), para: 'ana@ejemplo.do', asunto: 'a', texto: 'b');
    expect(smtp.ordenes.where((o) => o.startsWith('AUTH')), isEmpty);
    expect(smtp.mensajes, hasLength(1));
  });

  test('autenticación rechazada: su código, y la clave no aparece en el detalle', () async {
    smtp.rechazaAuth = true;
    await expectLater(
      enviaCorreo(config(), para: 'ana@ejemplo.do', asunto: 'a', texto: 'b'),
      throwsA(isA<CorreoError>()
          .having((e) => e.codigo, 'codigo', 'correo_autenticacion')
          .having((e) => e.detalle, 'detalle', isNot(contains('clave-secreta')))
          .having((e) => e.detalle, 'detalle', isNot(contains(base64.encode(utf8.encode('clave-secreta')))))),
    );
    expect(smtp.mensajes, isEmpty);
  });

  test('STARTTLS pedido y el servidor no lo ofrece: no manda nada en claro', () async {
    await expectLater(
      enviaCorreo(config(seguridad: 'starttls'), para: 'ana@ejemplo.do', asunto: 'a', texto: 'b'),
      throwsA(isA<CorreoError>().having((e) => e.codigo, 'codigo', 'correo_sin_starttls')),
    );
    expect(smtp.ordenes.where((o) => o.startsWith('AUTH')), isEmpty);
  });

  test('sin servidor que conteste: correo_conexion', () async {
    final puerto = smtp.puerto;
    await smtp.cierra();
    await expectLater(
      enviaCorreo(
        ConfigCorreo(host: '127.0.0.1', puerto: puerto, seguridad: 'ninguna', remitente: 'a@b.do'),
        para: 'ana@ejemplo.do',
        asunto: 'a',
        texto: 'b',
      ),
      throwsA(isA<CorreoError>().having((e) => e.codigo, 'codigo', 'correo_conexion')),
    );
  });

  test('lo que ve el panel no lleva la clave', () {
    final p = config().publico();
    expect(p.containsKey('clave'), isFalse);
    expect(p['clave_puesta'], isTrue);
    expect(p['configurado'], isTrue);
    expect(jsonEncode(p), isNot(contains('clave-secreta')));
  });
}
