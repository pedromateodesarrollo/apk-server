import 'dart:async';

import '../correo.dart';
import '../db.dart';
import '../limitador.dart';
import '../log.dart';
import '../seguridad.dart';
import 'rutas_org.dart';
import 'servidor.dart';

/// Cuánto vale un enlace de invitación.
const vidaInvitacion = Duration(days: 7);

/// Cuánto vale el enlace de «¿Olvidaste tu clave?». Corto: lo pide cualquiera
/// que sepa un correo, y llega a un buzón que puede estar en manos de otro.
const vidaRecuperacion = Duration(hours: 1);

/// Sesión, invitaciones y gestión de usuarios.
///
/// El hub tiene identidad propia —usuarios y claves suyos— porque un tercero
/// que lo instale no tiene de dónde sacarlas. Las personas entran por
/// invitación: el administrador pone el correo y el enlace le llega por el
/// correo de salida de la organización, o se lo comparte él si no hay; la
/// clave la escribe la persona, y el administrador nunca la ve. Con correo de
/// salida, quien olvidó su clave pide otro enlace desde la entrada.
void registraRutasAuth(Servidor s) {
  final freno = Limitador(cupo: 10, ventana: const Duration(minutes: 1));
  // «¿Olvidaste tu clave?» manda un correo a quien diga el que lo pide: dos
  // frenos, uno por IP (quien prueba correos) y otro por correo (que nadie le
  // llene el buzón a otro).
  final frenoRecuperarIp = Limitador(cupo: 5, ventana: const Duration(minutes: 1));
  final frenoRecuperarCorreo = Limitador(cupo: 3, ventana: const Duration(hours: 1));

  // `recuperar` le dice a la entrada del panel si ofrecer «¿Olvidaste tu
  // clave?»: solo si alguna organización tiene correo de salida.
  s.ruta('GET', '/salud', (p) async {
    await p.bd.fila('select 1 as ok');
    return Respuesta.ok({
      'ok': true,
      'servicio': 'apk-server',
      'registro': p.config.registro,
      // Sin APK_URL_PUBLICA tampoco: el enlace no puede armarse con el Host de
      // la petición, que lo escribe quien la manda (pediría la clave de otro y
      // el token llegaría a su página).
      'recuperar': p.config.urlPublica.isNotEmpty && await hayCorreoDeSalida(p.bd),
    });
  }, acceso: Acceso.publico);

  // Alta de organización. Solo con APK_REGISTRO=abierto.
  s.ruta('POST', '/v1/auth/registro', (p) async {
    if (p.config.registro != 'abierto') {
      return Respuesta.falla(
        403,
        'registro_cerrado',
        'Este hub no acepta altas por su cuenta; pídele una invitación a un administrador',
      );
    }
    if (!freno.cabe('registro:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final correo = p.texto('correo').toLowerCase();
    final clave = p.texto('clave');
    final organizacion = p.texto('organizacion');
    final problema = _revisaCorreo(correo) ?? _revisaClave(clave);
    if (problema != null) return problema;
    if (organizacion.isEmpty) {
      return Respuesta.falla(400, 'falta_organizacion', 'Ponle nombre a la organización');
    }
    if (await _correoOcupado(p.bd, correo)) {
      return Respuesta.falla(409, 'correo_en_uso', 'Ese correo ya tiene cuenta');
    }

    final creado = await p.bd.transaccion((tx) async {
      final org = await creaOrg(tx, organizacion);
      return await tx.fila(
        '''insert into apk.usuario (org, correo, clave_hash, nombre, rol)
           values (@o, @c, @h, @n, 'admin')
           returning id, org, correo, nombre, rol''',
        {
          'o': org,
          'c': correo,
          'h': Seguridad.hashClave(clave),
          'n': p.texto('nombre', porDefecto: correo.split('@').first),
        },
      );
    });

    log.info('auth', 'organización nueva: $organizacion');
    return Respuesta.creado(_conToken(creado!, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  s.ruta('POST', '/v1/auth/login', (p) async {
    final correo = p.texto('correo').toLowerCase();
    if (!freno.cabe('login:${p.ip}') || !freno.cabe('login:$correo')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final u = await p.bd.fila(
      'select id, org, correo, nombre, rol, clave_hash from apk.usuario where correo = @c',
      {'c': correo},
    );
    // Mismo error para «no existe», «clave mala» y «todavía no activó su
    // invitación»: la diferencia le diría a quien prueba correos cuáles están.
    const malas = 'Correo o clave incorrectos';
    final hash = u?['clave_hash'] as String?;
    if (u == null || hash == null || !Seguridad.verificaClave(p.texto('clave'), hash)) {
      return Respuesta.falla(401, 'credenciales_invalidas', malas);
    }
    freno.olvida('login:$correo');
    await p.bd.ejecuta(
      'update apk.usuario set ultimo_acceso = now() where id = @i',
      {'i': u['id']},
    );
    return Respuesta.ok(_conToken(u, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  // «¿Olvidaste tu clave?». Contesta siempre lo mismo, exista o no el correo y
  // tenga o no correo de salida su organización: nada aquí sirve para
  // averiguar qué correos tienen cuenta. Lo único que se espera es la
  // búsqueda, que se hace en los dos casos; el enlace y el correo van aparte
  // (`unawaited`), porque si se esperaran la respuesta tardaría más cuando la
  // cuenta existe, y eso la delataría.
  //
  // El enlace es el mismo de la invitación (`/#/activar/<token>`), con otra
  // vida: una hora. Solo se genera si el correo puede salir: sin correo de
  // salida, pedirlo no le toca nada a nadie (ni le invalida un enlace que ya
  // tuviera).
  s.ruta('POST', '/v1/auth/recuperar', (p) async {
    if (!frenoRecuperarIp.cabe('recuperar:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Demasiados pedidos seguidos. Espera un minuto.');
    }
    final correo = p.texto('correo').toLowerCase();
    final problema = _revisaCorreo(correo);
    if (problema != null) return problema;
    if (!frenoRecuperarCorreo.cabe('recuperar:$correo')) {
      return Respuesta.falla(
        429,
        'demasiados_intentos',
        'Ya se pidieron varios enlaces para ese correo. Espera una hora o pídele uno a quien administra.',
      );
    }
    final u = await p.bd.fila(
      '''select u.id, u.nombre, o.nombre as organizacion, o.correo as salida
           from apk.usuario u join apk.org o on o.id = u.org
          where u.correo = @c''',
      {'c': correo},
    );
    if (u != null) {
      final id = u['id'] as int;
      log.info('auth', 'recuperación pedida: usuario $id');
      final c = ConfigCorreo.deJson(u['salida']);
      if (c != null && c.completa && p.config.urlPublica.isNotEmpty) {
        unawaited(_mandaRecuperacion(
          p.bd,
          c,
          usuario: id,
          para: correo,
          nombre: '${u['nombre']}',
          org: '${u['organizacion']}',
          urlPublica: p.config.urlPublica,
        ));
      } else {
        log.aviso('auth', 'la organización del usuario $id no tiene correo de salida: no se mandó nada');
      }
    }
    return Respuesta.ok({'pedido': true});
  }, acceso: Acceso.publico);

  // Lo que la pantalla de activación puede enseñar antes de que la persona
  // ponga su clave: el correo y si el enlace sirve. Nada de la organización:
  // quien tiene el enlace todavía no ha demostrado nada.
  s.ruta('GET', '/v1/auth/invitacion/:token', (p) async {
    if (!freno.cabe('invitacion:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final u = await _porInvitacion(p.bd, p.params['token'] ?? '');
    if (u == null) {
      return Respuesta.falla(404, 'invitacion_invalida', 'Ese enlace no existe o ya se usó');
    }
    final vence = u['invitacion_vence'] as DateTime?;
    return Respuesta.ok({
      'correo': u['correo'],
      'vigente': vence != null && vence.isAfter(DateTime.now()),
    });
  }, acceso: Acceso.publico);

  s.ruta('POST', '/v1/auth/activar', (p) async {
    if (!freno.cabe('invitacion:${p.ip}')) {
      return Respuesta.falla(429, 'demasiados_intentos', 'Espera un minuto');
    }
    final clave = p.texto('clave');
    final problema = _revisaClave(clave);
    if (problema != null) return problema;
    final u = await _porInvitacion(p.bd, p.texto('token'));
    final vence = u?['invitacion_vence'] as DateTime?;
    if (u == null || vence == null || vence.isBefore(DateTime.now())) {
      return Respuesta.falla(
        410,
        'invitacion_vencida',
        'El enlace venció o ya se usó. Pide otro: en la entrada, «¿Olvidaste tu clave?», o a quien administra.',
      );
    }
    final hecho = await p.bd.fila(
      '''update apk.usuario
            set clave_hash = @h, invitacion_hash = null, invitacion_vence = null,
                ultimo_acceso = now()
          where id = @i
          returning id, org, correo, nombre, rol''',
      {'h': Seguridad.hashClave(clave), 'i': u['id']},
    );
    log.info('auth', 'clave puesta con un enlace: usuario ${u['id']}');
    return Respuesta.ok(_conToken(hecho!, p.config.secretoJwt));
  }, acceso: Acceso.publico);

  s.ruta('GET', '/v1/yo', (p) async {
    if (!p.s.esUsuario) {
      return Respuesta.ok({'org': p.s.org, 'llave': p.s.llave, 'rol': 'api'});
    }
    final u = await p.bd.fila(
      '''select u.id, u.correo, u.nombre, u.rol, u.org, o.nombre as organizacion
           from apk.usuario u join apk.org o on o.id = u.org
          where u.id = @i''',
      {'i': p.s.usuario},
    );
    return u == null ? Respuesta.falla(404, 'no_encontrado', '') : Respuesta.ok(u);
  });

  s.ruta('GET', '/v1/usuarios', (p) async {
    final r = await p.bd.filas(
      '''select id, correo, nombre, rol, creado, ultimo_acceso,
                clave_hash is not null as activo,
                invitacion_vence
           from apk.usuario where org = @o order by id''',
      {'o': p.s.org},
    );
    return Respuesta.ok({'usuarios': r});
  }, acceso: Acceso.admin);

  // Invitar: la persona queda dada de alta sin clave, y lo que se devuelve es
  // el enlace (una sola vez: se guarda hasheado). Si la organización tiene
  // correo de salida (migración 0002), además se lo manda; si no, el enlace lo
  // comparte quien invita, por donde quiera. `envio` dice cuál de las dos.
  s.ruta('POST', '/v1/usuarios', (p) async {
    final correo = p.texto('correo').toLowerCase();
    final problema = _revisaCorreo(correo);
    if (problema != null) return problema;
    final rol = p.texto('rol', porDefecto: 'editor');
    if (rol != 'admin' && rol != 'editor') {
      return Respuesta.falla(400, 'rol_invalido', 'El rol es admin o editor');
    }
    if (await _correoOcupado(p.bd, correo)) {
      return Respuesta.falla(409, 'correo_en_uso', 'Ese correo ya tiene cuenta');
    }
    final u = await p.bd.fila(
      '''insert into apk.usuario (org, correo, nombre, rol)
         values (@o, @c, @n, @r)
         returning id, correo, nombre, rol, creado''',
      {
        'o': p.s.org,
        'c': correo,
        'n': p.texto('nombre', porDefecto: correo.split('@').first),
        'r': rol,
      },
    );
    final token = await nuevaInvitacion(p.bd, u!['id'] as int);
    final enlace = enlaceInvitacion(p.urlPublica, token);
    return Respuesta.creado({
      ...u,
      'enlace': enlace,
      'envio': await _mandaInvitacion(p, correo, '${u['nombre']}', enlace),
    });
  }, acceso: Acceso.admin);

  // Otro enlace para la misma persona (el anterior venció o se perdió). Sirve
  // también para que alguien que olvidó su clave la ponga de nuevo. Con correo
  // de salida se lo manda, igual que la invitación.
  s.ruta('POST', '/v1/usuarios/:id/invitacion', (p) async {
    final id = p.enteroParam('id');
    final u = await p.bd.fila(
      '''select id, correo, nombre, clave_hash is not null as activo
           from apk.usuario where id = @i and org = @o''',
      {'i': id, 'o': p.s.org},
    );
    if (u == null) return Respuesta.falla(404, 'no_encontrado', '');
    final token = await nuevaInvitacion(p.bd, id);
    final enlace = enlaceInvitacion(p.urlPublica, token);
    return Respuesta.ok({
      'enlace': enlace,
      'envio': await _mandaInvitacion(
        p,
        '${u['correo']}',
        '${u['nombre']}',
        enlace,
        claveNueva: u['activo'] == true,
      ),
    });
  }, acceso: Acceso.admin);

  s.ruta('POST', '/v1/usuarios/:id/clave', (p) async {
    final id = p.enteroParam('id');
    // Cada quien cambia la suya, y tiene que saber la de ahora. Un admin no
    // pone claves ajenas: genera otro enlace de invitación.
    if (id != p.s.usuario) {
      return Respuesta.falla(403, 'solo_la_tuya',
          'Solo puedes cambiar tu propia clave. A otra persona, mándale un enlace nuevo.');
    }
    final clave = p.texto('clave');
    final problema = _revisaClave(clave);
    if (problema != null) return problema;
    final u = await p.bd.fila(
      'select clave_hash from apk.usuario where id = @i',
      {'i': id},
    );
    final hash = u?['clave_hash'] as String?;
    if (hash == null || !Seguridad.verificaClave(p.texto('actual'), hash)) {
      return Respuesta.falla(400, 'clave_actual_mala', 'La clave actual no es esa');
    }
    await p.bd.ejecuta(
      'update apk.usuario set clave_hash = @h where id = @i',
      {'h': Seguridad.hashClave(clave), 'i': id},
    );
    return Respuesta.ok({'ok': true});
  });

  s.ruta('DELETE', '/v1/usuarios/:id', (p) async {
    final id = p.enteroParam('id');
    if (id == p.s.usuario) {
      return Respuesta.falla(400, 'no_te_borres', 'No puedes borrar tu propio usuario');
    }
    await p.bd.ejecuta(
      'delete from apk.usuario where id = @i and org = @o',
      {'i': id, 'o': p.s.org},
    );
    return Respuesta.vacio();
  }, acceso: Acceso.admin);
}

/// Crea una organización con un slug libre. Devuelve su id.
Future<int> creaOrg(Bd bd, String nombre) async {
  final org = await bd.fila(
    'insert into apk.org (nombre, slug) values (@n, @s) returning id',
    {'n': nombre, 's': await _slugLibre(bd, nombre)},
  );
  return org!['id'] as int;
}

/// Genera el enlace de un solo uso de [usuario] y lo deja guardado (hasheado).
/// Invalida cualquier enlace anterior de esa persona. El de una invitación
/// vale [vidaInvitacion]; el de «¿Olvidaste tu clave?», [vidaRecuperacion].
Future<String> nuevaInvitacion(Bd bd, int usuario, {Duration vida = vidaInvitacion}) async {
  final token = Seguridad.token();
  await bd.ejecuta(
    '''update apk.usuario set invitacion_hash = @h, invitacion_vence = @v
        where id = @i''',
    {
      'h': Seguridad.hashToken(token),
      'v': DateTime.now().toUtc().add(vida),
      'i': usuario,
    },
  );
  return token;
}

String enlaceInvitacion(String urlPublica, String token) =>
    '$urlPublica/#/activar/$token';

/// Manda por el correo de salida de la organización el enlace que acaba de
/// generar quien administra: la invitación o, a quien ya entraba
/// ([claveNueva]), uno para poner una clave nueva. Devuelve `null` si no hay
/// correo configurado (el enlace se comparte a mano), `{enviado: true, para}`
/// o `{enviado: false, error, detalle}`: que no salga el correo no deshace
/// nada, el enlace sigue sirviendo.
Future<Map<String, Object?>?> _mandaInvitacion(
  Peticion p,
  String para,
  String nombre,
  String enlace, {
  bool claveNueva = false,
}) async {
  final o = await p.bd.fila('select nombre, correo from apk.org where id = @o', {'o': p.s.org});
  final c = ConfigCorreo.deJson(o?['correo']);
  if (c == null || !c.completa) return null;
  final org = '${o?['nombre'] ?? ''}';
  final m = claveNueva
      ? _correoConEnlace(
          nombre: nombre,
          parrafo: 'Quien administra el panel de apk-server de $org te mandó un enlace '
              'para poner una clave nueva.',
          instruccion: 'Ponla aquí',
          boton: 'Poner una clave nueva',
          enlace: enlace,
          vida: vidaInvitacion,
          pie: 'Si no lo esperabas, ignora este correo: tu clave sigue igual.',
        )
      : _correoConEnlace(
          nombre: nombre,
          parrafo: 'Te invitaron al panel de apk-server de $org, donde se publican las apps '
              'Android de la organización y se ve qué versión tiene cada equipo.',
          instruccion: 'Para entrar, pon tu clave aquí',
          boton: 'Poner mi clave',
          enlace: enlace,
          vida: vidaInvitacion,
          pie: 'Si no esperabas este correo, ignóralo.',
        );
  try {
    await enviaCorreo(
      c,
      para: para,
      asunto: claveNueva
          ? 'Clave nueva para el panel de apk-server'
          : 'Te invitaron al panel de apk-server de $org',
      texto: m.texto,
      html: m.html,
    );
    return {'enviado': true, 'para': para};
  } on CorreoError catch (e) {
    log.aviso('correo', 'el enlace a $para no salió: ${e.codigo} ${e.detalle}');
    return {'enviado': false, 'error': e.codigo, 'detalle': e.detalle};
  }
}

/// El enlace de «¿Olvidaste tu clave?»: lo genera y lo manda por el correo de
/// salida [c] de la organización de la persona. Corre sin que nadie lo espere
/// (ver `/v1/auth/recuperar`), así que no lanza: lo que falle va al log, sin
/// el correo de la persona.
Future<void> _mandaRecuperacion(
  Bd bd,
  ConfigCorreo c, {
  required int usuario,
  required String para,
  required String nombre,
  required String org,
  required String urlPublica,
}) async {
  try {
    final token = await nuevaInvitacion(bd, usuario, vida: vidaRecuperacion);
    final m = _correoConEnlace(
      nombre: nombre,
      parrafo: 'Pediste poner una clave nueva para el panel de apk-server de $org.',
      instruccion: 'Ponla aquí',
      boton: 'Poner una clave nueva',
      enlace: enlaceInvitacion(urlPublica, token),
      vida: vidaRecuperacion,
      pie: 'Si no lo pediste tú, ignora este correo: tu clave sigue igual.',
    );
    await enviaCorreo(
      c,
      para: para,
      asunto: 'Clave nueva para el panel de apk-server',
      texto: m.texto,
      html: m.html,
    );
  } on CorreoError catch (e) {
    log.aviso('correo', 'el enlace de clave nueva del usuario $usuario no salió: ${e.codigo} ${e.detalle}');
  } catch (e) {
    log.aviso('correo', 'el enlace de clave nueva del usuario $usuario no salió: $e');
  }
}

/// Texto y HTML de un correo con un enlace para poner la clave (la
/// invitación, el enlace nuevo de quien administra, el de «¿Olvidaste tu
/// clave?»). Lo que cambia entre ellos son las frases; el enlace es el mismo.
({String texto, String html}) _correoConEnlace({
  required String nombre,
  required String parrafo,
  required String instruccion,
  required String boton,
  required String enlace,
  required Duration vida,
  required String pie,
}) {
  final vence = 'el enlace sirve una vez y vence en ${_duracion(vida)}';
  return (
    texto: 'Hola, $nombre:\n\n'
        '$parrafo\n\n'
        '$instruccion ($vence):\n'
        '$enlace\n\n'
        '$pie',
    html: '<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;'
        'max-width:560px;margin:0 auto;padding:16px;color:#16181d">'
        '<p>Hola, ${_html(nombre)}:</p>'
        '<p>${_html(parrafo)}</p>'
        '<p style="margin:24px 0"><a href="${_html(enlace)}" style="background:#2563eb;'
        'color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none">'
        '${_html(boton)}</a></p>'
        '<p style="font-size:13px;color:#5b6270">${_html(vence[0].toUpperCase() + vence.substring(1))}. '
        '${_html(pie)}</p></div>',
  );
}

/// «7 días», «1 hora».
String _duracion(Duration d) {
  if (d.inDays >= 1) return d.inDays == 1 ? '1 día' : '${d.inDays} días';
  return d.inHours == 1 ? '1 hora' : '${d.inHours} horas';
}

String _html(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

Future<Map<String, Object?>?> _porInvitacion(Bd bd, String token) {
  if (token.isEmpty) return Future.value(null);
  return bd.fila(
    'select id, correo, invitacion_vence from apk.usuario where invitacion_hash = @h',
    {'h': Seguridad.hashToken(token)},
  );
}

Future<bool> _correoOcupado(Bd bd, String correo) async =>
    await bd.fila('select id from apk.usuario where correo = @c', {'c': correo}) != null;

Respuesta? _revisaCorreo(String correo) {
  if (!correo.contains('@') || correo.length < 5) {
    return Respuesta.falla(400, 'correo_invalido', 'Revisa el correo');
  }
  return null;
}

Respuesta? _revisaClave(String clave) {
  if (clave.length < 10) {
    return Respuesta.falla(400, 'clave_corta', 'La clave necesita 10 caracteres o más');
  }
  return null;
}

Map<String, Object?> _conToken(Map<String, Object?> u, String secreto) => {
      'token': Seguridad.firmaJwt(
        {'sub': u['id'], 'org': u['org'], 'rol': u['rol']},
        secreto,
      ),
      'usuario': {
        'id': u['id'],
        'correo': u['correo'],
        'nombre': u['nombre'],
        'rol': u['rol'],
        'org': u['org'],
      },
    };

Future<String> _slugLibre(Bd bd, String nombre) async {
  final base = nombre
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final raiz = base.isEmpty ? 'org' : base;
  for (var i = 0; i < 50; i++) {
    final intento = i == 0 ? raiz : '$raiz-$i';
    final ocupado = await bd.fila('select id from apk.org where slug = @s', {'s': intento});
    if (ocupado == null) return intento;
  }
  return '$raiz-${DateTime.now().millisecondsSinceEpoch}';
}
