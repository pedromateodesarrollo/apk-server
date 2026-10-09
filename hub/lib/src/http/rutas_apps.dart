import 'dart:typed_data';

import '../almacen.dart';
import '../apk_info.dart';
import '../catalogo.dart';
import '../log.dart';
import '../ws/avisos.dart';
import 'servidor.dart';

/// Tope del icono de una app. Es para la página de instalación, no un póster.
const _maxIcono = 512 * 1024;

/// El panel: apps, versiones e instalaciones de la organización.
void registraRutasApps(Servidor s, Almacen almacen, Avisos avisos) {
  /// La app [slug] si es de la organización de quien llama y su credencial la
  /// alcanza. Una app ajena da 404, no 403: no se confirma que exista.
  Future<Map<String, Object?>?> propia(Peticion p) async {
    final slug = p.params['app'] ?? '';
    final app = await appPorSlug(p.bd, slug);
    if (app == null || app['org'] != p.s.org || !p.s.alcanza(slug)) return null;
    return app;
  }

  Respuesta noEsta() =>
      Respuesta.falla(404, 'app_no_existe', 'No hay una app con ese nombre en tu organización');

  Respuesta sinPermiso(String permiso) =>
      Respuesta.falla(403, 'sin_permiso', 'La llave no tiene el permiso «$permiso»');

  // ------------------------------------------------------------------ apps

  s.ruta('GET', '/v1/apps', (p) async {
    if (!p.s.puede('leer')) return sinPermiso('leer');
    final filas = await p.bd.filas(
      '''select a.id, a.slug, a.nombre, a.descripcion, a.paquete, a.firma,
                a.icono is not null as tiene_icono, a.creado,
                u.build as ultima_build, u.version as ultima_version,
                u.publicado as ultima_publicada, u.requerido as ultima_requerida,
                (select count(*) from apk.version v where v.app = a.id)::int as versiones,
                (select coalesce(sum(v.bytes), 0) from apk.version v where v.app = a.id)::bigint as bytes,
                (select count(*) from apk.instalacion i
                  where i.app = a.id and i.ultima_vez > now() - interval '30 days')::int as instalaciones,
                (select count(*) from apk.instalacion i
                  where i.app = a.id and i.ultima_vez > now() - interval '30 days'
                    and i.build = u.build)::int as al_dia
           from apk.app a
           left join lateral (
             select v.build, v.version, v.publicado, v.requerido from apk.version v
              where v.app = a.id and v.retirada is null
              order by v.build desc limit 1
           ) u on true
          where a.org = @o
          order by a.nombre''',
      {'o': p.s.org},
    );
    return Respuesta.ok({
      'apps': [
        for (final f in filas)
          if (p.s.alcanza(f['slug'] as String))
            {...f, 'conectadas': avisos.conectados(f['slug'] as String)},
      ],
    });
  });

  s.ruta('POST', '/v1/apps', (p) async {
    final slug = p.texto('slug').toLowerCase();
    final nombre = p.texto('nombre');
    if (!slugValido.hasMatch(slug)) {
      return Respuesta.falla(400, 'slug_invalido',
          'El identificador va en minúsculas, números y guiones (ej. «inventario» o «inventario-marca»)');
    }
    if (nombre.isEmpty) {
      return Respuesta.falla(400, 'falta_nombre', 'Ponle nombre a la app');
    }
    if (await appPorSlug(p.bd, slug) != null) {
      return Respuesta.falla(409, 'slug_en_uso', 'Ya hay una app «$slug» en este hub');
    }
    final app = await p.bd.fila(
      '''insert into apk.app (org, slug, nombre, descripcion)
         values (@o, @s, @n, @d)
         returning id, slug, nombre, descripcion, creado''',
      {'o': p.s.org, 's': slug, 'n': nombre, 'd': p.texto('descripcion')},
    );
    log.info('apps', 'app nueva: $slug (org ${p.s.org})');
    return Respuesta.creado(app);
  }, acceso: Acceso.admin);

  s.ruta('PATCH', '/v1/apps/:app', (p) async {
    final app = await propia(p);
    if (app == null) return noEsta();
    final nombre = p.cuerpo.containsKey('nombre') ? p.texto('nombre') : app['nombre'];
    if (nombre == '') return Respuesta.falla(400, 'falta_nombre', 'El nombre no puede quedar vacío');
    final r = await p.bd.fila(
      '''update apk.app set nombre = @n, descripcion = @d where id = @i
         returning slug, nombre, descripcion''',
      {
        'i': app['id'],
        'n': nombre,
        'd': p.cuerpo.containsKey('descripcion') ? p.texto('descripcion') : app['descripcion'],
      },
    );
    return Respuesta.ok(r);
  }, acceso: Acceso.admin);

  // Una app se borra solo vacía: los APK de sus versiones son lo que los
  // equipos tienen instalado, y borrarlos por un clic no tiene vuelta.
  s.ruta('DELETE', '/v1/apps/:app', (p) async {
    final app = await propia(p);
    if (app == null) return noEsta();
    final v = await p.bd.fila('select 1 from apk.version where app = @a limit 1', {'a': app['id']});
    if (v != null) {
      return Respuesta.falla(409, 'tiene_versiones',
          'Borra primero sus versiones (retirarlas y después borrarlas)');
    }
    await p.bd.ejecuta('delete from apk.app where id = @a', {'a': app['id']});
    return Respuesta.vacio();
  }, acceso: Acceso.admin);

  s.ruta('PUT', '/v1/apps/:app/icono', (p) async {
    final app = await propia(p);
    if (app == null) return noEsta();
    final bytes = BytesBuilder(copy: false);
    await for (final trozo in p.crudo) {
      bytes.add(trozo);
      if (bytes.length > _maxIcono) {
        return Respuesta.falla(413, 'icono_grande', 'El icono puede pesar hasta 512 KB');
      }
    }
    final datos = bytes.takeBytes();
    final tipo = _tipoImagen(datos);
    if (tipo == null) {
      return Respuesta.falla(400, 'icono_invalido', 'El icono tiene que ser PNG, JPEG o WebP');
    }
    await p.bd.ejecuta(
      'update apk.app set icono = @b, icono_tipo = @t where id = @a',
      {'b': datos, 't': tipo, 'a': app['id']},
    );
    return Respuesta.ok({'ok': true});
  }, acceso: Acceso.admin, crudo: true);

  s.ruta('DELETE', '/v1/apps/:app/icono', (p) async {
    final app = await propia(p);
    if (app == null) return noEsta();
    await p.bd.ejecuta(
      'update apk.app set icono = null, icono_tipo = null where id = @a',
      {'a': app['id']},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);

  // ------------------------------------------------------------- versiones

  s.ruta('GET', '/v1/apps/:app/versiones', (p) async {
    if (!p.s.puede('leer')) return sinPermiso('leer');
    final app = await propia(p);
    if (app == null) return noEsta();
    final filas = await p.bd.filas(
      '''select $columnasVersion,
                (select count(*) from apk.instalacion i
                  where i.app = v.app and i.build = v.build
                    and i.ultima_vez > now() - interval '30 days')::int as instalaciones
           from apk.version v where v.app = @a order by v.build desc''',
      {'a': app['id']},
    );
    return Respuesta.ok({
      'app': app,
      'versiones': [
        for (final f in filas)
          {...versionJson(f, p.urlPublica), 'instalaciones': f['instalaciones']},
      ],
    });
  });

  // Publicar. El cuerpo es el APK tal cual (`curl --data-binary @app.apk`).
  // Lo que se dice por la consulta (`version`, `build`) es opcional y solo se
  // usa para comprobar: lo que manda es lo que trae el APK.
  s.ruta('POST', '/v1/apps/:app/versiones', (p) async {
    if (!p.s.puede('publicar')) return sinPermiso('publicar');
    final app = await propia(p);
    if (app == null) return noEsta();
    final slug = app['slug'] as String;

    final Subida subida;
    try {
      subida = await almacen.recibe(p.crudo, p.config.maxApkBytes);
    } on SubidaGrande catch (e) {
      return Respuesta.falla(413, 'apk_grande', 'El tope es ${e.maximo ~/ (1024 * 1024)} MB');
    }
    if (subida.bytes == 0) {
      subida.descarta();
      return Respuesta.falla(400, 'apk_vacio', 'No llegó nada. Manda el APK en el cuerpo.');
    }

    final ApkInfo info;
    try {
      info = await ApkInfo.deArchivo(subida.temporal);
    } on ApkInvalido catch (e) {
      subida.descarta();
      return Respuesta.falla(400, 'apk_invalido', e.motivo);
    }

    Respuesta? rechazo;
    final q = p.consulta;
    final buildDicha = int.tryParse(q['build'] ?? '');
    final versionDicha = (q['version'] ?? '').trim();
    if (buildDicha != null && buildDicha != info.build) {
      rechazo = Respuesta.falla(400, 'build_no_coincide',
          'Dices build $buildDicha y el APK trae versionCode ${info.build}. ¿Es el APK que querías?');
    } else if (versionDicha.isNotEmpty && info.version.isNotEmpty && versionDicha != info.version) {
      rechazo = Respuesta.falla(400, 'version_no_coincide',
          'Dices versión $versionDicha y el APK trae versionName ${info.version}');
    } else if (info.app != null && info.app!.isNotEmpty && info.app != slug) {
      // El APK dice de qué app es (la biblioteca de Android lo pone en el
      // manifiesto): uno de otro sabor preguntaría por la suya y no por esta.
      rechazo = Respuesta.falla(409, 'app_distinta',
          'Ese APK es de la app «${info.app}» (lo dice su manifiesto, apkServerApp), no de «$slug».');
    } else if (info.hub != null && info.hub!.isNotEmpty && !_mismoHub(info.hub!, p.urlPublica)) {
      rechazo = Respuesta.falla(409, 'hub_distinto',
          'Ese APK pregunta por sus versiones a ${info.hub} (apkServerHub), no a este hub: '
              'los equipos nunca verían esta publicación.');
    } else if (app['paquete'] != null && app['paquete'] != info.paquete) {
      rechazo = Respuesta.falla(409, 'paquete_distinto',
          'Ese APK es de ${info.paquete} y la app «$slug» es ${app['paquete']}. '
              'Dos applicationId son dos apps: publícalo en la suya.');
    } else if (app['firma'] != null && info.firma != null && app['firma'] != info.firma) {
      rechazo = Respuesta.falla(409, 'firma_distinta',
          'Ese APK está firmado con otra llave. Los equipos que tienen «$slug» no podrían '
              'actualizar: Android rechaza una actualización con otra firma.');
    }
    if (rechazo != null) {
      subida.descarta();
      return rechazo;
    }

    final previa = await p.bd.fila(
      'select $columnasVersion from apk.version v where v.app = @a and v.build = @b',
      {'a': app['id'], 'b': info.build},
    );
    if (previa != null) {
      subida.descarta();
      // Repetir la misma publicación no es un error: el script que se cortó
      // a la mitad puede volver a correr sin pensar.
      if (previa['sha256'] == subida.sha256) {
        return Respuesta.ok({...versionJson(previa, p.urlPublica), 'ya_estaba': true});
      }
      return Respuesta.falla(409, 'build_repetida',
          'La build ${info.build} ya está publicada con otro APK. Sube el versionCode.');
    }

    almacen.fija(subida);
    final requerido = const ['1', 'true', 'si', 'sí'].contains((q['requerido'] ?? '').toLowerCase());
    final Map<String, Object?> nueva;
    try {
      nueva = await p.bd.transaccion((tx) async {
        final v = await tx.fila(
          '''insert into apk.version
               (app, build, version, requerido, notas, sha256, bytes, paquete, firma,
                min_sdk, target_sdk, publicado_por)
             values (@a, @b, @v, @r, @n, @sha, @bytes, @paq, @firma, @min, @target, @por)
             returning id, build, version, requerido, notas, sha256, bytes, paquete, firma,
                       min_sdk, target_sdk, descargas, publicado, publicado_por, retirada''',
          {
            'a': app['id'],
            'b': info.build,
            'v': info.version.isEmpty ? (versionDicha.isEmpty ? '${info.build}' : versionDicha) : info.version,
            'r': requerido,
            'n': (q['notas'] ?? '').trim(),
            'sha': subida.sha256,
            'bytes': subida.bytes,
            'paq': info.paquete,
            'firma': info.firma,
            'min': info.minSdk,
            'target': info.targetSdk,
            'por': p.s.firma,
          },
        );
        // La primera versión fija el paquete y la firma de la app.
        await tx.ejecuta(
          '''update apk.app set paquete = coalesce(paquete, @paq),
                                firma = coalesce(firma, @firma)
              where id = @a''',
          {'a': app['id'], 'paq': info.paquete, 'firma': info.firma},
        );
        return v!;
      });
    } catch (e) {
      await _borraSiHuerfano(p, almacen, subida.sha256);
      rethrow;
    }

    final ultima = await ultimaVersion(p.bd, app['id'] as int);
    var avisadas = 0;
    if (ultima != null && ultima['build'] == info.build) {
      avisadas = avisos.anuncia(slug, {'build': info.build, 'requerido': requerido});
    }
    log.info('versiones',
        '$slug ${nueva['version']}+${info.build} publicada por ${p.s.firma} (${subida.bytes} bytes, avisadas $avisadas)');
    return Respuesta.creado({...versionJson(nueva, p.urlPublica), 'avisadas': avisadas});
  }, acceso: Acceso.cualquiera, crudo: true);

  // Cambiar notas, marcarla obligatoria o retirarla (y devolverla).
  s.ruta('PATCH', '/v1/apps/:app/versiones/:build', (p) async {
    if (!p.s.puede('publicar')) return sinPermiso('publicar');
    final app = await propia(p);
    if (app == null) return noEsta();
    final build = p.enteroParam('build');
    final v = await p.bd.fila(
      'select $columnasVersion from apk.version v where v.app = @a and v.build = @b',
      {'a': app['id'], 'b': build},
    );
    if (v == null) return Respuesta.falla(404, 'version_no_existe', 'No hay build $build');
    final c = p.cuerpo;
    final retirar = c.containsKey('retirada') ? c['retirada'] == true : v['retirada'] != null;
    final r = await p.bd.fila(
      '''update apk.version
            set notas = @n, requerido = @r,
                retirada = case when @ret then coalesce(retirada, now()) else null end
          where id = @i
          returning id, build, version, requerido, notas, sha256, bytes, paquete, firma,
                    min_sdk, target_sdk, descargas, publicado, publicado_por, retirada''',
      {
        'i': v['id'],
        'n': c.containsKey('notas') ? p.texto('notas') : v['notas'],
        'r': c.containsKey('requerido') ? c['requerido'] == true : v['requerido'],
        'ret': retirar,
      },
    );
    // Cambió lo que se ofrece: que los equipos conectados pregunten de nuevo.
    final ultima = await ultimaVersion(p.bd, app['id'] as int);
    avisos.anuncia(app['slug'] as String, {
      'build': ultima?['build'],
      'requerido': ultima?['requerido'],
    });
    return Respuesta.ok(versionJson(r!, p.urlPublica));
  }, acceso: Acceso.cualquiera);

  // Borrar del todo (la fila y, si nadie más lo usa, el APK). Solo una versión
  // ya retirada: retirar es el paso que se puede deshacer.
  s.ruta('DELETE', '/v1/apps/:app/versiones/:build', (p) async {
    final app = await propia(p);
    if (app == null) return noEsta();
    final build = p.enteroParam('build');
    final v = await p.bd.fila(
      'select id, sha256, retirada from apk.version where app = @a and build = @b',
      {'a': app['id'], 'b': build},
    );
    if (v == null) return Respuesta.falla(404, 'version_no_existe', 'No hay build $build');
    if (v['retirada'] == null) {
      return Respuesta.falla(409, 'no_retirada', 'Retírala primero; borrar no tiene vuelta');
    }
    await p.bd.ejecuta('delete from apk.version where id = @i', {'i': v['id']});
    await _borraSiHuerfano(p, almacen, v['sha256'] as String);
    return Respuesta.vacio();
  }, acceso: Acceso.admin);

  // ---------------------------------------------------------- instalaciones

  s.ruta('GET', '/v1/apps/:app/instalaciones', (p) async {
    if (!p.s.puede('leer')) return sinPermiso('leer');
    final app = await propia(p);
    if (app == null) return noEsta();
    final dias = (int.tryParse(p.consulta['dias'] ?? '') ?? 90).clamp(1, 3650);
    final filas = await p.bd.filas(
      '''select id, clave, huella, build, version, modelo, fabricante, android,
                contexto, ip, nombre, conectado, primera_vez, ultima_vez
           from apk.instalacion
          where app = @a and ultima_vez > now() - make_interval(days => @d)
          order by conectado desc, ultima_vez desc
          limit 2000''',
      {'a': app['id'], 'd': dias},
    );
    final porBuild = await p.bd.filas(
      '''select build, max(version) as version, count(*)::int as cuantas,
                count(*) filter (where conectado)::int as conectadas
           from apk.instalacion
          where app = @a and ultima_vez > now() - make_interval(days => @d)
          group by build order by build desc nulls last''',
      {'a': app['id'], 'd': dias},
    );
    return Respuesta.ok({'instalaciones': filas, 'por_build': porBuild});
  });

  // Ponerle nombre a un equipo («Terminal 3 — recepción»).
  s.ruta('PATCH', '/v1/apps/:app/instalaciones/:id', (p) async {
    final app = await propia(p);
    if (app == null) return noEsta();
    final r = await p.bd.fila(
      '''update apk.instalacion set nombre = @n where id = @i and app = @a
         returning id, nombre''',
      {'n': p.texto('nombre'), 'i': p.enteroParam('id'), 'a': app['id']},
    );
    return r == null ? Respuesta.falla(404, 'no_encontrado', '') : Respuesta.ok(r);
  });

  s.ruta('DELETE', '/v1/apps/:app/instalaciones/:id', (p) async {
    final app = await propia(p);
    if (app == null) return noEsta();
    await p.bd.ejecuta(
      'delete from apk.instalacion where id = @i and app = @a',
      {'i': p.enteroParam('id'), 'a': app['id']},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}

/// Borra el APK de disco si ninguna versión (de ninguna app) lo usa ya.
Future<void> _borraSiHuerfano(Peticion p, Almacen almacen, String sha) async {
  final otro = await p.bd.fila('select 1 from apk.version where sha256 = @s limit 1', {'s': sha});
  if (otro == null) almacen.borra(sha);
}

/// PNG, JPEG o WebP, por sus primeros bytes. No se cree el Content-Type: la
/// imagen se sirve después a cualquiera, y un SVG puede llevar script.
String? _tipoImagen(Uint8List b) {
  if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return 'image/jpeg';
  if (b.length > 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

/// ¿[a] y [b] son el mismo hub? Sin la barra final ni mayúsculas en el
/// esquema y el host (`https://Apk.Ejemplo.com/` = `https://apk.ejemplo.com`).
bool _mismoHub(String a, String b) {
  Uri? limpia(String s) {
    final u = Uri.tryParse(s.trim().replaceAll(RegExp(r'/+$'), ''));
    if (u == null || !u.hasScheme) return null;
    return u.replace(scheme: u.scheme.toLowerCase(), host: u.host.toLowerCase());
  }

  final x = limpia(a), y = limpia(b);
  return x != null && y != null && x == y;
}
