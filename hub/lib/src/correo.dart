import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// El correo de salida de una organización: con él salen las invitaciones al
/// panel y los enlaces de «¿Olvidaste tu clave?». apk-server no depende de
/// ningún otro sistema, así que cada organización pone el suyo (Organización →
/// Correo de salida).
///
/// SMTP a mano con `dart:io`, como el resto del hub (dos dependencias a
/// propósito): TLS directo (465), STARTTLS (587) o sin cifrar (solo para una
/// red propia), autenticación PLAIN o LOGIN, y el mensaje en texto y HTML con
/// acentos (UTF-8 en base64).
class ConfigCorreo {
  const ConfigCorreo({
    required this.host,
    required this.puerto,
    required this.seguridad,
    required this.remitente,
    this.usuario = '',
    this.clave = '',
    this.nombre = '',
  });

  final String host;
  final int puerto;

  /// `tls` (TLS desde el principio, 465), `starttls` (587) o `ninguna`.
  final String seguridad;

  /// La dirección que va en el «De:» y en `MAIL FROM`.
  final String remitente;
  final String usuario;
  final String clave;

  /// El nombre que se ve en el «De:» (`apk-server de Duralon`).
  final String nombre;

  static const seguridades = ['tls', 'starttls', 'ninguna'];

  bool get completa => host.isNotEmpty && puerto > 0 && remitente.contains('@');

  /// Lo que se guarda en `apk.org.correo`.
  Map<String, Object?> aJson() => {
    'host': host,
    'puerto': puerto,
    'seguridad': seguridad,
    'remitente': remitente,
    'usuario': usuario,
    'clave': clave,
    'nombre': nombre,
  };

  /// Lo que ve el panel: todo menos la clave.
  Map<String, Object?> publico() => {
    'host': host,
    'puerto': puerto,
    'seguridad': seguridad,
    'remitente': remitente,
    'usuario': usuario,
    'nombre': nombre,
    'clave_puesta': clave.isNotEmpty,
    'configurado': completa,
  };

  static ConfigCorreo? deJson(Object? j) {
    if (j is! Map || (j['host'] ?? '').toString().isEmpty) return null;
    return ConfigCorreo(
      host: '${j['host']}',
      puerto: j['puerto'] is num ? (j['puerto'] as num).toInt() : int.tryParse('${j['puerto']}') ?? 0,
      seguridad: '${j['seguridad'] ?? 'starttls'}',
      remitente: '${j['remitente'] ?? ''}',
      usuario: '${j['usuario'] ?? ''}',
      clave: '${j['clave'] ?? ''}',
      nombre: '${j['nombre'] ?? ''}',
    );
  }
}

/// Un correo que no salió. [codigo] es para la API; [detalle], lo que dijo el
/// servidor (sin la clave: nunca se repite lo que se mandó al autenticar).
class CorreoError implements Exception {
  CorreoError(this.codigo, this.detalle);
  final String codigo;
  final String detalle;

  @override
  String toString() => 'CorreoError($codigo: $detalle)';
}

