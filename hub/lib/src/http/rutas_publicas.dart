import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../almacen.dart';
import '../catalogo.dart';
import '../limitador.dart';
import '../log.dart';
import 'servidor.dart';

/// Lo que usan las apps instaladas y la página de instalación. Todo sin
/// credencial, a propósito: un equipo nuevo no tiene ninguna, y lo que se
/// reparte (un APK que se instala en cualquier teléfono) ya es público en
/// cuanto sale. Lo que se protege es publicar, no descargar.
void registraRutasPublicas(Servidor s, Almacen almacen) {
  // Una consulta por equipo por hora es lo normal; esto frena al que martilla.
  final freno = Limitador(cupo: 240, ventana: const Duration(minutes: 1));

  Respuesta noEsta(String slug) =>
      Respuesta.falla(404, 'app_no_existe', 'No hay una app «$slug» en este hub');

  // Ficha pública de una app: la página de instalación sale de aquí.
  s.ruta('GET', '/v1/apps/:app', (p) async {
    final slug = p.params['app'] ?? '';
    final app = await appPorSlug(p.bd, slug);
    if (app == null) return noEsta(slug);
    final ultima = await ultimaVersion(p.bd, app['id'] as int);
    return Respuesta.ok({
      'slug': app['slug'],
      'nombre': app['nombre'],
      'descripcion': app['descripcion'],
      'paquete': app['paquete'],
      'icono': app['tiene_icono'] == true ? '/v1/apps/$slug/icono' : null,
      'instalar': '${p.urlPublica}/install/$slug',
      'pagina': '${p.urlPublica}/i/$slug',
      'ultima': ultima == null ? null : _publica(versionJson(ultima, p.urlPublica)),
    });
  }, acceso: Acceso.publico);

  s.ruta('GET', '/v1/apps/:app/icono', (p) async {
    final slug = p.params['app'] ?? '';
    if (!slugValido.hasMatch(slug)) return noEsta(slug);
    final f = await p.bd.fila(
      'select icono, icono_tipo from apk.app where slug = @s and icono is not null',
      {'s': slug},
    );
    if (f == null) return Respuesta.falla(404, 'sin_icono', '');
    final res = p.crudo.response;
    final tipo = (f['icono_tipo'] as String).split('/');
    res.headers
      ..contentType = ContentType(tipo[0], tipo[1])
      ..set('cache-control', 'public, max-age=3600')
      ..set('x-content-type-options', 'nosniff');
    if (p.crudo.method != 'HEAD') res.add(f['icono'] as List<int>);
    await res.close();
    return Respuesta.yaEscrita();
  }, acceso: Acceso.publico);

  // Consulta sin dejar rastro: para un script o para mirar a mano.
  s.ruta('GET', '/v1/apps/:app/ultima', (p) async {
    final slug = p.params['app'] ?? '';
    final app = await appPorSlug(p.bd, slug);
    if (app == null) return noEsta(slug);
    final build = int.tryParse(p.consulta['build'] ?? '') ?? 0;
    return Respuesta.ok(await _respuesta(p, app['id'] as int, build));
  }, acceso: Acceso.publico);

  // La consulta de las apps: «tengo la build N, ¿hay algo?». De paso deja
  // anotada la instalación (qué equipo, qué build, cuándo).
  s.ruta('POST', '/v1/apps/:app/consulta', (p) async {
    if (!freno.cabe(p.ip)) {
      return Respuesta.falla(429, 'demasiadas_consultas', 'Espera un minuto');
    }
    final slug = p.params['app'] ?? '';
    final app = await appPorSlug(p.bd, slug);
    if (app == null) return noEsta(slug);
    final appId = app['id'] as int;
    final build = p.entero('build') ?? 0;
    final clave = p.texto('instalacion');
    if (_claveValida(clave)) {
      try {
        await _anota(p, appId, clave, build);
      } catch (e) {
        // Que una estadística no le niegue la actualización a nadie.
        log.aviso('consulta', 'no se pudo anotar la instalación de $slug: $e');
      }
    }
    return Respuesta.ok(await _respuesta(p, appId, build));
  }, acceso: Acceso.publico);

  // El APK. Nombre = sha256: la URL no cambia nunca y se cachea para siempre.
  s.ruta('GET', '/archivos/:archivo', (p) async {
    final nombre = p.params['archivo'] ?? '';
    final sha = nombre.endsWith('.apk') ? nombre.substring(0, nombre.length - 4) : '';
    if (!Almacen.shaValido(sha)) return Respuesta.falla(404, 'no_encontrado', '');
    final v = await p.bd.fila(
      '''select v.id, v.version, v.build, v.retirada, a.slug
           from apk.version v join apk.app a on a.id = v.app
          where v.sha256 = @s
          order by (v.retirada is null) desc, v.build desc limit 1''',
      {'s': sha},
    );
    if (v == null || !almacen.existe(sha)) {
      return Respuesta.falla(404, 'no_encontrado', 'Ese APK no está en este hub');
    }
    if (v['retirada'] != null) {
      return Respuesta.falla(410, 'retirada', 'Esa versión se retiró');
    }
    final descargaCompleta = await _sirve(
      p.crudo,
      almacen.archivo(sha),
      '${v['slug']}-${v['version']}.apk',
    );
    if (descargaCompleta) {
      unawaited(p.bd
          .ejecuta('update apk.version set descargas = descargas + 1 where id = @i', {'i': v['id']})
          .catchError((_) {}));
    }
    return Respuesta.yaEscrita();
  }, acceso: Acceso.publico);

  // URL estable para instalar en un equipo nuevo: la última versión, sea cual
  // sea. Es la que va en un código QR o en un mensaje.
  Future<Respuesta> instalar(Peticion p) async {
    final slug = p.params['app'] ?? '';
    final app = await appPorSlug(p.bd, slug);
    if (app == null) return noEsta(slug);
    final ultima = await ultimaVersion(p.bd, app['id'] as int);
    if (ultima == null) {
      return Respuesta.falla(404, 'sin_versiones', '«$slug» todavía no tiene versiones publicadas');
    }
    return Respuesta(302, null, cabeceras: {
      'location': rutaArchivo(ultima['sha256'] as String),
      'cache-control': 'no-cache',
    });
  }

  s.ruta('GET', '/install/:app', instalar, acceso: Acceso.publico);
  // La forma vieja de la plataforma de la que salió esto (`/install/<app>/android`).
  s.ruta('GET', '/install/:app/:plataforma', instalar, acceso: Acceso.publico);
}

