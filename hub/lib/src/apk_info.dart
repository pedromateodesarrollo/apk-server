import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Lo que se sabe de un APK sin instalarlo: de qué app es, qué versión trae y
/// con qué llave se firmó.
///
/// Se lee del propio archivo para no creerle a quien publica. Los tres
/// errores que más caro salen al repartir APK a mano son justamente estos:
/// publicar el APK de un sabor en la app de otro (otro `applicationId`), un
/// `versionCode` que no es el que se dijo (los equipos comparan contra un
/// número que no es el instalado) y uno firmado con otra llave (Android se
/// niega a actualizar, en el teléfono, cuando ya es tarde).
///
/// Sin `aapt` ni SDK de Android: un APK es un zip, el manifiesto va en el
/// formato binario de Android (AXML) y la firma v2/v3 es un bloque antes del
/// directorio central. Las tres cosas se leen con `dart:io`.
class ApkInfo {
  const ApkInfo({
    required this.paquete,
    required this.build,
    required this.version,
    this.minSdk,
    this.targetSdk,
    this.firma,
  });

  /// `applicationId` (`com.ejemplo.app`).
  final String paquete;

  /// `versionCode`.
  final int build;

  /// `versionName`. Vacío si el manifiesto lo trae como referencia a un
  /// recurso (no se resuelve: haría falta leer `resources.arsc`).
  final String version;

  final int? minSdk;
  final int? targetSdk;

  /// sha256 en hex del certificado del primer firmante (esquema v2 o v3).
  /// Null si el APK solo trae la firma v1 (JAR), que aquí no se mira.
  final String? firma;

  /// Lee solo los pedazos que hacen falta (el final, el directorio central, el
  /// manifiesto y el bloque de firma), no el archivo entero: un APK pesa
  /// decenas de megas y lo que interesa son unos kilobytes.
  static Future<ApkInfo> deArchivo(File archivo) async {
    final raf = await archivo.open();
    try {
      final largo = await raf.length();
      return await _lee(largo, (desde, n) async {
        await raf.setPosition(desde);
        return raf.read(n);
      });
    } finally {
      await raf.close();
    }
  }

  static Future<ApkInfo> deBytes(Uint8List bytes) => _lee(
        bytes.length,
        (desde, n) async => Uint8List.sublistView(bytes, desde, desde + n),
      );

  Map<String, Object?> aJson() => {
        'paquete': paquete,
        'build': build,
        'version': version,
        'min_sdk': minSdk,
        'target_sdk': targetSdk,
        'firma': firma,
      };
}

/// El archivo no es un APK que se pueda leer. [motivo] va tal cual al que
/// publicó, así que se escribe para una persona.
class ApkInvalido implements Exception {
  ApkInvalido(this.motivo);
  final String motivo;
  @override
  String toString() => 'ApkInvalido: $motivo';
}

typedef _Lector = Future<Uint8List> Function(int desde, int largo);

/// Topes de lo que se acepta leer. Un manifiesto real pesa decenas de KB y un
/// bloque de firma unos pocos; los topes son para que un zip hecho a mala fe
/// no haga reservar gigas de memoria.
const _maxManifiesto = 8 * 1024 * 1024;
const _maxDirectorio = 32 * 1024 * 1024;
const _maxBloqueFirma = 16 * 1024 * 1024;

