/// Una versión publicada más nueva que la instalada. Es lo que el actualizador
/// entrega; qué hacer con ella (bajarla, instalarla, avisar) es de la app.
class VersionDisponible {
  const VersionDisponible({
    required this.version,
    required this.build,
    required this.requerido,
    required this.url,
    this.notas = '',
    this.sha256 = '',
    this.bytes = 0,
  });

  /// Nombre de la versión (`1.14.0`).
  final String version;

  /// `versionCode`. Es lo que se compara: crece siempre, sin ambigüedad.
  final int build;

  /// Obligatoria: alguna versión por encima de la instalada lo es.
  final bool requerido;

  /// URL absoluta del APK. Lleva el sha256 en el nombre: no caduca.
  final String url;

  final String notas;

  /// Para comprobar la descarga.
  final String sha256;
  final int bytes;

  /// Desde la respuesta de `/v1/apps/:app/consulta` (o `/ultima`).
  static VersionDisponible? deRespuesta(Map<String, Object?> r, String servidor) {
    if (r['actualizar'] != true) return null;
    final v = r['version'];
    if (v is! Map) return null;
    final build = _entero(v['build']);
    final ruta = (v['url'] ?? v['ruta'] ?? '').toString();
    if (build == null || ruta.isEmpty) return null;
    return VersionDisponible(
      version: (v['version'] ?? '$build').toString(),
      build: build,
      requerido: r['requerido'] == true,
      url: ruta.startsWith('http') ? ruta : '$servidor$ruta',
      notas: (v['notas'] ?? '').toString(),
      sha256: (v['sha256'] ?? '').toString(),
      bytes: _entero(v['bytes']) ?? 0,
    );
  }

  static int? _entero(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  @override
  String toString() => 'VersionDisponible($version+$build${requerido ? ' requerida' : ''})';
}
