import '../seguridad.dart';
import 'servidor.dart';

/// Permisos que puede llevar una llave de API. Pocos a propósito: la llave que
/// vive en el script de publicación de una app no debería poder borrar otras
/// llaves ni invitar a nadie.
const permisosValidos = {
  // Subir versiones nuevas (y nada más).
  'publicar',
  // Leer el panel por API: apps, versiones e instalaciones.
  'leer',
  // Todo, incluida la gestión de usuarios y de otras llaves. Es para
  // automatizar la administración desde otro sistema; no se reparte.
  'admin',
};

/// Llaves de API para los scripts que publican.
///
/// No caducan solas —un script de despliegue no está para renovar tokens— así
/// que lo que hay es revocación. Se pueden acotar a unas apps: la llave del
/// proyecto del WMS no tiene por qué poder publicar la app de compras.
void registraRutasLlaves(Servidor s) {
  s.ruta('GET', '/v1/llaves', (p) async {
    final r = await p.bd.filas(
      '''select id, nombre, prefijo, permisos, apps, creado, ultimo_uso, revocada
           from apk.llave where org = @o order by id desc''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'llaves': r});
  }, acceso: Acceso.admin);

  s.ruta('POST', '/v1/llaves', (p) async {
    final nombre = p.texto('nombre');
    if (nombre.isEmpty) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre para saber después qué la usa');
    }
    final pedidos = ((p.cuerpo['permisos'] as List?) ?? const [])
        .map((x) => x.toString())
        .toSet();
    final permisos = pedidos.isEmpty ? {'publicar'} : pedidos;
    final malos = permisos.difference(permisosValidos);
    if (malos.isNotEmpty) {
      return Respuesta.falla(400, 'permiso_invalido',
          'No existe: ${malos.join(", ")}. Válidos: ${permisosValidos.join(", ")}');
    }
    final apps = ((p.cuerpo['apps'] as List?) ?? const [])
        .map((x) => x.toString().trim())
        .where((x) => x.isNotEmpty)
        .toSet();
    if (apps.isNotEmpty) {
      final propias = (await p.bd.filas(
        'select slug from apk.app where org = @o and slug = any(@s)',
        {'o': p.s.org, 's': apps.toList()},
      ))
          .map((f) => f['slug'] as String)
          .toSet();
      final ajenas = apps.difference(propias);
      if (ajenas.isNotEmpty) {
        return Respuesta.falla(400, 'app_desconocida',
            'Esas apps no son de tu organización: ${ajenas.join(", ")}');
      }
    }

    // Hex, no base64url: el prefijo viaja dentro de `cak_<prefijo>_<secreto>`
    // y un guion bajo ahí rompería el corte.
    final prefijo = Seguridad.hex(4);
    final secreto = Seguridad.token();
    final l = await p.bd.fila(
      '''insert into apk.llave (org, nombre, prefijo, clave_hash, permisos, apps)
         values (@o, @n, @p, @h, @perm, @apps)
         returning id, nombre, prefijo, permisos, apps, creado''',
      {
        'o': p.s.org,
        'n': nombre,
        'p': prefijo,
        'h': Seguridad.hashToken(secreto),
        'perm': permisos.toList(),
        'apps': apps.toList(),
      },
    );
    return Respuesta.creado({
      ...l!,
      // Única vez que se ve completa. Se guarda hasheada.
      'llave': 'cak_${prefijo}_$secreto',
    });
  }, acceso: Acceso.admin);

  /// Revocar, no borrar: la fila sigue explicando qué llave publicó la versión
  /// de la semana pasada.
  s.ruta('DELETE', '/v1/llaves/:id', (p) async {
    await p.bd.ejecuta(
      'update apk.llave set revocada = now() where id = @i and org = @o and revocada is null',
      {'i': p.enteroParam('id'), 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}
