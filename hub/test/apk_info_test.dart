import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_server_hub/src/apk_info.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'apk_sintetico.dart';

/// Los APK salen de `apk_sintetico.dart`: armados byte a byte, sin cargar
/// APK de nadie en el repositorio.
void main() {
  group('manifiesto', () {
    test('lee paquete, versión y SDK de un manifiesto UTF-16 comprimido', () async {
      final apk = apkSintetico({
        'AndroidManifest.xml': manifiestoSintetico(
          paquete: 'com.ejemplo.inventario',
          build: 84,
          version: '1.55.0',
          minSdk: 24,
          targetSdk: 36,
        ),
        'classes.dex': Uint8List(300),
      });
      final info = await ApkInfo.deBytes(apk);
      expect(info.paquete, 'com.ejemplo.inventario');
      expect(info.build, 84);
      expect(info.version, '1.55.0');
      expect(info.minSdk, 24);
      expect(info.targetSdk, 36);
      expect(info.firma, isNull);
    });

    test('igual con la tabla de cadenas en UTF-8 y el manifiesto sin comprimir', () async {
      final apk = apkSintetico(
        {
          'AndroidManifest.xml': manifiestoSintetico(
            paquete: 'com.ejemplo.compras',
            build: 39,
            version: '2.17.0',
            utf8: true,
          ),
        },
        comprimir: false,
      );
      final info = await ApkInfo.deBytes(apk);
      expect(info.paquete, 'com.ejemplo.compras');
      expect(info.build, 39);
      expect(info.version, '2.17.0');
    });

    test('un versionCode grande no se vuelve negativo', () async {
      final apk = apkSintetico({
        'AndroidManifest.xml': manifiestoSintetico(paquete: 'a.b', build: 2100000000, version: 'x'),
      });
      expect((await ApkInfo.deBytes(apk)).build, 2100000000);
    });

    test('desde un archivo en disco lee lo mismo', () async {
      final dir = await Directory.systemTemp.createTemp('apk_info');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/a.apk')
        ..writeAsBytesSync(apkSintetico({
          'AndroidManifest.xml': manifiestoSintetico(paquete: 'a.b.c', build: 7, version: '0.7'),
        }));
      final info = await ApkInfo.deArchivo(f);
      expect(info.paquete, 'a.b.c');
      expect(info.build, 7);
    });
  });

  group('firma', () {
    test('saca el sha256 del certificado del bloque v2', () async {
      final certificado = utf8.encode('certificado DER de mentira');
      final apk = apkSintetico(
        {'AndroidManifest.xml': manifiestoSintetico(paquete: 'a.b', build: 1, version: '1')},
        certificado: Uint8List.fromList(certificado),
      );
      final info = await ApkInfo.deBytes(apk);
      expect(info.firma, sha256.convert(certificado).toString());
    });
  });

  group('rechazos', () {
    Future<String> motivo(Uint8List b) async {
      try {
        await ApkInfo.deBytes(b);
        return 'aceptado';
      } on ApkInvalido catch (e) {
        return e.motivo;
      }
    }

    test('lo que no es zip', () async {
      expect(await motivo(Uint8List.fromList(List.filled(500, 7))), contains('No es un APK'));
      expect(await motivo(Uint8List(3)), contains('demasiado chico'));
    });

    test('un zip sin manifiesto', () async {
      expect(await motivo(apkSintetico({'hola.txt': Uint8List(10)})), contains('no trae AndroidManifest'));
    });

    test('un manifiesto de texto (el de un proyecto, no el compilado)', () async {
      final apk = apkSintetico({
        'AndroidManifest.xml': Uint8List.fromList(utf8.encode('<manifest package="a.b"/>')),
      });
      expect(await motivo(apk), contains('formato binario'));
    });

    test('un manifiesto cortado a la mitad no revienta', () async {
      final m = manifiestoSintetico(paquete: 'a.b', build: 1, version: '1');
      final apk = apkSintetico({'AndroidManifest.xml': Uint8List.sublistView(m, 0, m.length ~/ 2)});
      expect(await motivo(apk), isNot('aceptado'));
    });
  });
}