/// Lo que se contesta a «tengo la build N».
Future<Map<String, Object?>> _respuesta(Peticion p, int app, int build) async {
  final ultima = await ultimaVersion(p.bd, app);
  final actualizar = ultima != null && (ultima['build'] as int) > build;
  return {
    'build_actual': build,
    'actualizar': actualizar,
    'requerido': actualizar && await hayRequerida(p.bd, app, build),
    'version': ultima == null ? null : _publica(versionJson(ultima, p.urlPublica)),
  };
}

/// Lo que se enseña de una versión a cualquiera: sin quién la publicó ni
/// cuántas veces se bajó.
Map<String, Object?> _publica(Map<String, Object?> v) => {
      for (final k in const [
        'build', 'version', 'requerido', 'notas', 'sha256', 'bytes',
        'paquete', 'min_sdk', 'publicado', 'ruta', 'url',
      ])
        k: v[k],
    };

bool _claveValida(String c) =>
    c.length >= 8 && c.length <= 100 && RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(c);

String _corto(Peticion p, String clave, [int max = 120]) {
  final v = p.texto(clave);
  return v.length > max ? v.substring(0, max) : v;
}

/// Alta o puesta al día de la instalación que pregunta.
Future<void> _anota(Peticion p, int app, String clave, int build) async {
  final huellaCruda = _corto(p, 'huella', 100);
  final huella = huellaCruda.isEmpty ? null : huellaCruda;
  var contexto = p.cuerpo['contexto'];
  if (contexto is! Map || jsonEncode(contexto).length > 4096) contexto = const {};
  await p.bd.transaccion((tx) async {
    // Reinstalar la app genera otra clave, pero el ANDROID_ID es el mismo: se
    // sigue en la fila de antes y el equipo no aparece dos veces.
    if (huella != null) {
      await tx.ejecuta(
        '''update apk.instalacion set clave = @c
            where id = (select id from apk.instalacion
                         where app = @a and huella = @h
                         order by ultima_vez desc limit 1)
              and not exists (select 1 from apk.instalacion where app = @a and clave = @c)''',
        {'a': app, 'h': huella, 'c': clave},
      );
    }
    await tx.ejecuta(
      '''insert into apk.instalacion
           (app, clave, huella, build, version, modelo, fabricante, android, contexto, ip)
         values (@a, @c, @h, @b, @v, @m, @f, @and, @ctx, @ip)
         on conflict (app, clave) do update set
           huella = coalesce(excluded.huella, apk.instalacion.huella),
           build = excluded.build,
           version = case when excluded.version = '' then apk.instalacion.version else excluded.version end,
           modelo = case when excluded.modelo = '' then apk.instalacion.modelo else excluded.modelo end,
           fabricante = case when excluded.fabricante = '' then apk.instalacion.fabricante else excluded.fabricante end,
           android = coalesce(excluded.android, apk.instalacion.android),
           contexto = case when excluded.contexto = '{}'::jsonb then apk.instalacion.contexto
                           else excluded.contexto end,
           ip = excluded.ip,
           ultima_vez = now()''',
      {
        'a': app,
        'c': clave,
        'h': huella,
        'b': build,
        'v': _corto(p, 'version', 40),
        'm': _corto(p, 'modelo'),
        'f': _corto(p, 'fabricante'),
        'and': p.entero('android'),
        'ctx': contexto,
        'ip': p.ip,
      },
    );
  });
}

