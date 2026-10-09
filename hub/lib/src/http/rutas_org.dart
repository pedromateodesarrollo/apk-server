import 'dart:convert';

import '../correo.dart';
import '../db.dart';
import 'servidor.dart';

/// Lo de la organización: hoy, su correo de salida (migración 0002).
///
/// Con él salen las invitaciones al panel y los enlaces de «¿Olvidaste tu
/// clave?». apk-server no usa el correo de ningún otro sistema: cada
/// organización pone el suyo. Solo lo toca quien administra, y la clave no
/// vuelve nunca: el panel sabe si está puesta, no cuál es.
void registraRutasOrg(Servidor s) {
  s.ruta('GET', '/v1/org/correo', (p) async {
    final c = await correoDeOrg(p.bd, p.s.org);
    return Respuesta.ok(c?.publico() ?? {'configurado': false});
  }, acceso: Acceso.admin);

  // Si la clave no viene, o viene vacía, se queda la que estaba: el panel no
  // la tiene para mandarla de vuelta. `{quitar: true}` lo borra.
  s.ruta('PUT', '/v1/org/correo', (p) async {
    if (p.cuerpo['quitar'] == true) {
      await p.bd.ejecuta("update apk.org set correo = '{}'::jsonb where id = @o", {'o': p.s.org});
      return Respuesta.ok({'configurado': false});
    }
    final actual = await correoDeOrg(p.bd, p.s.org);
    final host = p.texto('host').toLowerCase();
    final puerto = p.entero('puerto') ?? 0;
    final seguridad = p.texto('seguridad', porDefecto: 'starttls');
    final remitente = p.texto('remitente').toLowerCase();
    if (host.isEmpty || host.contains(RegExp(r'[\s/:@]'))) {
      return Respuesta.falla(400, 'host_invalido', 'El servidor es un nombre como smtp.gmail.com');
    }
    if (puerto < 1 || puerto > 65535) {
      return Respuesta.falla(400, 'puerto_invalido', 'El puerto va de 1 a 65535 (suele ser 465 o 587)');
    }
    if (!ConfigCorreo.seguridades.contains(seguridad)) {
      return Respuesta.falla(400, 'seguridad_invalida', 'La seguridad es tls, starttls o ninguna');
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(remitente)) {
      return Respuesta.falla(400, 'remitente_invalido', 'El remitente es una dirección de correo');
    }
    final clave = p.texto('clave').isNotEmpty ? p.texto('clave') : (actual?.clave ?? '');
    final c = ConfigCorreo(
      host: host,
      puerto: puerto,
      seguridad: seguridad,
      remitente: remitente,
      usuario: p.texto('usuario'),
      clave: clave,
      nombre: p.texto('nombre'),
    );
    await p.bd.ejecuta(
      'update apk.org set correo = @c::jsonb where id = @o',
      {'c': jsonEncode(c.aJson()), 'o': p.s.org},
    );
    return Respuesta.ok(c.publico());
  }, acceso: Acceso.admin);

  // Manda un correo de prueba a quien lo pide: si llega, las invitaciones y
  // los enlaces de clave nueva también llegarán. Si no, dice qué contestó el
  // servidor.
  s.ruta('POST', '/v1/org/correo/prueba', (p) async {
    final c = await correoDeOrg(p.bd, p.s.org);
    if (c == null || !c.completa) {
      return Respuesta.falla(400, 'correo_sin_configurar', 'Primero guarda el correo de salida');
    }
    final yo = p.s.esUsuario
        ? await p.bd.fila('select correo from apk.usuario where id = @u', {'u': p.s.usuario})
        : null;
    final para = (yo?['correo'] ?? '').toString();
    if (!para.contains('@')) {
      return Respuesta.falla(400, 'sin_destinatario', 'La prueba va al correo de quien la pide: entra con tu usuario');
    }
    try {
      await enviaCorreo(
        c,
        para: para,
        asunto: 'Prueba del correo de apk-server',
        texto: 'Si lees esto, el correo de salida de tu organización funciona: '
            'las invitaciones al panel y los enlaces para poner una clave nueva saldrán por aquí.',
      );
    } on CorreoError catch (e) {
      return Respuesta.falla(502, e.codigo, e.detalle);
    }
    return Respuesta.ok({'enviado': true, 'para': para});
  }, acceso: Acceso.admin);
}

/// El correo de salida de [org], o null si no tiene (o le falta algo para
/// estar entero: mirar [ConfigCorreo.completa] antes de mandar).
Future<ConfigCorreo?> correoDeOrg(Bd bd, int org) async =>
    ConfigCorreo.deJson((await bd.fila('select correo from apk.org where id = @o', {'o': org}))?['correo']);

/// Si alguna organización del hub tiene el correo de salida entero. Es lo que
/// decide si la entrada del panel ofrece «¿Olvidaste tu clave?»: sin ningún
/// correo, el enlace no le llegaría a nadie.
Future<bool> hayCorreoDeSalida(Bd bd) async {
  final filas = await bd.filas("select correo from apk.org where correo <> '{}'::jsonb");
  return filas.any((f) => ConfigCorreo.deJson(f['correo'])?.completa ?? false);
}
