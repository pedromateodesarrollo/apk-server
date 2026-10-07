import 'db.dart';

/// Consultas del catálogo que comparten el panel y las rutas públicas: qué
/// versión toca, si es obligatoria, cómo se presenta.

const columnasVersion = '''v.id, v.build, v.version, v.requerido, v.notas, v.sha256,
  v.bytes, v.paquete, v.firma, v.min_sdk, v.target_sdk, v.descargas,
  v.publicado, v.publicado_por, v.retirada''';

/// Slug válido de una app: minúsculas, números y guiones, hasta 63.
final slugValido = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');

Future<Map<String, Object?>?> appPorSlug(Bd bd, String slug) {
  if (!slugValido.hasMatch(slug)) return Future.value(null);
  return bd.fila(
    '''select id, org, slug, nombre, descripcion, paquete, firma,
              icono is not null as tiene_icono, creado
         from apk.app where slug = @s''',
    {'s': slug},
  );
}

/// La versión que se ofrece: la de build más alta que no esté retirada.
Future<Map<String, Object?>?> ultimaVersion(Bd bd, int app) => bd.fila(
      '''select $columnasVersion from apk.version v
          where v.app = @a and v.retirada is null
          order by v.build desc limit 1''',
      {'a': app},
    );

/// Si alguna versión por encima de [build] es obligatoria. Así una build
/// requerida obliga aunque después salgan otras opcionales: quien estaba por
/// debajo de ella tiene que pasar, aterrice en la que aterrice.
Future<bool> hayRequerida(Bd bd, int app, int build) async =>
    await bd.fila(
      '''select 1 from apk.version
          where app = @a and build > @b and requerido and retirada is null
          limit 1''',
      {'a': app, 'b': build},
    ) !=
    null;

/// Ruta de descarga de un APK. Lleva el sha256: es inmutable y se cachea.
String rutaArchivo(String sha) => '/archivos/$sha.apk';

/// Una versión tal como la ven el panel y las apps.
Map<String, Object?> versionJson(Map<String, Object?> v, String urlPublica) {
  final ruta = rutaArchivo(v['sha256'] as String);
  return {
    'build': v['build'],
    'version': v['version'],
    'requerido': v['requerido'],
    'notas': v['notas'],
    'sha256': v['sha256'],
    'bytes': v['bytes'],
    'paquete': v['paquete'],
    'firma': v['firma'],
    'min_sdk': v['min_sdk'],
    'target_sdk': v['target_sdk'],
    'descargas': v['descargas'],
    'publicado': v['publicado'],
    'publicado_por': v['publicado_por'],
    'retirada': v['retirada'],
    'ruta': ruta,
    'url': '$urlPublica$ruta',
  };
}
