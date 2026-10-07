import 'dart:io';

import 'config.dart';
import 'db.dart';
import 'http/rutas_auth.dart';
import 'http/rutas_llaves.dart';
import 'log.dart';
import 'seguridad.dart';

/// Órdenes de administración por consola, para lo que no se puede hacer desde
/// el panel porque todavía no hay nadie que entre: la primera organización, su
/// primer administrador y la primera llave.
///
/// Corren contra la misma base que el servicio (`APK_DATABASE_URL`) y escriben
/// el resultado —un enlace o una llave— en stdout y nada más, para que se
/// pueda mandar directo a un archivo sin que pase por la pantalla.
const ayudaCli = '''
Órdenes:
  (ninguna)                         arranca el servicio
  migrar                            aplica las migraciones y sale
  org --nombre N --correo C         organización nueva con su administrador;
                                    imprime el enlace para que ponga su clave
  invitar --correo C                enlace nuevo para un usuario que ya existe
  llave --org ID --nombre N         llave de API nueva; imprime la llave
        [--permisos publicar,leer,admin] [--apps slug1,slug2]
''';

Future<int> correCli(List<String> args, Config config, String migraciones) async {
  logAStderr();
  final orden = args.first;
  final op = _opciones(args.skip(1).toList());
  final bd = await Bd.abrir(config.urlBd);
  try {
    await bd.migrar(migraciones);
    final base = config.urlPublica.isEmpty
        ? 'http://localhost:${config.puerto}'
        : config.urlPublica;
    switch (orden) {
      case 'migrar':
        stderr.writeln('migraciones al día');
        return 0;

      case 'org':
        final nombre = op['nombre'] ?? '';
        final correo = (op['correo'] ?? '').toLowerCase();
        if (nombre.isEmpty || !correo.contains('@')) return _uso('org --nombre N --correo C');
        final token = await bd.transaccion((tx) async {
          final org = await creaOrg(tx, nombre);
          final u = await tx.fila(
            '''insert into apk.usuario (org, correo, nombre, rol)
               values (@o, @c, @n, 'admin') returning id''',
            {'o': org, 'c': correo, 'n': op['nombre-persona'] ?? correo.split('@').first},
          );
          stderr.writeln('organización $org creada; administrador ${u!['id']} sin clave todavía');
          return nuevaInvitacion(tx, u['id'] as int);
        });
        stdout.writeln(enlaceInvitacion(base, token));
        return 0;

      case 'invitar':
        final correo = (op['correo'] ?? '').toLowerCase();
        final u = await bd.fila('select id from apk.usuario where correo = @c', {'c': correo});
        if (u == null) {
          stderr.writeln('no hay un usuario con ese correo');
          return 1;
        }
        stdout.writeln(enlaceInvitacion(base, await nuevaInvitacion(bd, u['id'] as int)));
        return 0;

      case 'llave':
        final org = int.tryParse(op['org'] ?? '');
        final nombre = op['nombre'] ?? '';
        if (org == null || nombre.isEmpty) return _uso('llave --org ID --nombre N');
        final permisos = _lista(op['permisos'], porDefecto: ['publicar']);
        final malos = permisos.toSet().difference(permisosValidos);
        if (malos.isNotEmpty) {
          stderr.writeln('permisos que no existen: ${malos.join(", ")}');
          return 64;
        }
        final prefijo = Seguridad.hex(4);
        final secreto = Seguridad.token();
        await bd.ejecuta(
          '''insert into apk.llave (org, nombre, prefijo, clave_hash, permisos, apps)
             values (@o, @n, @p, @h, @perm, @apps)''',
          {
            'o': org,
            'n': nombre,
            'p': prefijo,
            'h': Seguridad.hashToken(secreto),
            'perm': permisos,
            'apps': _lista(op['apps']),
          },
        );
        stderr.writeln('llave «$nombre» creada (prefijo $prefijo)');
        stdout.writeln('cak_${prefijo}_$secreto');
        return 0;
    }
    stderr.writeln('orden desconocida: $orden\n$ayudaCli');
    return 64;
  } finally {
    await bd.cerrar();
  }
}

int _uso(String forma) {
  stderr.writeln('uso: apk-server-hub $forma');
  return 64;
}

List<String> _lista(String? v, {List<String> porDefecto = const []}) {
  final l = (v ?? '').split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
  return l.isEmpty ? porDefecto : l;
}

Map<String, String> _opciones(List<String> args) {
  final r = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) continue;
    final igual = a.indexOf('=');
    if (igual > 0) {
      r[a.substring(2, igual)] = a.substring(igual + 1);
    } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      r[a.substring(2)] = args[++i];
    } else {
      r[a.substring(2)] = 'true';
    }
  }
  return r;
}
