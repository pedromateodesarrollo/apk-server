// Fuente única de la documentación del API.
//
// De aquí sale la página de documentación del sitio Y el archivo `docs/api.md`
// del repositorio (`npm run docs`). Con dos fuentes, una de las dos miente a
// los tres meses.

export const intro = {
  titulo: 'API de apk-server',
  texto:
    'Todo lo que hace el panel se puede hacer por API. La base es la dirección de tu hub ' +
    'y las respuestas son JSON. Lo que usan los equipos (consultar, bajar, instalar, el ' +
    'WebSocket) va sin credencial; lo que cambia algo (publicar, administrar) la pide.',
}

export const autenticacion = [
  {
    titulo: 'Llave de API',
    texto:
      'Para los scripts de publicación y el CI. Va en `authorization: Bearer cak_...` ' +
      '(también se acepta `x-api-key`). No caduca; se revoca desde el panel o por API. ' +
      'Se puede acotar a unas apps.',
    ejemplo: 'curl -H "authorization: Bearer cak_ab12cd34_..." https://TU-HUB/v1/apps',
  },
  {
    titulo: 'Permisos de una llave',
    texto:
      '`publicar` sube versiones y cambia sus notas, si son obligatorias o si están retiradas · ' +
      '`leer` lista apps, versiones y equipos · `admin` abre todo el API, incluidos usuarios y llaves.',
  },
  {
    titulo: 'Sesión de persona',
    texto:
      'La del panel. `POST /v1/auth/login` devuelve un JWT que dura siete días y viaja en la ' +
      'misma cabecera. A las personas se las invita: el administrador genera un enlace y la ' +
      'persona pone su propia clave.',
  },
  {
    titulo: 'Sin credencial',
    texto:
      'La ficha de una app, la consulta de versión, la descarga del APK, `/install/<app>` y el ' +
      'WebSocket. Un equipo nuevo no tiene ninguna credencial, y lo que se reparte —un APK— es ' +
      'público en cuanto sale. Lo que se protege es publicar.',
  },
]

export const clientes = [
  {
    titulo: 'Flutter: actualizarse solo',
    texto:
      'El paquete `apk_server_flutter` (en `cliente/flutter`) consulta, se entera por WebSocket, ' +
      'baja el APK con reanudación e instala. En Android 12+, si la persona ya permitió instalar ' +
      'desde la app, instala sin diálogo (la app se cierra y queda en la versión nueva). Cada ' +
      'consulta lleva la clave de la instalación, el ANDROID_ID, el modelo y lo que la app ponga ' +
      'en `contexto`: es lo que se ve en la pestaña Equipos.',
    ejemplo: `# pubspec.yaml
dependencies:
  apk_server_flutter:
    git:
      url: https://github.com/pedromateodesarrollo/apk-server
      path: cliente/flutter

// main.dart
final update = UpdateService(
  servidor: 'https://TU-HUB',
  app: 'inventario',
  contexto: () => {'empresa': sesion.empresa, 'usuario': sesion.nombre},
);
update.iniciar();   // pregunta ya, cada hora y al llegar un aviso

Scaffold(bottomNavigationBar: UpdateBanner(update), ...)`,
  },
  {
    titulo: 'Dart puro: solo el protocolo',
    texto:
      'El paquete `apk_server` (en `cliente/dart`) sabe preguntar y escuchar el WebSocket, sin ' +
      'Flutter ni nada de Android. Es la base del de Flutter y sirve para otra plataforma.',
    ejemplo: `final a = ApkActualizador(
  servidor: 'https://TU-HUB',
  app: 'inventario',
  buildActual: () async => 84,
  instalacion: claveGuardada,
);
a.disponible.listen((v) => print('hay \${v.version} en \${v.url}'));
a.iniciar();
a.conectarAvisos();`,
  },
]

export const grupos = ['Equipos', 'Publicar', 'Apps', 'Equipos instalados', 'Usuarios y llaves']

