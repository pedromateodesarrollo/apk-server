import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Un servidor SMTP de mentira, sin cifrar, para las pruebas: anota cada orden
/// y cada mensaje que recibe. [rechazaAuth] contesta 535 a la autenticación;
/// [sinStarttls] no lo ofrece en el EHLO (y [ofreceStarttls] sí, para ver que
/// el cliente lo pide).
class SmtpFalso {
  SmtpFalso._(this._srv);

  final ServerSocket _srv;
  final ordenes = <String>[];
  final mensajes = <String>[];
  bool rechazaAuth = false;
  bool ofreceStarttls = false;

  int get puerto => _srv.port;

  static Future<SmtpFalso> arranca() async {
    final f = SmtpFalso._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    f._srv.listen(f._atiende);
    return f;
  }

  void _atiende(Socket s) {
    var enDatos = false;
    final datos = StringBuffer();
    var pendiente = '';
    s.write('220 falso listo\r\n');
    s.listen((bytes) {
      pendiente += utf8.decode(bytes);
      while (true) {
        if (enDatos) {
          final fin = pendiente.indexOf('\r\n.\r\n');
          if (fin < 0) return;
          datos.write(pendiente.substring(0, fin));
          pendiente = pendiente.substring(fin + 5);
          mensajes.add(datos.toString());
          datos.clear();
          enDatos = false;
          s.write('250 en cola\r\n');
          continue;
        }
        final i = pendiente.indexOf('\r\n');
        if (i < 0) return;
        final l = pendiente.substring(0, i);
        pendiente = pendiente.substring(i + 2);
        ordenes.add(l);
        final o = l.toUpperCase();
        if (o.startsWith('EHLO')) {
          s.write('250-falso\r\n${ofreceStarttls ? '250-STARTTLS\r\n' : ''}250 AUTH PLAIN LOGIN\r\n');
        } else if (o.startsWith('AUTH')) {
          s.write(rechazaAuth ? '535 5.7.8 credenciales no aceptadas\r\n' : '235 adelante\r\n');
        } else if (o.startsWith('MAIL') || o.startsWith('RCPT')) {
          s.write('250 ok\r\n');
        } else if (o == 'DATA') {
          enDatos = true;
          s.write('354 manda\r\n');
        } else if (o == 'QUIT') {
          s.write('221 adios\r\n');
          s.close();
          return;
        } else {
          s.write('502 no\r\n');
        }
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  /// El texto de una parte en base64 de [mensaje] (`text/plain` o `text/html`).
  static String parte(String mensaje, String tipo) {
    final i = mensaje.indexOf('Content-Type: $tipo');
    if (i < 0) return '';
    final cuerpo = mensaje.substring(mensaje.indexOf('\r\n\r\n', i) + 4);
    final fin = cuerpo.indexOf('--');
    final b64 = (fin < 0 ? cuerpo : cuerpo.substring(0, fin)).replaceAll(RegExp(r'\s'), '');
    return utf8.decode(base64.decode(b64));
  }

  Future<void> cierra() => _srv.close();
}
