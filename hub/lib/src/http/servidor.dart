import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../config.dart';
import '../db.dart';
import '../log.dart';
import '../seguridad.dart';

/// Quién hace la petición, ya resuelto.
///
/// Hay dos clases de llamante y conviene no confundirlos: una persona con
/// sesión en el panel, y un script con llave de API. Los dos pertenecen a una
/// organización, y **de esa organización sale el filtro de toda consulta**:
/// ninguna ruta acepta un `org` que venga del cuerpo.
class Sesion {
  const Sesion({
    required this.org,
    this.usuario,
    this.llave,
    this.rol = 'api',
    this.permisos = const {},
    this.apps = const {},
  });

  final int org;
  final int? usuario;
  final int? llave;
  final String rol;
  final Set<String> permisos;

  /// Apps a las que está acotada una llave. Vacío = todas las de la
  /// organización. Las personas del panel no se acotan.
  final Set<String> apps;

  bool get esUsuario => usuario != null;

  /// Una llave con permiso `admin` vale lo mismo que una persona administradora.
  bool get esAdmin => (esUsuario && rol == 'admin') || permisos.contains('admin');

  bool puede(String permiso) =>
      esUsuario || permisos.contains('admin') || permisos.contains(permiso);

  /// Si la credencial alcanza la app [slug] (la org se mira aparte).
  bool alcanza(String slug) => esUsuario || apps.isEmpty || apps.contains(slug);

  /// Quién hizo algo, para dejarlo escrito (`usuario:3`, `llave:7`).
  String get firma => esUsuario ? 'usuario:$usuario' : 'llave:$llave';
}

/// Nivel de acceso que exige una ruta.
enum Acceso {
  /// Sin credencial: consulta de versión, descargas, login, salud.
  publico,

  /// Sesión de persona (JWT del panel) o llave con permiso `admin`.
  usuario,

  /// Persona con rol admin, o llave con permiso `admin`.
  admin,

  /// Persona o llave de API. Es lo que usa publicar.
  cualquiera,
}

class Peticion {
  Peticion({
    required this.crudo,
    required this.params,
    required this.cuerpo,
    required this.sesion,
    required this.config,
    required this.bd,
  });

  final HttpRequest crudo;
  final Map<String, String> params;
  final Map<String, Object?> cuerpo;
  final Sesion? sesion;
  final Config config;
  final Bd bd;

  Sesion get s => sesion!;
  Map<String, String> get consulta => crudo.uri.queryParameters;

  String texto(String clave, {String porDefecto = ''}) {
    final v = cuerpo[clave];
    return v == null ? porDefecto : v.toString().trim();
  }

  int? entero(String clave) {
    final v = cuerpo[clave];
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '');
  }

  int enteroParam(String clave) => int.tryParse(params[clave] ?? '') ?? 0;

  /// IP de quien llama. Detrás de nginx, la que él dice en `X-Real-IP`.
  String get ip =>
      crudo.headers.value('x-real-ip')?.trim() ??
      crudo.headers.value('x-forwarded-for')?.split(',').first.trim() ??
      crudo.connectionInfo?.remoteAddress.address ??
      '';

  /// URL con la que el mundo llega al hub, sin barra final. Si no se fijó en
  /// la configuración, se arma con lo que dice el proxy.
  String get urlPublica {
    if (config.urlPublica.isNotEmpty) return config.urlPublica;
    final proto = crudo.headers.value('x-forwarded-proto')?.split(',').first.trim() ??
        (crudo.requestedUri.scheme);
    final host = crudo.headers.value('x-forwarded-host')?.split(',').first.trim() ??
        crudo.headers.host ??
        'localhost';
    final puerto = crudo.headers.value('x-forwarded-host') == null &&
            crudo.headers.port != 80 &&
            crudo.headers.port != 443
        ? ':${crudo.headers.port}'
        : '';
    return '$proto://$host$puerto';
  }
}

class Respuesta {
  Respuesta(this.estado, this.cuerpo, {this.cabeceras = const {}});

  final int estado;
  final Object? cuerpo;
  final Map<String, String> cabeceras;

  static Respuesta ok(Object? cuerpo) => Respuesta(200, cuerpo);

  /// El manejador ya escribió y cerró la respuesta por su cuenta (una descarga
  /// que va en flujo, no en JSON). Sin esta señal, el ciclo intentaría cerrar
  /// dos veces la misma respuesta.
  static Respuesta yaEscrita() => Respuesta(0, null);
  static Respuesta creado(Object? cuerpo) => Respuesta(201, cuerpo);
  static Respuesta vacio() => Respuesta(204, null);

