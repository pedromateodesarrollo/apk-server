import 'dart:io';

import 'package:postgres/postgres.dart';

import 'log.dart';

/// Acceso a Postgres: un pool y dos ayudantes para no repetir `toColumnMap`.
///
/// No hay ORM ni generador. Las consultas son SQL a la vista, con parámetros
/// nombrados; quien audite el repo lee lo que se ejecuta.
class Bd {
  Bd._(this._sesion, this._pool);

  /// Sobre qué se ejecuta: el pool, o la sesión de una transacción abierta.
  final Session _sesion;

  /// Solo lo tiene la instancia raíz. Dentro de una transacción es null, y por
  /// eso [transaccion] no se puede anidar por accidente.
  final Pool? _pool;

  static Future<Bd> abrir(String url) async {
    final pool = Pool.withUrl(url);
    // Un `select 1` al arrancar convierte «la base está mal configurada» en un
    // error al iniciar el servicio, no en un 500 a la primera consulta.
    await pool.execute('select 1');
    return Bd._(pool, pool);
  }

  Future<void> cerrar() async => _pool?.close();

  /// Filas como mapas columna→valor.
  Future<List<Map<String, Object?>>> filas(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final r = await _sesion.execute(Sql.named(sql), parameters: params);
    return r.map((f) => f.toColumnMap()).toList();
  }

  /// La primera fila, o null.
  Future<Map<String, Object?>?> fila(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final r = await filas(sql, params);
    return r.isEmpty ? null : r.first;
  }

  Future<void> ejecuta(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    await _sesion.execute(Sql.named(sql), parameters: params, ignoreRows: true);
  }

  /// Un script con varias sentencias (una migración). Va en modo simple
  /// porque el protocolo extendido de Postgres admite una sentencia por
  /// petición y una migración son diez; a cambio, no acepta parámetros.
  Future<void> script(String sql) async {
    await _sesion.execute(sql, queryMode: QueryMode.simple, ignoreRows: true);
  }

  /// Varias escrituras que solo valen juntas. Si [fn] lanza, se revierte todo.
  Future<R> transaccion<R>(Future<R> Function(Bd bd) fn) {
    final pool = _pool;
    if (pool == null) throw StateError('No hay transacciones anidadas');
    return pool.runTx((tx) => fn(Bd._(tx, null)));
  }

  /// Aplica las migraciones pendientes de [carpeta], en orden lexicográfico.
  ///
  /// Cada una corre en su propia transacción y queda anotada. Mismo contrato
  /// que Flyway: un archivo aplicado no se edita, se añade uno nuevo.
  Future<void> migrar(String carpeta) async {
    final dir = Directory(carpeta);
    if (!dir.existsSync()) {
      throw StateError(
        'No encuentro la carpeta de migraciones «$carpeta». '
        'Copia `migraciones/` junto al binario o define APK_MIGRACIONES.',
      );
    }
    await ejecuta('create schema if not exists apk');
    await ejecuta('''
      create table if not exists apk.migracion (
        nombre   text primary key,
        aplicada timestamptz not null default now()
      )''');

    final aplicadas = (await filas('select nombre from apk.migracion'))
        .map((f) => f['nombre'] as String)
        .toSet();

    final archivos =
        dir.listSync().whereType<File>().where((f) => f.path.endsWith('.sql')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final archivo in archivos) {
      final nombre = archivo.uri.pathSegments.last;
      if (aplicadas.contains(nombre)) continue;
      log.info('bd', 'aplicando migración $nombre');
      await transaccion((tx) async {
        await tx.script(archivo.readAsStringSync());
        await tx.ejecuta(
          'insert into apk.migracion (nombre) values (@n)',
          {'n': nombre},
        );
      });
    }
  }
}
