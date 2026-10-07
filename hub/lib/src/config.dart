import 'dart:io';
import 'dart:math';

/// Configuración del hub, toda por variable de entorno.
///
/// Un servicio que un tercero instala en su propio servidor se configura por
/// entorno: es lo que entienden systemd, Docker y cualquier PaaS. Nada de
/// archivos de configuración con rutas que adivinar.
class Config {
  Config({
    required this.urlBd,
    required this.host,
    required this.puerto,
    required this.secretoJwt,
    required this.registro,
    required this.origenesCors,
    required this.maxApkBytes,
    required this.rutaArchivos,
    required this.rutaManager,
    required this.urlPublica,
    required this.secretoEfimero,
  });

  /// `postgres://usuario:clave@host:5432/base`
  final String urlBd;

  /// Dirección en la que escucha. `0.0.0.0` dentro de Docker; detrás de un
  /// nginx en la misma máquina, `127.0.0.1`, para que nadie llegue de lado.
  final String host;
  final int puerto;

  /// Clave HS256 de los JWT de sesión. Cambiarla cierra la sesión de todos.
  final String secretoJwt;

  /// `cerrado` (por defecto: los usuarios los invita un administrador),
  /// `abierto` (cualquiera crea su organización).
  ///
  /// Cerrado por defecto, al revés que print-server, y no por capricho: un hub
  /// abierto es un sitio donde cualquiera sube un APK y lo reparte con el
  /// nombre de tu dominio. Es exactamente lo que buscan los que distribuyen
  /// malware, y el dominio acaba en las listas negras del navegador.
  final String registro;

  /// Vacío = `*`. Con contenido, solo se refleja el Origin que esté en la lista.
  final List<String> origenesCors;

  /// Tope de un APK. Una app Flutter con todo pesa 50–90 MB; el tope evita que
  /// una subida mal formada llene el disco.
  final int maxApkBytes;

  /// Carpeta donde viven los APK, uno por archivo y con su sha256 por nombre.
  /// La base guarda solo de qué app y versión es cada uno.
  final String rutaArchivos;

  /// Carpeta con el panel web compilado. Si no existe, el hub sirve solo API.
  final String rutaManager;

  /// URL con la que el mundo llega al hub (`https://apk.ejemplo.com`). Con
  /// ella se arman las URL absolutas de descarga. Vacía = se deduce de las
  /// cabeceras del proxy (`X-Forwarded-Proto` y `Host`).
  final String urlPublica;

  /// True cuando el secreto JWT se generó al arrancar (no venía por entorno).
  /// Vale para desarrollo; en producción significa que un reinicio saca a todos.
  final bool secretoEfimero;

  static const _reglas = <String>[
    'APK_DATABASE_URL   (obligatoria)  postgres://usuario:clave@host:5432/base',
    'APK_HOST           (0.0.0.0)',
    'APK_PUERTO         (3130)',
    'APK_SECRETO_JWT    (aleatoria si falta; en producción, fíjala)',
    'APK_REGISTRO       (cerrado|abierto, por defecto cerrado)',
    'APK_CORS           (lista separada por comas; vacío = *)',
    'APK_MAX_APK_MB     (300)',
    'APK_ARCHIVOS       (carpeta de los APK; por defecto ./archivos)',
    'APK_MANAGER        (ruta al panel compilado; por defecto ./manager)',
    'APK_URL_PUBLICA    (https://tu-dominio; vacía = se deduce del proxy)',
    'APK_MIGRACIONES    (carpeta de migraciones; por defecto ./migraciones)',
  ];

  static String get ayuda => _reglas.join('\n  ');

  factory Config.desdeEntorno([Map<String, String>? entorno]) {
    final e = entorno ?? Platform.environment;
    final url = (e['APK_DATABASE_URL'] ?? '').trim();
    if (url.isEmpty) {
      throw ArgumentError('Falta APK_DATABASE_URL.\n  Variables:\n  $ayuda');
    }
    final secreto = (e['APK_SECRETO_JWT'] ?? '').trim();
    final registro = (e['APK_REGISTRO'] ?? 'cerrado').trim().toLowerCase();
    if (!const ['abierto', 'cerrado'].contains(registro)) {
      throw ArgumentError('APK_REGISTRO debe ser cerrado o abierto');
    }
    final urlPublica = (e['APK_URL_PUBLICA'] ?? '').trim();
    return Config(
      urlBd: url,
      host: (e['APK_HOST'] ?? '').trim().isEmpty ? '0.0.0.0' : e['APK_HOST']!.trim(),
      puerto: int.tryParse(e['APK_PUERTO'] ?? '') ?? 3130,
      secretoJwt: secreto.isEmpty ? _secretoAleatorio() : secreto,
      secretoEfimero: secreto.isEmpty,
      registro: registro,
      origenesCors: (e['APK_CORS'] ?? '')
          .split(',')
          .map((o) => o.trim())
          .where((o) => o.isNotEmpty)
          .toList(),
      maxApkBytes: (int.tryParse(e['APK_MAX_APK_MB'] ?? '') ?? 300) * 1024 * 1024,
      rutaArchivos: (e['APK_ARCHIVOS'] ?? 'archivos').trim(),
      rutaManager: (e['APK_MANAGER'] ?? 'manager').trim(),
      urlPublica: urlPublica.replaceAll(RegExp(r'/+$'), ''),
    );
  }

  static String _secretoAleatorio() {
    final r = Random.secure();
    return List.generate(48, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