  /// El cuerpo de error es siempre `{error, mensaje}`: `error` es un código
  /// estable para que el cliente ramifique, `mensaje` es para la gente.
  static Respuesta falla(int estado, String error, [String mensaje = '']) =>
      Respuesta(estado, {'error': error, 'mensaje': mensaje});
}

typedef Manejador = FutureOr<Respuesta> Function(Peticion p);

class _Ruta {
  _Ruta(this.metodo, String patron, this.manejador, this.acceso, this.crudo)
    : partes = patron.split('/').where((s) => s.isNotEmpty).toList();

  final String metodo;
  final List<String> partes;
  final Manejador manejador;
  final Acceso acceso;

  /// El cuerpo no es JSON y lo lee el manejador (la subida de un APK).
  final bool crudo;

  Map<String, String>? casa(String metodoPet, List<String> ruta) {
    if (metodoPet != metodo || ruta.length != partes.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < partes.length; i++) {
      final p = partes[i];
      if (p.startsWith(':')) {
        params[p.substring(1)] = ruta[i];
      } else if (p != ruta[i]) {
        return null;
      }
    }
    return params;
  }
}

/// Router y ciclo de petición. Sin framework: dart:io da el servidor HTTP y
/// esto son ciento y pico de líneas que cualquiera lee de una sentada.
class Servidor {
  Servidor(this.config, this.bd);

  final Config config;
  final Bd bd;
  final List<_Ruta> _rutas = [];

  /// Manejadores de upgrade (WebSocket). Se prueban antes del routing normal.
  final List<Future<bool> Function(HttpRequest)> upgrades = [];

  void ruta(
    String metodo,
    String patron,
    Manejador manejador, {
    Acceso acceso = Acceso.usuario,
    bool crudo = false,
  }) => _rutas.add(_Ruta(metodo, patron, manejador, acceso, crudo));

  Future<HttpServer> escuchar() async {
    final servidor = await HttpServer.bind(config.host, config.puerto, shared: true);
    servidor.listen(
      (pet) => _atiende(pet).catchError((Object e, StackTrace t) {
        log.error('http', 'fallo no atrapado: $e');
      }),
    );
    return servidor;
  }

  Future<void> _atiende(HttpRequest pet) async {
    _cors(pet);
    if (pet.method == 'OPTIONS') {
      pet.response.statusCode = HttpStatus.noContent;
      await pet.response.close();
      return;
    }

    for (final upgrade in upgrades) {
      if (await upgrade(pet)) return;
    }

    final ruta = pet.uri.pathSegments.where((s) => s.isNotEmpty).toList();

    // HEAD se atiende con el manejador de GET y sin cuerpo. Es lo que manda un
    // `curl -I` y lo que usa un navegador para comprobar una descarga; sin
    // esto, la misma URL que funciona da 404 al mirarla.
    final metodo = pet.method == 'HEAD' ? 'GET' : pet.method;

    for (final r in _rutas) {
      final params = r.casa(metodo, ruta);
      if (params == null) continue;
      await _corre(pet, r, params);
      return;
    }

    // Nada casó. Si la ruta empieza por `v1` es un 404 de API; si no, puede
    // ser el panel (una SPA con rutas propias del navegador).
    if (ruta.isNotEmpty && ruta.first == 'v1') {
      await _escribe(pet, Respuesta.falla(404, 'no_encontrado', 'Ruta desconocida'));
    } else {
      await _sirveManager(pet, ruta);
    }
  }