/// Manda un correo por [c]. Lanza [CorreoError] si el servidor no lo acepta.
Future<void> enviaCorreo(
  ConfigCorreo c, {
  required String para,
  required String asunto,
  required String texto,
  String? html,
  Duration espera = const Duration(seconds: 30),
}) async {
  if (!c.completa) throw CorreoError('correo_sin_configurar', 'Falta el servidor o el remitente');
  final mensaje = armaMensaje(
    de: c.remitente,
    nombreDe: c.nombre,
    para: para,
    asunto: asunto,
    texto: texto,
    html: html,
  );
  final s = _Smtp(c.host, espera);
  try {
    await s.conecta(c.puerto, tls: c.seguridad == 'tls');
    await s.espera(220);
    var ehlo = await s.orden('EHLO ${_nombreLocal()}', 250);
    if (c.seguridad == 'starttls') {
      if (!ehlo.any((l) => l.toUpperCase().contains('STARTTLS'))) {
        throw CorreoError('correo_sin_starttls', 'El servidor no ofrece STARTTLS en el puerto ${c.puerto}');
      }
      await s.orden('STARTTLS', 220);
      await s.aTls();
      ehlo = await s.orden('EHLO ${_nombreLocal()}', 250);
    }
    if (c.usuario.isNotEmpty) {
      final auth = ehlo.where((l) => l.toUpperCase().contains('AUTH')).join(' ').toUpperCase();
      if (auth.contains('PLAIN') || !auth.contains('LOGIN')) {
        final plano = base64.encode(utf8.encode('\u0000${c.usuario}\u0000${c.clave}'));
        await s.orden('AUTH PLAIN $plano', 235, secreto: true);
      } else {
        await s.orden('AUTH LOGIN', 334);
        await s.orden(base64.encode(utf8.encode(c.usuario)), 334, secreto: true);
        await s.orden(base64.encode(utf8.encode(c.clave)), 235, secreto: true);
      }
    }
    await s.orden('MAIL FROM:<${c.remitente}>', 250);
    await s.orden('RCPT TO:<$para>', 250, tambien: 251);
    await s.orden('DATA', 354);
    // Una línea que empieza con «.» se dobla: si no, el servidor la toma por
    // el fin del mensaje.
    final cuerpo = mensaje.split('\r\n').map((l) => l.startsWith('.') ? '.$l' : l).join('\r\n');
    await s.orden('$cuerpo\r\n.', 250);
    try {
      await s.orden('QUIT', 221);
    } catch (_) {
      // El correo ya salió; un QUIT mal contestado no lo deshace.
    }
  } on CorreoError {
    rethrow;
  } on HandshakeException catch (e) {
    throw CorreoError('correo_tls', 'No se pudo cifrar la conexión: ${e.message}');
  } on SocketException catch (e) {
    throw CorreoError('correo_conexion', 'No se pudo conectar con ${c.host}:${c.puerto}: ${e.message}');
  } on TimeoutException {
    throw CorreoError('correo_tiempo', '${c.host}:${c.puerto} no contestó a tiempo');
  } finally {
    await s.cierra();
  }
}

/// El mensaje entero (cabeceras y cuerpo), con saltos CRLF. Público para las
/// pruebas.
String armaMensaje({
  required String de,
  required String nombreDe,
  required String para,
  required String asunto,
  required String texto,
  String? html,
  DateTime? fecha,
}) {
  final frontera = 'apk-${_aleatorio(16)}';
  final dominio = de.contains('@') ? de.split('@').last : 'apk-server';
  final b = StringBuffer()
    ..write('From: ${nombreDe.isEmpty ? '' : '${_nombreVisible(nombreDe)} '}<$de>\r\n')
    ..write('To: <$para>\r\n')
    ..write('Subject: ${_palabra(asunto)}\r\n')
    ..write('Date: ${HttpDate.format(fecha ?? DateTime.now()).replaceFirst('GMT', '+0000')}\r\n')
    ..write('Message-ID: <${_aleatorio(24)}@$dominio>\r\n')
    ..write('MIME-Version: 1.0\r\n');
  if (html == null) {
    b
      ..write('Content-Type: text/plain; charset=utf-8\r\n')
      ..write('Content-Transfer-Encoding: base64\r\n\r\n')
      ..write(_base64EnLineas(texto));
  } else {
    b
      ..write('Content-Type: multipart/alternative; boundary="$frontera"\r\n\r\n')
      ..write('--$frontera\r\n')
      ..write('Content-Type: text/plain; charset=utf-8\r\n')
      ..write('Content-Transfer-Encoding: base64\r\n\r\n')
      ..write(_base64EnLineas(texto))
      ..write('--$frontera\r\n')
      ..write('Content-Type: text/html; charset=utf-8\r\n')
      ..write('Content-Transfer-Encoding: base64\r\n\r\n')
      ..write(_base64EnLineas(html))
      ..write('--$frontera--\r\n');
  }
  return b.toString();
}

/// Una cabecera con acentos (RFC 2047): ASCII tal cual, lo demás en base64.
String _palabra(String s) {
  final limpio = s.replaceAll(RegExp(r'[\r\n]+'), ' ');
  if (RegExp(r'^[\x20-\x7e]*$').hasMatch(limpio)) return limpio;
  return '=?UTF-8?B?${base64.encode(utf8.encode(limpio))}?=';
}

