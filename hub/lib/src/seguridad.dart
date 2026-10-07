import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Primitivas de seguridad del hub: claves, tokens y JWT.
///
/// Se implementan aquí, con `package:crypto` y nada más, porque son cuatro
/// funciones bien definidas y cada dependencia extra es una dependencia que el
/// que se auto-hospeda tiene que auditar.
class Seguridad {
  Seguridad._();

  static final _rnd = Random.secure();

  // ---------------------------------------------------------------- claves

  /// Iteraciones de PBKDF2. No es Argon2 —que sería mejor contra GPU— pero sí
  /// es lo que se puede hacer sin dependencias nativas, y con este conteo una
  /// clave sola cuesta ~100 ms de CPU al que la quiera adivinar.
  static const int _iteraciones = 210000;

  /// `pbkdf2$<iteraciones>$<sal_b64>$<hash_b64>`
  static String hashClave(String clave, {int? iteraciones}) {
    final iter = iteraciones ?? _iteraciones;
    final sal = bytesAleatorios(16);
    final hash = _pbkdf2(utf8.encode(clave), sal, iter, 32);
    return 'pbkdf2\$$iter\$${base64.encode(sal)}\$${base64.encode(hash)}';
  }

  static bool verificaClave(String clave, String guardado) {
    final partes = guardado.split(r'$');
    if (partes.length != 4 || partes[0] != 'pbkdf2') return false;
    final iter = int.tryParse(partes[1]) ?? 0;
    if (iter <= 0) return false;
    final sal = base64.decode(partes[2]);
    final esperado = base64.decode(partes[3]);
    final calculado = _pbkdf2(utf8.encode(clave), sal, iter, esperado.length);
    return igualdadConstante(calculado, esperado);
  }

  static Uint8List _pbkdf2(
    List<int> clave,
    List<int> sal,
    int iteraciones,
    int largo,
  ) {
    final hmac = Hmac(sha256, clave);
    final salida = Uint8List(largo);
    var generado = 0;
    var bloque = 1;
    while (generado < largo) {
      final semilla = <int>[
        ...sal,
        (bloque >> 24) & 0xff,
        (bloque >> 16) & 0xff,
        (bloque >> 8) & 0xff,
        bloque & 0xff,
      ];
      var u = Uint8List.fromList(hmac.convert(semilla).bytes);
      final acumulado = Uint8List.fromList(u);
      for (var i = 1; i < iteraciones; i++) {
        u = Uint8List.fromList(hmac.convert(u).bytes);
        for (var j = 0; j < acumulado.length; j++) {
          acumulado[j] ^= u[j];
        }
      }
      final copiar = min(acumulado.length, largo - generado);
      salida.setRange(generado, generado + copiar, acumulado);
      generado += copiar;
      bloque++;
    }
    return salida;
  }

  // ---------------------------------------------------------------- tokens

  static Uint8List bytesAleatorios(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rnd.nextInt(256)));

  /// Token opaco url-safe. Se usa para llaves de API e invitaciones.
  static String token([int bytes = 32]) => _b64url(bytesAleatorios(bytes));

  /// Hex plano, para prefijos que se enseñan y se buscan (no son secretos).
  static String hex(int bytes) => bytesAleatorios(bytes)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// Parte una credencial `tipo_id_secreto`.
  ///
  /// Se cortan **solo los dos primeros** separadores: el secreto es base64url
  /// y trae guiones bajos, así que un `split('_')` a secas lo despedaza y toda
  /// credencial con un `_` dentro se rechazaba como mal formada.
  static List<String>? partesCredencial(String v) {
    final a = v.indexOf('_');
    if (a <= 0) return null;
    final b = v.indexOf('_', a + 1);
    if (b < 0 || b == a + 1 || b == v.length - 1) return null;
    return [v.substring(0, a), v.substring(a + 1, b), v.substring(b + 1)];
  }

  /// Los tokens se guardan hasheados. SHA-256 desnudo basta y sobra: el token
  /// tiene 256 bits de azar, no hay diccionario que lo alcance, así que el
  /// costo de PBKDF2 sería puro peaje por petición.
  static String hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  /// Comparación en tiempo constante. Con `==` sobre cadenas, el tiempo de
  /// respuesta filtra cuántos caracteres acertó quien está probando.
  static bool igualdadConstante(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var dif = 0;
    for (var i = 0; i < a.length; i++) {
      dif |= a[i] ^ b[i];
    }
    return dif == 0;
  }

  static bool tokenCoincide(String recibido, String hashGuardado) =>
      igualdadConstante(
        utf8.encode(hashToken(recibido)),
        utf8.encode(hashGuardado),
      );

  // ------------------------------------------------------------------- JWT

  /// Firma un JWT HS256. El hub emite un solo tipo de sesión —persona del
  /// panel—; los scripts de publicación usan llaves de API, que no caducan
  /// solas.
  static String firmaJwt(
    Map<String, Object?> carga,
    String secreto, {
    Duration vida = const Duration(days: 7),
  }) {
    final ahora = DateTime.now().toUtc();
    final cuerpo = <String, Object?>{
      ...carga,
      'iat': ahora.millisecondsSinceEpoch ~/ 1000,
      'exp': ahora.add(vida).millisecondsSinceEpoch ~/ 1000,
    };
    final cabecera = _b64url(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
    final datos = _b64url(utf8.encode(jsonEncode(cuerpo)));
    final firma = _firma('$cabecera.$datos', secreto);
    return '$cabecera.$datos.$firma';
  }

  /// Devuelve la carga si el token verifica y no ha expirado; si no, null.
  static Map<String, Object?>? verificaJwt(String jwt, String secreto) {
    final partes = jwt.split('.');
    if (partes.length != 3) return null;
    final firma = _firma('${partes[0]}.${partes[1]}', secreto);
    if (!igualdadConstante(utf8.encode(firma), utf8.encode(partes[2]))) {
      return null;
    }
    try {
      final carga = jsonDecode(utf8.decode(_deB64url(partes[1])));
      if (carga is! Map) return null;
      final exp = carga['exp'];
      if (exp is int &&
          exp * 1000 < DateTime.now().toUtc().millisecondsSinceEpoch) {
        return null;
      }
      return carga.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  static String _firma(String mensaje, String secreto) =>
      _b64url(Hmac(sha256, utf8.encode(secreto)).convert(utf8.encode(mensaje)).bytes);

  static String _b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _deB64url(String s) {
    final relleno = '=' * ((4 - s.length % 4) % 4);
    return base64Url.decode(s + relleno);
  }
}