  Future<void> _corre(HttpRequest pet, _Ruta r, Map<String, String> params) async {
    Map<String, Object?> cuerpo = const {};
    if (!r.crudo && pet.method != 'GET' && pet.method != 'DELETE') {
      try {
        cuerpo = await _leeJson(pet);
      } on FormatException catch (e) {
        await _escribe(pet, Respuesta.falla(400, 'json_invalido', e.message));
        return;
      }
    }

    Sesion? sesion;
    if (r.acceso != Acceso.publico) {
      sesion = await _autentica(pet);
      if (sesion == null) {
        await _escribe(
          pet,
          Respuesta.falla(401, 'no_autenticado', 'Falta credencial o no es válida'),
        );
        return;
      }
      if (r.acceso == Acceso.usuario && !sesion.esUsuario && !sesion.esAdmin) {
        await _escribe(
          pet,
          Respuesta.falla(403, 'requiere_sesion',
              'Esta ruta necesita sesión de persona o una llave con permiso «admin»'),
        );
        return;
      }
      if (r.acceso == Acceso.admin && !sesion.esAdmin) {
        await _escribe(
          pet,
          Respuesta.falla(403, 'requiere_admin', 'Hace falta rol de administrador'),
        );
        return;
      }
    }

    try {
      final resp = await r.manejador(
        Peticion(
          crudo: pet,
          params: params,
          cuerpo: cuerpo,
          sesion: sesion,
          config: config,
          bd: bd,
        ),
      );
      await _escribe(pet, resp);
    } catch (e, t) {
      // El texto de la excepción trae nombres de tabla y restricciones. Va al
      // log; al cliente solo una referencia con la que buscarlo.
      final ref = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      log.error('http', 'err:$ref ${pet.method} ${pet.uri.path} → $e\n$t');
      await _escribe(
        pet,
        Respuesta.falla(500, 'error_interno', 'Error interno. Referencia: $ref'),
      );
    }
  }

  Future<Map<String, Object?>> _leeJson(HttpRequest pet) async {
    final bytes = <int>[];
    await for (final trozo in pet) {
      bytes.addAll(trozo);
      // Por JSON solo viajan formularios; el APK va por una ruta `crudo`.
      if (bytes.length > 1024 * 1024) {
        throw const FormatException('Cuerpo demasiado grande');
      }
    }
    if (bytes.isEmpty) return const {};
    final decodificado = jsonDecode(utf8.decode(bytes));
    if (decodificado is! Map) {
      throw const FormatException('El cuerpo debe ser un objeto JSON');
    }
    return decodificado.cast<String, Object?>();
  }

  /// Resuelve la credencial. Dos formatos sobre la misma cabecera:
  /// `Bearer <jwt>` para personas y `Bearer cak_<prefijo>_<secreto>` (o
  /// `X-Api-Key`) para scripts. Se distinguen por el prefijo, no por
  /// cabeceras distintas: así un cliente cualquiera usa una sola forma.
  Future<Sesion?> _autentica(HttpRequest pet) async {
    var credencial = pet.headers.value('x-api-key')?.trim() ?? '';
    if (credencial.isEmpty) {
      final auth = pet.headers.value('authorization')?.trim() ?? '';
      credencial = auth.toLowerCase().startsWith('bearer ')
          ? auth.substring(7).trim()
          : auth;
    }
    if (credencial.isEmpty) return null;

    if (credencial.startsWith('cak_')) return _sesionDeLlave(credencial);

    final carga = Seguridad.verificaJwt(credencial, config.secretoJwt);
    if (carga == null) return null;
    final usuario = carga['sub'];
    final org = carga['org'];
    if (usuario is! int || org is! int) return null;
    return Sesion(
      org: org,
      usuario: usuario,
      rol: carga['rol']?.toString() ?? 'editor',
    );
  }

  Future<Sesion?> _sesionDeLlave(String credencial) async {
    final partes = Seguridad.partesCredencial(credencial);
    if (partes == null || partes[0] != 'cak') return null;
    final fila = await bd.fila(
      '''select id, org, clave_hash, permisos, apps
           from apk.llave
          where prefijo = @p and revocada is null''',
      {'p': partes[1]},
    );
    if (fila == null) return null;
    if (!Seguridad.tokenCoincide(partes[2], fila['clave_hash'] as String)) {
      return null;
    }
    // `ultimo_uso` sirve para saber qué llave se puede revocar sin romper nada.
    // No se espera: que una publicación no pague la latencia de una estadística.
    unawaited(
      bd.ejecuta('update apk.llave set ultimo_uso = now() where id = @i', {
        'i': fila['id'],
      }),
    );
    Set<String> lista(Object? v) =>
        ((v as List?) ?? const []).map((p) => p.toString()).toSet();
    return Sesion(
      org: fila['org'] as int,
      llave: fila['id'] as int,
      rol: 'api',
      permisos: lista(fila['permisos']),
      apps: lista(fila['apps']),
    );
  }

