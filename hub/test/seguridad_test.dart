import 'package:apk_server_hub/src/seguridad.dart';
import 'package:test/test.dart';

void main() {
  group('claves', () {
    test('verifica la buena y rechaza la mala', () {
      // Pocas iteraciones: aquí se prueba el formato, no el costo.
      final h = Seguridad.hashClave('clave12345', iteraciones: 1000);
      expect(Seguridad.verificaClave('clave12345', h), isTrue);
      expect(Seguridad.verificaClave('clave12346', h), isFalse);
    });

    test('dos hashes de la misma clave son distintos (sal por clave)', () {
      final a = Seguridad.hashClave('igual', iteraciones: 1000);
      final b = Seguridad.hashClave('igual', iteraciones: 1000);
      expect(a, isNot(b));
    });

    test('un hash con formato roto no valida en vez de reventar', () {
      expect(Seguridad.verificaClave('x', 'basura'), isFalse);
      expect(Seguridad.verificaClave('x', r'pbkdf2$0$c2Fs$aGFzaA=='), isFalse);
    });
  });

  group('credenciales', () {
    // El secreto es base64url y trae `_`: partir por todos los separadores
    // lo despedaza (le pasó a print-server, de donde sale este código).
    test('el secreto puede traer guiones bajos', () {
      final p = Seguridad.partesCredencial('cak_2_A_S5pV8g_Jq-Om');
      expect(p, ['cak', '2', 'A_S5pV8g_Jq-Om']);
    });

    test('formatos inválidos devuelven null', () {
      expect(Seguridad.partesCredencial('sinseparador'), isNull);
      expect(Seguridad.partesCredencial('cak_2'), isNull);
      expect(Seguridad.partesCredencial('cak__secreto'), isNull);
      expect(Seguridad.partesCredencial('cak_2_'), isNull);
      expect(Seguridad.partesCredencial('_2_secreto'), isNull);
    });

    test('el token se compara contra su hash', () {
      final t = Seguridad.token();
      final h = Seguridad.hashToken(t);
      expect(Seguridad.tokenCoincide(t, h), isTrue);
      expect(Seguridad.tokenCoincide('${t}x', h), isFalse);
    });
  });

  group('jwt', () {
    test('ida y vuelta', () {
      final j = Seguridad.firmaJwt({'sub': 7, 'org': 3}, 'secreto');
      final carga = Seguridad.verificaJwt(j, 'secreto');
      expect(carga?['sub'], 7);
      expect(carga?['org'], 3);
    });

    test('con otra clave no verifica', () {
      final j = Seguridad.firmaJwt({'sub': 7}, 'secreto');
      expect(Seguridad.verificaJwt(j, 'otro'), isNull);
    });

    test('caducado no verifica', () {
      final j = Seguridad.firmaJwt(
        {'sub': 7},
        'secreto',
        vida: const Duration(seconds: -10),
      );
      expect(Seguridad.verificaJwt(j, 'secreto'), isNull);
    });

    test('un token manipulado no verifica', () {
      final j = Seguridad.firmaJwt({'sub': 7, 'rol': 'editor'}, 'secreto');
      final partes = j.split('.');
      final falso = '${partes[0]}.${partes[1]}x.${partes[2]}';
      expect(Seguridad.verificaJwt(falso, 'secreto'), isNull);
    });
  });
}
