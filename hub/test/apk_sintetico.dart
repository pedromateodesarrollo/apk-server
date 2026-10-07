import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// APK armados byte a byte para las pruebas: un manifiesto en el XML binario
/// de Android, el zip alrededor y, si toca, el bloque de firma v2. Así el
/// repositorio no carga APK de nadie y cada caso dice exactamente qué trae.

// ------------------------------------------------------------ constructores

class _Bytes {
  final _b = BytesBuilder();
  void u8(int v) => _b.addByte(v & 0xff);
  void u16(int v) => _b.add((ByteData(2)..setUint16(0, v & 0xffff, Endian.little)).buffer.asUint8List());
  void u32(int v) => _b.add((ByteData(4)..setUint32(0, v & 0xffffffff, Endian.little)).buffer.asUint8List());
  void u64(int v) => _b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void bytes(List<int> v) => _b.add(v);
  int get length => _b.length;
  Uint8List toBytes() => _b.toBytes();
}

/// Un AndroidManifest.xml compilado (AXML) con `<manifest>` y `<uses-sdk>`.
Uint8List manifiestoSintetico({
  required String paquete,
  required int build,
  required String version,
  int minSdk = 21,
  int targetSdk = 34,
  bool utf8 = false,
}) {
  // Primero las cadenas con id de recurso (en el mismo orden que el mapa).
  final cadenas = [
    'versionCode', 'versionName', 'minSdkVersion', 'targetSdkVersion', // 0-3
    'android', 'http://schemas.android.com/apk/res/android', // 4-5
    'package', 'manifest', paquete, version, 'uses-sdk', 'application', // 6-11
  ];
  const ids = [0x0101021b, 0x0101021c, 0x0101020c, 0x01010270];
  const sinValor = 0xffffffff;

  // Tabla de cadenas.
  final datos = _Bytes();
  final offsets = <int>[];
  for (final c in cadenas) {
    offsets.add(datos.length);
    if (utf8) {
      final b = const Utf8Encoder().convert(c);
      datos
        ..u8(c.length)
        ..u8(b.length)
        ..bytes(b)
        ..u8(0);
    } else {
      datos.u16(c.length);
      for (final u in c.codeUnits) {
        datos.u16(u);
      }
      datos.u16(0);
    }
  }
  while (datos.length % 4 != 0) {
    datos.u8(0);
  }
  final pool = _Bytes()
    ..u16(0x0001)
    ..u16(28)
    ..u32(28 + cadenas.length * 4 + datos.length)
    ..u32(cadenas.length)
    ..u32(0)
    ..u32(utf8 ? 0x100 : 0)
    ..u32(28 + cadenas.length * 4)
    ..u32(0);
  for (final o in offsets) {
    pool.u32(o);
  }
  pool.bytes(datos.toBytes());

  final mapa = _Bytes()
    ..u16(0x0180)
    ..u16(8)
    ..u32(8 + ids.length * 4);
  for (final id in ids) {
    mapa.u32(id);
  }

  Uint8List elemento(int nombre, List<List<int>> attrs) {
    final e = _Bytes()
      ..u16(0x0102)
      ..u16(16)
      ..u32(16 + 20 + attrs.length * 20)
      ..u32(1)
      ..u32(sinValor)
      ..u32(sinValor)
      ..u32(nombre)
      ..u16(20)
      ..u16(20)
      ..u16(attrs.length)
      ..u16(0)
      ..u16(0)
      ..u16(0);
    // [ns, nombre, crudo, tipo, dato]
    for (final a in attrs) {
      e
        ..u32(a[0])
        ..u32(a[1])
        ..u32(a[2])
        ..u16(8)
        ..u8(0)
        ..u8(a[3])
        ..u32(a[4]);
    }
    return e.toBytes();
  }

  final manifest = elemento(7, [
    [sinValor, 6, 8, 0x03, 8],
    [5, 0, sinValor, 0x10, build],
    [5, 1, 9, 0x03, 9],
  ]);
  final usesSdk = elemento(10, [
    [5, 2, sinValor, 0x10, minSdk],
    [5, 3, sinValor, 0x10, targetSdk],
  ]);
  final cuerpo = _Bytes()
    ..bytes(pool.toBytes())
    ..bytes(mapa.toBytes())
    ..bytes(manifest)
    ..bytes(usesSdk);
  return (_Bytes()
        ..u16(0x0003)
        ..u16(8)
        ..u32(8 + cuerpo.length)
        ..bytes(cuerpo.toBytes()))
      .toBytes();
}

/// Un zip con [entradas]; con [certificado], además el bloque de firma v2
/// entre los datos y el directorio central, como lo deja `apksigner`.
Uint8List apkSintetico(
  Map<String, Uint8List> entradas, {
  bool comprimir = true,
  Uint8List? certificado,
}) {
  final z = _Bytes();
  final central = _Bytes();
  entradas.forEach((nombre, datos) {
    final n = const Utf8Encoder().convert(nombre);
    final cuerpo = comprimir ? Uint8List.fromList(ZLibEncoder(raw: true).convert(datos)) : datos;
    final metodo = comprimir ? 8 : 0;
    final offset = z.length;
    z
      ..u32(0x04034b50)
      ..u16(20)
      ..u16(0)
      ..u16(metodo)
      ..u16(0)
      ..u16(0)
      ..u32(0)
      ..u32(cuerpo.length)
      ..u32(datos.length)
      ..u16(n.length)
      ..u16(0)
      ..bytes(n)
      ..bytes(cuerpo);
    central
      ..u32(0x02014b50)
      ..u16(20)
      ..u16(20)
      ..u16(0)
      ..u16(metodo)
      ..u16(0)
      ..u16(0)
      ..u32(0)
      ..u32(cuerpo.length)
      ..u32(datos.length)
      ..u16(n.length)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u32(0)
      ..u32(offset)
      ..bytes(n);
  });

  if (certificado != null) {
    Uint8List conLargo(List<int> b) => (_Bytes()
          ..u32(b.length)
          ..bytes(b))
        .toBytes();
    final firmados = [...conLargo([]), ...conLargo(conLargo(certificado))];
    final firmante = conLargo([...conLargo(firmados), ...conLargo([]), ...conLargo([])]);
    final valor = conLargo(firmante);
    final par = _Bytes()
      ..u64(4 + valor.length)
      ..u32(0x7109871a)
      ..bytes(valor);
    final tam = par.length + 8 + 16;
    z
      ..u64(tam)
      ..bytes(par.toBytes())
      ..u64(tam)
      ..bytes(ascii.encode('APK Sig Block 42'));
  }

  final inicioCentral = z.length;
  z
    ..bytes(central.toBytes())
    ..u32(0x06054b50)
    ..u16(0)
    ..u16(0)
    ..u16(entradas.length)
    ..u16(entradas.length)
    ..u32(central.length)
    ..u32(inicioCentral)
    ..u16(0);
  return z.toBytes();
}