  void _cors(HttpRequest pet) {
    final origen = pet.headers.value('origin');
    final permitidos = config.origenesCors;
    if (permitidos.isEmpty) {
      pet.response.headers.set('access-control-allow-origin', '*');
    } else if (origen != null && permitidos.contains(origen)) {
      pet.response.headers
        ..set('access-control-allow-origin', origen)
        ..add('vary', 'Origin');
    }
    pet.response.headers
      ..set('access-control-allow-methods', 'GET,POST,PATCH,DELETE,OPTIONS')
      ..set('access-control-allow-headers', 'authorization,content-type,x-api-key')
      ..set('access-control-max-age', '86400');
  }

  Future<void> _escribe(HttpRequest pet, Respuesta r) async {
    if (r.estado == 0) return; // ya la escribió el manejador
    final res = pet.response;
    res.statusCode = r.estado;
    r.cabeceras.forEach(res.headers.set);
    if (r.cuerpo == null || pet.method == 'HEAD') {
      await res.close();
      return;
    }
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(r.cuerpo, toEncodable: _aJson));
    await res.close();
  }

  /// Sirve el panel compilado. Cualquier ruta que no sea un archivo existente
  /// devuelve `index.html`, que es lo que necesita una SPA para que abrir
  /// `/i/<app>` (la página de instalación) no dé 404.
  Future<void> _sirveManager(HttpRequest pet, List<String> ruta) async {
    final base = Directory(config.rutaManager);
    if (!base.existsSync()) {
      await _escribe(
        pet,
        Respuesta.falla(404, 'sin_manager', 'Este hub sirve solo la API'),
      );
      return;
    }
    // Sin `..`: un segmento con salto de carpeta serviría cualquier archivo
    // del servidor.
    final limpio = ruta.where((s) => s != '..' && s != '.').toList();
    var archivo = File([base.path, ...limpio].join(Platform.pathSeparator));
    final existe = limpio.isNotEmpty && archivo.existsSync();

    if (!existe) {
      // Un archivo con extensión que no está es un 404, no la portada.
      //
      // Devolver `index.html` en su lugar rompe de la peor manera: el
      // navegador que tenía cacheada una versión anterior pide su `.js`, le
      // llega HTML, se niega a ejecutarlo y la página queda muerta sin un solo
      // error que explique nada. El respaldo a `index.html` es para las rutas
      // del navegador (`/i/<app>`), que no llevan extensión.
      if (limpio.isNotEmpty && limpio.last.contains('.')) {
        await _escribe(pet, Respuesta.falla(404, 'no_encontrado', ''));
        return;
      }
      archivo = File('${base.path}${Platform.pathSeparator}index.html');
      if (!archivo.existsSync()) {
        await _escribe(pet, Respuesta.falla(404, 'no_encontrado', ''));
        return;
      }
    }

    // Los archivos de `assets/` llevan el hash del contenido en el nombre: si
    // cambian, cambia la URL. Se pueden cachear para siempre. `index.html` es
    // lo contrario: es el que dice qué hash toca hoy, y cachearlo es lo que
    // deja a un navegador pidiendo archivos que ya no existen.
    final enAssets = limpio.isNotEmpty && limpio.first == 'assets';
    pet.response.headers
      ..contentType = _tipo(archivo.path)
      ..set(
        'cache-control',
        enAssets && existe ? 'public, max-age=31536000, immutable' : 'no-cache',
      );
    await pet.response.addStream(archivo.openRead());
    await pet.response.close();
  }

  /// Postgres devuelve `DateTime` y `Uint8List` donde JSON quiere texto. Se
  /// traduce aquí, en la salida, y no en cada consulta: una ruta nueva no
  /// tiene que acordarse de convertir sus fechas.
  static Object? _aJson(Object? v) {
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is Uint8List) return base64.encode(v);
    return v.toString();
  }

  ContentType _tipo(String ruta) {
    final p = ruta.toLowerCase();
    if (p.endsWith('.html')) return ContentType.html;
    if (p.endsWith('.js')) return ContentType('application', 'javascript', charset: 'utf-8');
    if (p.endsWith('.css')) return ContentType('text', 'css', charset: 'utf-8');
    if (p.endsWith('.json')) return ContentType.json;
    if (p.endsWith('.svg')) return ContentType('image', 'svg+xml');
    if (p.endsWith('.png')) return ContentType('image', 'png');
    if (p.endsWith('.ico')) return ContentType('image', 'x-icon');
    if (p.endsWith('.webp')) return ContentType('image', 'webp');
    if (p.endsWith('.woff2')) return ContentType('font', 'woff2');
    if (p.endsWith('.txt')) return ContentType('text', 'plain', charset: 'utf-8');
    return ContentType.binary;
  }
}