/// El nombre del «De:»: entre comillas si es ASCII (una coma o un punto lo
/// partirían), y en base64 si lleva acentos.
String _nombreVisible(String n) {
  final limpio = n.replaceAll(RegExp(r'[\r\n]+'), ' ');
  if (!RegExp(r'^[\x20-\x7e]*$').hasMatch(limpio)) return _palabra(limpio);
  return '"${limpio.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}

String _base64EnLineas(String s) {
  final b64 = base64.encode(utf8.encode(s));
  final out = StringBuffer();
  for (var i = 0; i < b64.length; i += 76) {
    out
      ..write(b64.substring(i, min(i + 76, b64.length)))
      ..write('\r\n');
  }
  return out.toString();
}

String _aleatorio(int n) {
  const letras = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(n, (_) => letras[r.nextInt(letras.length)]).join();
}

String _nombreLocal() {
  try {
    final h = Platform.localHostname;
    return h.isEmpty ? 'apk-server' : h;
  } catch (_) {
    return 'apk-server';
  }
}

/// Una conversación SMTP: manda una orden y espera el código de respuesta.
class _Smtp {
  _Smtp(this.host, this.plazo);
  final String host;
  final Duration plazo;

  Socket? _s;
  StreamSubscription<List<int>>? _sub;
  final _pendiente = StringBuffer();
  final _lineas = <String>[];
  Completer<void>? _hay;
  Object? _error;

  Future<void> conecta(int puerto, {required bool tls}) async {
    _s = tls
        ? await SecureSocket.connect(host, puerto, timeout: plazo)
        : await Socket.connect(host, puerto, timeout: plazo);
    _escucha();
  }

  void _escucha() {
    _sub = _s!.listen(
      (datos) {
        _pendiente.write(utf8.decode(datos, allowMalformed: true));
        final todo = _pendiente.toString();
        final partes = todo.split('\r\n');
        _pendiente
          ..clear()
          ..write(partes.removeLast());
        _lineas.addAll(partes);
        _avisa();
      },
      onError: (Object e) {
        _error = e;
        _avisa();
      },
      onDone: () {
        _error ??= const SocketException('El servidor cerró la conexión');
        _avisa();
      },
    );
  }

  void _avisa() {
    final h = _hay;
    if (h != null && !h.isCompleted) h.complete();
  }

  /// STARTTLS: la lectura se pausa, el mismo socket pasa a TLS y se vuelve a
  /// leer del seguro.
  Future<void> aTls() async {
    _sub!.pause();
    _s = await SecureSocket.secure(_s!, host: host).timeout(plazo);
    _escucha();
  }

  /// Espera una respuesta completa (la última línea es «NNN texto», las
  /// anteriores «NNN-texto») y la devuelve si su código es [codigo].
  Future<List<String>> espera(int codigo, {int? tambien, bool secreto = false}) async {
    final fin = DateTime.now().add(plazo);
    final respuesta = <String>[];
    while (true) {
      while (_lineas.isNotEmpty) {
        final l = _lineas.removeAt(0);
        respuesta.add(l);
        if (l.length < 4 || l[3] != '-') {
          final n = int.tryParse(l.length >= 3 ? l.substring(0, 3) : '') ?? 0;
          if (n != codigo && n != tambien) {
            throw CorreoError(
              n == 535 || n == 534 ? 'correo_autenticacion' : 'correo_rechazado',
              secreto ? '$n (al autenticar)' : respuesta.join(' | '),
            );
          }
          return respuesta;
        }
      }
      if (_error != null) throw _error!;
      final queda = fin.difference(DateTime.now());
      if (queda.isNegative) throw TimeoutException('smtp');
      _hay = Completer<void>();
      await _hay!.future.timeout(queda);
    }
  }

  Future<List<String>> orden(String linea, int codigo, {int? tambien, bool secreto = false}) {
    _s!.write('$linea\r\n');
    return espera(codigo, tambien: tambien, secreto: secreto);
  }

  Future<void> cierra() async {
    await _sub?.cancel();
    try {
      await _s?.close();
    } catch (_) {}
    _s?.destroy();
  }
}