const version = `{
  "build": 84,
  "version": "1.55.0",
  "requerido": true,
  "notas": "Arreglos de la toma",
  "sha256": "5c91542e…",
  "bytes": 54662850,
  "paquete": "com.ejemplo.inventario",
  "min_sdk": 24,
  "publicado": "2026-10-07T20:54:47Z",
  "ruta": "/archivos/5c91542e….apk",
  "url": "https://TU-HUB/archivos/5c91542e….apk"
}`

export const puntos = [
  // ------------------------------------------------------------- equipos
  {
    grupo: 'Equipos',
    metodo: 'POST',
    ruta: '/v1/apps/:app/consulta',
    acceso: 'público',
    resumen:
      'Lo que pregunta una app instalada: «tengo la build N, ¿hay algo?». De paso deja anotada ' +
      'la instalación. `requerido` es verdadero si alguna versión por encima de la build actual ' +
      'es obligatoria, aunque la última no lo sea.',
    cuerpo: [
      ['build', 'entero', 'sí', 'El `versionCode` instalado.'],
      ['instalacion', 'texto', 'no', 'Clave de la instalación (8–100 caracteres, la genera la app). Sin ella no se anota nada.'],
      ['huella', 'texto', 'no', 'El ANDROID_ID. Si la app se reinstala, la fila del equipo se reusa.'],
      ['version', 'texto', 'no', 'El `versionName` instalado.'],
      ['modelo', 'texto', 'no', 'Modelo del equipo.'],
      ['fabricante', 'texto', 'no', ''],
      ['android', 'entero', 'no', 'Nivel de SDK de Android.'],
      ['contexto', 'objeto', 'no', 'Lo que la app quiera contar (empresa, usuario…). Hasta 4 KB.'],
    ],
    respuesta: `{
  "build_actual": 80,
  "actualizar": true,
  "requerido": true,
  "version": ${version.replace(/\n/g, '\n  ')}
}`,
  },
  {
    grupo: 'Equipos',
    metodo: 'GET',
    ruta: '/v1/apps/:app/ultima',
    acceso: 'público',
    resumen: 'La misma respuesta que la consulta, sin anotar nada. Para mirar a mano o desde un script.',
    consulta: [['build', 'entero', '', 'La build contra la que comparar (0 si se omite).']],
    ejemplo: 'curl "https://TU-HUB/v1/apps/inventario/ultima?build=80"',
  },
  {
    grupo: 'Equipos',
    metodo: 'GET',
    ruta: '/v1/ws?app=:app&instalacion=:clave',
    acceso: 'público',
    resumen:
      'WebSocket de la app instalada. Al publicar (o retirar, o marcar obligatoria) llega ' +
      '`{"tipo":"version","app","build","requerido"}` y la app consulta. Mientras está abierto, ' +
      'el equipo figura como conectado; al cerrarse queda la hora en que se vio por última vez. ' +
      'El hub manda ping cada 30 s; un cliente que no pueda contestar pings de protocolo puede ' +
      'mandar `{"tipo":"ping"}` y recibe `{"tipo":"pong"}`.',
  },
  {
    grupo: 'Equipos',
    metodo: 'GET',
    ruta: '/archivos/:sha256.apk',
    acceso: 'público',
    resumen:
      'El APK. La URL lleva el sha256 del contenido: no cambia nunca y se cachea para siempre. ' +
      'Admite `Range` (un teléfono que pierde la señal retoma donde iba). Una versión retirada ' +
      'responde 410.',
  },
  {
    grupo: 'Equipos',
    metodo: 'GET',
    ruta: '/install/:app',
    acceso: 'público',
    resumen:
      'Redirige al APK de la última versión. Es la URL estable para instalar en un equipo nuevo ' +
      '(la de la página `/i/:app` y su código QR).',
  },
  {
    grupo: 'Equipos',
    metodo: 'GET',
    ruta: '/v1/apps/:app',
    acceso: 'público',
    resumen: 'Ficha pública de la app: nombre, descripción, paquete, icono y la última versión.',
  },

  // ------------------------------------------------------------- publicar
  {
    grupo: 'Publicar',
    metodo: 'POST',
    ruta: '/v1/apps/:app/versiones',
    acceso: 'llave con `publicar` o persona',
    resumen:
      'Sube un APK. El cuerpo es el archivo tal cual. El hub lee del APK el `applicationId`, el ' +
      '`versionCode`, el `versionName`, los SDK y el certificado de firma, y lo rechaza si el ' +
      'paquete o la firma no son los de la app (los fija la primera versión), o si esa build ' +
      'ya existe con otro contenido. Repetir la misma publicación no es error: devuelve la ' +
      'versión con `ya_estaba`. Al terminar avisa por WebSocket a los equipos conectados.',
    consulta: [
      ['notas', 'texto', '', 'Lo que ve quien actualiza.'],
      ['requerido', '1', '', 'Obligatoria: nadie se queda por debajo de esta build.'],
      ['build', 'entero', '', 'Opcional: si se da y no es la del APK, se rechaza.'],
      ['version', 'texto', '', 'Opcional: igual, contra el `versionName`.'],
    ],
    ejemplo: `curl -X POST "https://TU-HUB/v1/apps/inventario/versiones?build=84&notas=Arreglos" \\
  -H "authorization: Bearer cak_..." \\
  --data-binary @build/app/outputs/flutter-apk/app-release.apk`,
    respuesta: `{ …la versión…, "avisadas": 12 }`,
  },
  {
    grupo: 'Publicar',
    metodo: 'PATCH',
    ruta: '/v1/apps/:app/versiones/:build',
    acceso: 'llave con `publicar` o persona',
    resumen:
      'Cambia `notas`, `requerido` o `retirada` (true deja de ofrecerla y de servirla; false la ' +
      'devuelve). Los equipos conectados reciben el aviso y vuelven a consultar.',
    cuerpo: [
      ['notas', 'texto', 'no', ''],
      ['requerido', 'booleano', 'no', ''],
      ['retirada', 'booleano', 'no', ''],
    ],
  },
  {
    grupo: 'Publicar',
    metodo: 'DELETE',
    ruta: '/v1/apps/:app/versiones/:build',
    acceso: 'admin',
    resumen: 'Borra una versión ya retirada y su APK del disco (si ninguna otra lo usa). No tiene vuelta.',
  },
  {
    grupo: 'Publicar',
    metodo: 'GET',
    ruta: '/v1/apps/:app/versiones',
    acceso: 'llave con `leer` o persona',
    resumen: 'Todas las versiones, con descargas y cuántos equipos tienen cada una (últimos 30 días).',
  },

  // ----------------------------------------------------------------- apps
  {
    grupo: 'Apps',
    metodo: 'GET',
    ruta: '/v1/apps',
    acceso: 'llave con `leer` o persona',
    resumen: 'Las apps de la organización, con su última versión, espacio y equipos (vistos, al día y conectados).',
  },
  {
    grupo: 'Apps',
    metodo: 'POST',
    ruta: '/v1/apps',
    acceso: 'admin',
    resumen:
      'Crea una app. El `slug` es global en el hub (va en las URL públicas) y no se cambia. Una ' +
      'app por `applicationId`: dos sabores con distinto paquete son dos apps.',
    cuerpo: [
      ['slug', 'texto', 'sí', 'Minúsculas, números y guiones; hasta 63.'],
      ['nombre', 'texto', 'sí', ''],
      ['descripcion', 'texto', 'no', ''],
    ],
  },
  {
    grupo: 'Apps',
    metodo: 'PATCH',
    ruta: '/v1/apps/:app',
    acceso: 'admin',
    resumen: 'Cambia `nombre` o `descripcion`.',
  },
  {
    grupo: 'Apps',
    metodo: 'PUT',
    ruta: '/v1/apps/:app/icono',
    acceso: 'admin',
    resumen: 'Sube el icono (PNG, JPEG o WebP, hasta 512 KB; el tipo se mira en los bytes). `DELETE` lo quita.',
  },
  {
    grupo: 'Apps',
    metodo: 'DELETE',
    ruta: '/v1/apps/:app',
    acceso: 'admin',
    resumen: 'Borra una app sin versiones.',
  },

  // ------------------------------------------------------ equipos instalados
  {
    grupo: 'Equipos instalados',
    metodo: 'GET',
    ruta: '/v1/apps/:app/instalaciones',
    acceso: 'llave con `leer` o persona',
    resumen:
      'Los equipos que consultaron en los últimos `dias` (90 por defecto), conectados primero, ' +
      'y el reparto por build.',
    consulta: [['dias', 'entero', '', '1 a 3650.']],
  },
  {
    grupo: 'Equipos instalados',
    metodo: 'PATCH',
    ruta: '/v1/apps/:app/instalaciones/:id',
    acceso: 'persona',
    resumen: 'Le pone `nombre` a un equipo («Terminal 3 — recepción»).',
  },
  {
    grupo: 'Equipos instalados',
    metodo: 'DELETE',
    ruta: '/v1/apps/:app/instalaciones/:id',
    acceso: 'admin',
    resumen: 'Olvida un equipo (si vuelve a consultar, reaparece).',
  },

  // ------------------------------------------------------ usuarios y llaves
  {
    grupo: 'Usuarios y llaves',
    metodo: 'POST',
    ruta: '/v1/auth/login',
    acceso: 'público',
    resumen: 'Entra con `correo` y `clave`. Devuelve `{token, usuario}`.',
  },
  {
    grupo: 'Usuarios y llaves',
    metodo: 'POST',
    ruta: '/v1/usuarios',
    acceso: 'admin',
    resumen:
      'Invita a una persona (`correo`, `nombre`, `rol`: `admin` o `editor`). Devuelve `enlace`, ' +
      'de un solo uso y por 7 días, para que ponga su clave. El hub no manda correos.',
  },
  {
    grupo: 'Usuarios y llaves',
    metodo: 'POST',
    ruta: '/v1/usuarios/:id/invitacion',
    acceso: 'admin',
    resumen: 'Otro enlace para la misma persona (el anterior deja de servir). También sirve para que ponga una clave nueva.',
  },
  {
    grupo: 'Usuarios y llaves',
    metodo: 'POST',
    ruta: '/v1/auth/activar',
    acceso: 'público',
    resumen: 'Con el `token` del enlace y la `clave` nueva. Devuelve la sesión.',
  },
  {
    grupo: 'Usuarios y llaves',
    metodo: 'POST',
    ruta: '/v1/llaves',
    acceso: 'admin',
    resumen:
      'Crea una llave (`nombre`, `permisos`, `apps`). La llave completa se ve solo en esta ' +
      'respuesta; se guarda hasheada.',
  },
  {
    grupo: 'Usuarios y llaves',
    metodo: 'DELETE',
    ruta: '/v1/llaves/:id',
    acceso: 'admin',
    resumen: 'Revoca una llave. La fila se queda: explica quién publicó qué.',
  },
]

export const errores = [
  [400, '`apk_invalido`', 'Lo subido no es un APK que se pueda leer (el mensaje dice por qué).'],
  [400, '`build_no_coincide`', 'La build dicha en la consulta no es la del APK.'],
  [401, '`no_autenticado`', 'Falta la credencial o no es válida.'],
  [403, '`sin_permiso`', 'La llave no tiene el permiso que hace falta.'],
  [404, '`app_no_existe`', 'No hay una app con ese nombre (o no es de tu organización).'],
  [409, '`paquete_distinto`', 'El APK es de otro `applicationId` que la app.'],
  [409, '`firma_distinta`', 'El APK está firmado con otra llave: los equipos no podrían actualizar.'],
  [409, '`build_repetida`', 'Esa build ya está publicada con otro APK.'],
  [410, '`retirada`', 'Se pidió el APK de una versión retirada.'],
  [413, '`apk_grande`', 'Pasa del tope del hub (`APK_MAX_APK_MB`).'],
  [429, '`demasiadas_consultas`', 'Más de 240 consultas por minuto desde la misma IP.'],
]
