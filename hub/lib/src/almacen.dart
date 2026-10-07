import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'seguridad.dart';

/// Los APK en disco, uno por archivo y con su sha256 por nombre
/// (`<carpeta>/<sha256>.apk`).
///
/// Direccionados por contenido: el mismo APK publicado dos veces es un solo
/// archivo, la URL de descarga no cambia nunca (se puede cachear para siempre)
/// y no hay forma de que una publicación pise los bytes de otra —que es lo que
/// pasaba cuando el nombre salía de la app y la versión—.
class Almacen {
  Almacen(this.carpeta);

  final String carpeta;

  Directory get _dir => Directory(carpeta);
  Directory get _subidas => Directory('$carpeta${Platform.pathSeparator}.subidas');

  /// Crea las carpetas y borra subidas a medias de un arranque anterior.
  void prepara() {
    _dir.createSync(recursive: true);
    if (_subidas.existsSync()) _subidas.deleteSync(recursive: true);
    _subidas.createSync();
  }

  File archivo(String sha) => File('$carpeta${Platform.pathSeparator}$sha.apk');

  bool existe(String sha) => _shaValido(sha) && archivo(sha).existsSync();

  /// Escribe [datos] en un temporal mientras calcula el sha256, sin tener el
  /// APK entero en memoria. Lanza [SubidaGrande] si pasa de [maximo].
  Future<Subida> recibe(Stream<List<int>> datos, int maximo) async {
    final temporal = File(
      '${_subidas.path}${Platform.pathSeparator}${Seguridad.hex(12)}.parcial',
    );
    final salida = temporal.openWrite();
    final resumen = _Acumulador();
    final hash = sha256.startChunkedConversion(resumen);
    var bytes = 0;
    try {
      await for (final trozo in datos) {
        bytes += trozo.length;
        if (bytes > maximo) throw SubidaGrande(maximo);
        hash.add(trozo);
        salida.add(trozo);
      }
      hash.close();
      await salida.flush();
      await salida.close();
    } catch (_) {
      await salida.close().catchError((_) {});
      if (temporal.existsSync()) temporal.deleteSync();
      rethrow;
    }
    return Subida(temporal, resumen.valor.toString(), bytes);
  }

  /// Pasa la subida a su lugar definitivo. Si ese APK ya estaba, el temporal
  /// sobra y se borra: es el mismo contenido.
  void fija(Subida s) {
    final destino = archivo(s.sha256);
    if (destino.existsSync()) {
      s.descarta();
      return;
    }
    // Mismo sistema de archivos que el destino: el `rename` es atómico y
    // nadie llega a ver un APK a medias.
    s.temporal.renameSync(destino.path);
  }

  void borra(String sha) {
    if (!_shaValido(sha)) return;
    final f = archivo(sha);
    if (f.existsSync()) f.deleteSync();
  }

  /// Un sha256 en hex y nada más: el nombre se arma con él, y cualquier otra
  /// cosa (una barra, `..`) sería abrir un archivo de otro sitio.
  static bool _shaValido(String sha) => RegExp(r'^[0-9a-f]{64}$').hasMatch(sha);
  static bool shaValido(String sha) => _shaValido(sha);
}

class Subida {
  Subida(this.temporal, this.sha256, this.bytes);
  final File temporal;
  final String sha256;
  final int bytes;

  void descarta() {
    if (temporal.existsSync()) temporal.deleteSync();
  }
}

class SubidaGrande implements Exception {
  SubidaGrande(this.maximo);
  final int maximo;
}

class _Acumulador implements Sink<Digest> {
  late Digest valor;
  @override
  void add(Digest data) => valor = data;
  @override
  void close() {}
}