Future<ApkInfo> _lee(int largo, _Lector leer) async {
  if (largo < 22) throw ApkInvalido('El archivo es demasiado chico para ser un APK');

  // -- Fin del directorio central (EOCD). Está en los últimos 22 bytes, más
  // un comentario opcional de hasta 64 KB: se busca hacia atrás.
  final cola = largo < 65557 ? largo : 65557;
  final fin = await leer(largo - cola, cola);
  var eocd = -1;
  for (var i = fin.length - 22; i >= 0; i--) {
    if (fin[i] == 0x50 && fin[i + 1] == 0x4b && fin[i + 2] == 0x05 && fin[i + 3] == 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw ApkInvalido('No es un APK (no se encontró el índice del zip)');
  final fd = ByteData.sublistView(fin);
  final tamDirectorio = fd.getUint32(eocd + 12, Endian.little);
  final inicioDirectorio = fd.getUint32(eocd + 16, Endian.little);
  if (inicioDirectorio == 0xFFFFFFFF || tamDirectorio == 0xFFFFFFFF) {
    throw ApkInvalido('APK en formato zip64, que no se admite');
  }
  if (tamDirectorio > _maxDirectorio || inicioDirectorio + tamDirectorio > largo) {
    throw ApkInvalido('El índice del zip está dañado');
  }

  // -- Directorio central: se busca la entrada del manifiesto.
  final dir = await leer(inicioDirectorio, tamDirectorio);
  final dd = ByteData.sublistView(dir);
  int? metodo, tamComprimido, tamReal, offsetLocal;
  var p = 0;
  while (p + 46 <= dir.length && dd.getUint32(p, Endian.little) == 0x02014b50) {
    final nLargo = dd.getUint16(p + 28, Endian.little);
    final eLargo = dd.getUint16(p + 30, Endian.little);
    final cLargo = dd.getUint16(p + 32, Endian.little);
    if (p + 46 + nLargo > dir.length) break;
    final nombre = utf8.decode(dir.sublist(p + 46, p + 46 + nLargo), allowMalformed: true);
    if (nombre == 'AndroidManifest.xml') {
      metodo = dd.getUint16(p + 10, Endian.little);
      tamComprimido = dd.getUint32(p + 20, Endian.little);
      tamReal = dd.getUint32(p + 24, Endian.little);
      offsetLocal = dd.getUint32(p + 42, Endian.little);
      break;
    }
    p += 46 + nLargo + eLargo + cLargo;
  }
  if (offsetLocal == null) {
    throw ApkInvalido('El archivo es un zip, pero no trae AndroidManifest.xml');
  }
  if (tamComprimido! > _maxManifiesto || tamReal! > _maxManifiesto) {
    throw ApkInvalido('El manifiesto es demasiado grande');
  }

  // -- Cabecera local: su nombre y su «extra» pueden medir distinto que en el
  // directorio central, así que el inicio de los datos se calcula con los suyos.
  final cab = await leer(offsetLocal, 30);
  final cd = ByteData.sublistView(cab);
  if (cd.getUint32(0, Endian.little) != 0x04034b50) {
    throw ApkInvalido('La entrada del manifiesto está dañada');
  }
  final inicioDatos =
      offsetLocal + 30 + cd.getUint16(26, Endian.little) + cd.getUint16(28, Endian.little);
  if (inicioDatos + tamComprimido > largo) {
    throw ApkInvalido('La entrada del manifiesto se sale del archivo');
  }
  final comprimido = await leer(inicioDatos, tamComprimido);
  final Uint8List manifiesto;
  if (metodo == 0) {
    manifiesto = comprimido;
  } else if (metodo == 8) {
    try {
      manifiesto = Uint8List.fromList(ZLibDecoder(raw: true).convert(comprimido));
    } on FormatException {
      throw ApkInvalido('El manifiesto no se pudo descomprimir');
    }
  } else {
    throw ApkInvalido('El manifiesto usa una compresión que no se admite ($metodo)');
  }

  final m = _Manifiesto.lee(manifiesto);
  final firma = await _firma(leer, inicioDirectorio);
  return ApkInfo(
    paquete: m.paquete,
    build: m.build!,
    version: m.version,
    minSdk: m.minSdk,
    targetSdk: m.targetSdk,
    firma: firma,
  );
}

// ------------------------------------------------------------- manifiesto

/// Ids de recurso de los atributos `android:` que interesan. Se busca por id y
/// no por nombre porque un APK optimizado puede dejar los nombres vacíos en la
/// tabla de cadenas; el id siempre está.
const _attrVersionCode = 0x0101021b;
const _attrVersionName = 0x0101021c;
const _attrMinSdk = 0x0101020c;
const _attrTargetSdk = 0x01010270;

class _Manifiesto {
  String paquete = '';
  int? build;
  String version = '';
  int? minSdk;
  int? targetSdk;

  /// Recorre el XML binario de Android hasta `<uses-sdk>`: no hace falta el
  /// resto (actividades, permisos…).
  static _Manifiesto lee(Uint8List b) {
    final d = ByteData.sublistView(b);
    if (b.length < 8 || d.getUint16(0, Endian.little) != 0x0003) {
      throw ApkInvalido('El manifiesto no está en el formato binario de Android');
    }
    final total = d.getUint32(4, Endian.little).clamp(0, b.length);
    final m = _Manifiesto();
    var cadenas = const <String>[];
    var ids = const <int>[];
    var p = d.getUint16(2, Endian.little);
    try {
      while (p + 8 <= total) {
        final tipo = d.getUint16(p, Endian.little);
        final cabecera = d.getUint16(p + 2, Endian.little);
        final tam = d.getUint32(p + 4, Endian.little);
        if (tam < 8 || p + tam > total) break;
        if (tipo == 0x0001) {
          cadenas = _cadenas(b, d, p, cabecera);
        } else if (tipo == 0x0180) {
          ids = [
            for (var i = p + cabecera; i + 4 <= p + tam; i += 4) d.getUint32(i, Endian.little),
          ];
        } else if (tipo == 0x0102) {
          final listo = m._elemento(d, p + cabecera, cadenas, ids);
          if (listo) break;
        }
        p += tam;
      }
    } on RangeError {
      throw ApkInvalido('El manifiesto está dañado');
    }
    if (m.paquete.isEmpty || m.build == null) {
      throw ApkInvalido('El manifiesto no dice el paquete o el versionCode');
    }
    return m;
  }

  /// Un `<elemento>`. Devuelve true cuando ya no hace falta seguir leyendo.
  bool _elemento(ByteData d, int ext, List<String> cadenas, List<int> ids) {
    final nombre = _cadena(cadenas, d.getUint32(ext + 4, Endian.little));
    if (nombre != 'manifest' && nombre != 'uses-sdk') {
      // `<uses-sdk>` va antes de `<application>`; si ya se llegó ahí, no hay más.
      return nombre == 'application';
    }
    final inicio = d.getUint16(ext + 8, Endian.little);
    final tamAttr = d.getUint16(ext + 10, Endian.little);
    final cuantos = d.getUint16(ext + 12, Endian.little);
    for (var i = 0; i < cuantos; i++) {
      final a = ext + inicio + i * tamAttr;
      final iNombre = d.getUint32(a + 4, Endian.little);
      final crudo = d.getUint32(a + 8, Endian.little);
      final tipoDato = d.getUint8(a + 15);
      final dato = d.getUint32(a + 16, Endian.little);
      final id = iNombre < ids.length ? ids[iNombre] : 0;
      final nAttr = _cadena(cadenas, iNombre);

      String? texto() {
        if (tipoDato == 0x03) return _cadena(cadenas, dato);
        if (crudo != 0xFFFFFFFF) return _cadena(cadenas, crudo);
        return null;
      }

      // 0x10 entero decimal, 0x11 hexadecimal. Un versionCode como texto
      // (raro, pero aapt lo permite) también vale.
      int? entero() => (tipoDato == 0x10 || tipoDato == 0x11)
          ? dato.toSigned(32)
          : int.tryParse(texto() ?? '');

      if (nombre == 'manifest') {
        if (nAttr == 'package' && id == 0) {
          paquete = (texto() ?? '').trim();
        } else if (id == _attrVersionCode || (id == 0 && nAttr == 'versionCode')) {
          build = entero();
        } else if (id == _attrVersionName || (id == 0 && nAttr == 'versionName')) {
          version = texto() ?? '';
        }
      } else {
        if (id == _attrMinSdk || (id == 0 && nAttr == 'minSdkVersion')) {
          minSdk = entero();
        } else if (id == _attrTargetSdk || (id == 0 && nAttr == 'targetSdkVersion')) {
          targetSdk = entero();
        }
      }
    }
    return nombre == 'uses-sdk';
  }

  static String _cadena(List<String> cadenas, int i) =>
      i >= 0 && i < cadenas.length ? cadenas[i] : '';

  /// Tabla de cadenas (`ResStringPool`), en UTF-8 o UTF-16 según su bandera.
  static List<String> _cadenas(Uint8List b, ByteData d, int p, int cabecera) {
    final cuantas = d.getUint32(p + 8, Endian.little);
    final banderas = d.getUint32(p + 16, Endian.little);
    final inicio = d.getUint32(p + 20, Endian.little);
    final esUtf8 = banderas & 0x100 != 0;
    final salida = <String>[];
    for (var i = 0; i < cuantas; i++) {
      var o = p + inicio + d.getUint32(p + cabecera + i * 4, Endian.little);
      if (esUtf8) {
        // Primero el largo en UTF-16 (que no se usa), luego el largo en bytes;
        // cada uno en 1 o 2 bytes según el bit alto.
        o += (b[o] & 0x80) != 0 ? 2 : 1;
        var n = b[o];
        if (n & 0x80 != 0) {
          n = ((n & 0x7f) << 8) | b[o + 1];
          o += 2;
        } else {
          o += 1;
        }
        salida.add(utf8.decode(b.sublist(o, o + n), allowMalformed: true));
      } else {
        var n = d.getUint16(o, Endian.little);
        if (n & 0x8000 != 0) {
          n = ((n & 0x7fff) << 16) | d.getUint16(o + 2, Endian.little);
          o += 4;
        } else {
          o += 2;
        }
        salida.add(String.fromCharCodes([
          for (var k = 0; k < n; k++) d.getUint16(o + k * 2, Endian.little),
        ]));
      }
    }
    return salida;
  }
}

// ------------------------------------------------------------------ firma

const _idFirmaV2 = 0x7109871a;
const _idFirmaV3 = 0xf05368c0;

/// sha256 del certificado del primer firmante, del bloque de firma v2 (o v3
/// si no hay v2). El bloque va pegado antes del directorio central y termina
/// con su tamaño y la marca «APK Sig Block 42».
Future<String?> _firma(_Lector leer, int inicioDirectorio) async {
  if (inicioDirectorio < 32) return null;
  final pie = await leer(inicioDirectorio - 24, 24);
  if (ascii.decode(pie.sublist(8), allowInvalid: true) != 'APK Sig Block 42') return null;
  final tamBloque = ByteData.sublistView(pie).getUint64(0, Endian.little);
  if (tamBloque < 24 || tamBloque > _maxBloqueFirma || tamBloque + 8 > inicioDirectorio) {
    return null;
  }
  // Pares (largo u64, id u32, valor) entre el tamaño del principio y el pie.
  final pares = await leer(inicioDirectorio - tamBloque, tamBloque - 24);
  final d = ByteData.sublistView(pares);
  Uint8List? v2, v3;
  var p = 0;
  while (p + 12 <= pares.length) {
    final largo = d.getUint64(p, Endian.little);
    if (largo < 4 || p + 8 + largo > pares.length) break;
    final id = d.getUint32(p + 8, Endian.little);
    final valor = Uint8List.sublistView(pares, p + 12, p + 8 + largo);
    if (id == _idFirmaV2) v2 = valor;
    if (id == _idFirmaV3) v3 = valor;
    p += 8 + largo;
  }
  final valor = v2 ?? v3;
  if (valor == null) return null;
  try {
    // firmantes → primer firmante → datos firmados → (resúmenes, certificados)
    // → primer certificado. Todo con prefijo de largo u32.
    final firmantes = _conLargo(valor, 0);
    final firmante = _conLargo(firmantes, 0);
    final firmados = _conLargo(firmante, 0);
    final resumenes = _conLargo(firmados, 0);
    final certificados = _conLargo(firmados, 4 + resumenes.length);
    final certificado = _conLargo(certificados, 0);
    if (certificado.isEmpty) return null;
    return sha256.convert(certificado).toString();
  } on RangeError {
    return null;
  }
}

/// El pedazo con prefijo de largo (u32) que empieza en [desde].
Uint8List _conLargo(Uint8List b, int desde) {
  final n = ByteData.sublistView(b).getUint32(desde, Endian.little);
  if (desde + 4 + n > b.length) throw RangeError('largo fuera del bloque');
  return Uint8List.sublistView(b, desde + 4, desde + 4 + n);
}