/// Manda [archivo] con soporte de `Range` (un teléfono que pierde la señal a
/// mitad de 50 MB retoma donde iba). Devuelve true si fue una descarga que
/// empieza desde el principio, que es lo que se cuenta como descarga.
Future<bool> _sirve(HttpRequest pet, File archivo, String nombre) async {
  final res = pet.response;
  final total = await archivo.length();
  var desde = 0;
  var hasta = total - 1;
  final rango = pet.headers.value(HttpHeaders.rangeHeader);
  var parcial = false;
  if (rango != null) {
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rango.trim());
    final a = m == null ? null : int.tryParse(m.group(1)!);
    final b = m == null ? null : int.tryParse(m.group(2)!);
    if (m == null || (a == null && b == null)) {
      return _rangoMalo(res, total);
    }
    if (a == null) {
      desde = total - b!.clamp(0, total);
    } else {
      desde = a;
      if (b != null) hasta = b < total ? b : total - 1;
    }
    if (desde >= total || desde > hasta) return _rangoMalo(res, total);
    parcial = true;
  }
  res.statusCode = parcial ? HttpStatus.partialContent : HttpStatus.ok;
  res.headers
    ..contentType = ContentType('application', 'vnd.android.package-archive')
    ..set('accept-ranges', 'bytes')
    ..set('content-length', '${hasta - desde + 1}')
    ..set('content-disposition', 'attachment; filename="$nombre"')
    ..set('cache-control', 'public, max-age=31536000, immutable');
  if (parcial) res.headers.set('content-range', 'bytes $desde-$hasta/$total');
  if (pet.method == 'HEAD') {
    await res.close();
    return false;
  }
  await res.addStream(archivo.openRead(desde, hasta + 1));
  await res.close();
  return desde == 0;
}

Future<bool> _rangoMalo(HttpResponse res, int total) async {
  res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
  res.headers.set('content-range', 'bytes */$total');
  await res.close();
  return false;
}
