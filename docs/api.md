# API de apk-server

Todo lo que hace el panel se puede hacer por API. La base es la dirección de tu hub y las respuestas son JSON. Lo que usan los equipos (consultar, bajar, instalar, el WebSocket) va sin credencial; lo que cambia algo (publicar, administrar) la pide.

> Generado desde `manager/src/docs.js` con `npm run docs`. No lo edites a mano.

## Autenticación

### Llave de API

Para los scripts de publicación y el CI. Va en `authorization: Bearer cak_...` (también se acepta `x-api-key`). No caduca; se revoca desde el panel o por API. Se puede acotar a unas apps.

```bash
curl -H "authorization: Bearer cak_ab12cd34_..." https://TU-HUB/v1/apps
```

### Permisos de una llave

`publicar` sube versiones y cambia sus notas, si son obligatorias o si están retiradas · `leer` lista apps, versiones y equipos · `admin` abre todo el API, incluidos usuarios y llaves.

### Sesión de persona

La del panel. `POST /v1/auth/login` devuelve un JWT que dura siete días y viaja en la misma cabecera. A las personas se las invita: el administrador genera un enlace y la persona pone su propia clave. Si la organización tiene correo de salida, el enlace le llega por correo, y quien olvidó su clave pide otro desde la entrada («¿Olvidaste tu clave?»).

### Sin credencial

La ficha de una app, la consulta de versión, la descarga del APK, `/install/<app>` y el WebSocket. Un equipo nuevo no tiene ninguna credencial, y lo que se reparte —un APK— es público en cuanto sale. Lo que se protege es publicar.

## Clientes

### Android: actualizarse solo

La biblioteca de `cliente/android` sirve para cualquier app Android, nativa o Flutter. Consulta, se entera por WebSocket y baja el APK en segundo plano, con la pantalla apagada y retomando lo cortado. Al terminar comprueba tamaño y sha256 y saca una notificación «Actualización X lista — toca para instalarla», que se queda hasta que se instala. Si la descarga se corta o pasa 45 s sin recibir nada, no se abandona: vuelve a preguntar y sigue desde donde quedó (`Range`) a los 5 s, 15 s, 30 s, 1 min, 2 min y después cada 5 min, o en cuanto vuelve la red. En Android 12+, si la persona ya permitió instalar desde la app, instala sin diálogo (la app se cierra y queda en la versión nueva); si no, al tocar la notificación sale la pantalla del sistema. Cada consulta lleva la clave de la instalación, el ANDROID_ID, el modelo y lo que la app ponga en `contexto`: es lo que se ve en la pestaña Equipos. El hub y la app van una vez en el `build.gradle.kts` de la app (por sabor): de ahí los lee la biblioteca y, del APK, el comando de publicar. Ver `cliente/android/README.md`.

```kotlin
// android/app/build.gradle.kts
manifestPlaceholders["apkServerHub"] = "https://TU-HUB"
manifestPlaceholders["apkServerApp"] = "inventario"

// una app nativa
ApkServer.de(this).iniciar()   // pregunta ya, cada hora y al llegar un aviso
```

### Flutter

El paquete `apk_server_flutter` (en `cliente/flutter`) es esa biblioteca más `UpdateService` y los widgets (`UpdateTarjeta`, `UpdateBanner`, `UpdateAccion`).

```dart
# pubspec.yaml
dependencies:
  apk_server_flutter:
    git:
      url: https://github.com/pedromateodesarrollo/apk-server
      path: cliente/flutter
      ref: v0.2.1

// main.dart
final update = UpdateService(
  contexto: () => {'empresa': sesion.empresa, 'usuario': sesion.nombre},
);
update.iniciar();   // pregunta ya, cada hora y al llegar un aviso

Scaffold(bottomNavigationBar: UpdateBanner(update), ...)
```

### Publicar desde el proyecto

`dart run apk_server_flutter:publicar --apk <archivo>` (o `dart run apk_server:publicar` desde `cliente/dart`) lee del APK a qué hub y a qué app va, comprueba `--build` y `--version` si se dan, y lo sube con la llave de `APK_SERVER_LLAVE`. Con varios `--apk` (un sabor cada uno) revisa todos antes de subir el primero. `--simular` dice qué haría.

```bash
APK_SERVER_LLAVE=cak_... dart run apk_server_flutter:publicar \
  --apk build/app/outputs/flutter-apk/app-release.apk --build 84 --notas "Arreglos"
```

### Dart puro: solo el protocolo

El paquete `apk_server` (en `cliente/dart`) sabe preguntar y escuchar el WebSocket, sin Flutter ni nada de Android. También lee un APK (`ApkInfo`, el mismo lector que usa el hub) y lo publica.

```dart
final a = ApkActualizador(
  servidor: 'https://TU-HUB',
  app: 'inventario',
  buildActual: () async => 84,
  instalacion: claveGuardada,
);
a.disponible.listen((v) => print('hay ${v.version} en ${v.url}'));
a.iniciar();
a.conectarAvisos();
```

## Equipos

### `POST /v1/apps/:app/consulta`

*Acceso: público*

Lo que pregunta una app instalada: «tengo la build N, ¿hay algo?». De paso deja anotada la instalación. `requerido` es verdadero si alguna versión por encima de la build actual es obligatoria, aunque la última no lo sea.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `build` | entero | sí | El `versionCode` instalado. |
| `instalacion` | texto | no | Clave de la instalación (8–100 caracteres, la genera la app). Sin ella no se anota nada. |
| `huella` | texto | no | El ANDROID_ID. Si la app se reinstala, la fila del equipo se reusa. |
| `version` | texto | no | El `versionName` instalado. |
| `modelo` | texto | no | Modelo del equipo. |
| `fabricante` | texto | no |  |
| `android` | entero | no | Nivel de SDK de Android. |
| `contexto` | objeto | no | Lo que la app quiera contar (empresa, usuario…). Hasta 4 KB. |

```json
{
  "build_actual": 80,
  "actualizar": true,
  "requerido": true,
  "version": {
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
  }
}
```

### `GET /v1/apps/:app/ultima`

*Acceso: público*

La misma respuesta que la consulta, sin anotar nada. Para mirar a mano o desde un script.

| Parámetro | Tipo | | |
|---|---|---|---|
| `build` | entero |  | La build contra la que comparar (0 si se omite). |

```bash
curl "https://TU-HUB/v1/apps/inventario/ultima?build=80"
```

### `GET /v1/ws?app=:app&instalacion=:clave`

*Acceso: público*

WebSocket de la app instalada. Al publicar (o retirar, o marcar obligatoria) llega `{"tipo":"version","app","build","requerido"}` y la app consulta. Mientras está abierto, el equipo figura como conectado; al cerrarse queda la hora en que se vio por última vez. El hub manda ping cada 30 s; un cliente que no pueda contestar pings de protocolo puede mandar `{"tipo":"ping"}` y recibe `{"tipo":"pong"}`.

### `GET /archivos/:sha256.apk`

*Acceso: público*

El APK. La URL lleva el sha256 del contenido: no cambia nunca y se cachea para siempre. Admite `Range` (un teléfono que pierde la señal retoma donde iba). Una versión retirada responde 410.

### `GET /install/:app`

*Acceso: público*

Redirige al APK de la última versión. Es la URL estable para instalar en un equipo nuevo (la de la página `/i/:app` y su código QR).

### `GET /v1/apps/:app`

*Acceso: público*

Ficha pública de la app: nombre, descripción, paquete, icono y la última versión.

## Publicar

### `POST /v1/apps/:app/versiones`

*Acceso: llave con `publicar` o persona*

Sube un APK. El cuerpo es el archivo tal cual. El hub lee del APK el `applicationId`, el `versionCode`, el `versionName`, los SDK y el certificado de firma, y lo rechaza si el paquete o la firma no son los de la app (los fija la primera versión), o si esa build ya existe con otro contenido. Si el APK trae la biblioteca de Android, también lee a qué hub y a qué app dice que va (`apkServerHub`, `apkServerApp`) y lo rechaza si no son este hub y esta app: los equipos nunca verían esa publicación. Repetir la misma publicación no es error: devuelve la versión con `ya_estaba`. Al terminar avisa por WebSocket a los equipos conectados.

| Parámetro | Tipo | | |
|---|---|---|---|
| `notas` | texto |  | Lo que ve quien actualiza. |
| `requerido` | 1 |  | Obligatoria: nadie se queda por debajo de esta build. |
| `build` | entero |  | Opcional: si se da y no es la del APK, se rechaza. |
| `version` | texto |  | Opcional: igual, contra el `versionName`. |

```json
{ …la versión…, "avisadas": 12 }
```

```bash
curl -X POST "https://TU-HUB/v1/apps/inventario/versiones?build=84&notas=Arreglos" \
  -H "authorization: Bearer cak_..." \
  --data-binary @build/app/outputs/flutter-apk/app-release.apk
```

### `PATCH /v1/apps/:app/versiones/:build`

*Acceso: llave con `publicar` o persona*

Cambia `notas`, `requerido` o `retirada` (true deja de ofrecerla y de servirla; false la devuelve). Los equipos conectados reciben el aviso y vuelven a consultar.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `notas` | texto | no |  |
| `requerido` | booleano | no |  |
| `retirada` | booleano | no |  |

### `DELETE /v1/apps/:app/versiones/:build`

*Acceso: admin*

Borra una versión ya retirada y su APK del disco (si ninguna otra lo usa). No tiene vuelta.

### `GET /v1/apps/:app/versiones`

*Acceso: llave con `leer` o persona*

Todas las versiones, con descargas y cuántos equipos tienen cada una (últimos 30 días).

## Apps

### `GET /v1/apps`

*Acceso: llave con `leer` o persona*

Las apps de la organización, con su última versión, espacio y equipos (vistos, al día y conectados).

### `POST /v1/apps`

*Acceso: admin*

Crea una app. El `slug` es global en el hub (va en las URL públicas) y no se cambia. Una app por `applicationId`: dos sabores con distinto paquete son dos apps.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `slug` | texto | sí | Minúsculas, números y guiones; hasta 63. |
| `nombre` | texto | sí |  |
| `descripcion` | texto | no |  |

### `PATCH /v1/apps/:app`

*Acceso: admin*

Cambia `nombre` o `descripcion`.

### `PUT /v1/apps/:app/icono`

*Acceso: admin*

Sube el icono (PNG, JPEG o WebP, hasta 512 KB; el tipo se mira en los bytes). `DELETE` lo quita.

### `DELETE /v1/apps/:app`

*Acceso: admin*

Borra una app sin versiones.

## Equipos instalados

### `GET /v1/apps/:app/instalaciones`

*Acceso: llave con `leer` o persona*

Los equipos que consultaron en los últimos `dias` (90 por defecto), conectados primero, y el reparto por build.

| Parámetro | Tipo | | |
|---|---|---|---|
| `dias` | entero |  | 1 a 3650. |

### `PATCH /v1/apps/:app/instalaciones/:id`

*Acceso: persona*

Le pone `nombre` a un equipo («Terminal 3 — recepción»).

### `DELETE /v1/apps/:app/instalaciones/:id`

*Acceso: admin*

Olvida un equipo (si vuelve a consultar, reaparece).

## Usuarios y llaves

### `POST /v1/auth/login`

*Acceso: público*

Entra con `correo` y `clave`. Devuelve `{token, usuario}`.

### `GET /salud`

*Acceso: público*

Si el hub y su base contestan. `recuperar` es verdadero si alguna organización tiene correo de salida: el panel lo usa para ofrecer «¿Olvidaste tu clave?» en la entrada.

```json
{ "ok": true, "servicio": "apk-server", "registro": "cerrado", "recuperar": true }
```

### `POST /v1/auth/recuperar`

*Acceso: público*

«¿Olvidaste tu clave?». Con el `correo`, si tiene cuenta y su organización tiene correo de salida, le manda por ese correo un enlace para poner una clave nueva (el mismo de la invitación, de un solo uso, que vence en 1 hora; el enlace anterior deja de servir). Contesta siempre `{"pedido": true}`, exista o no el correo: no sirve para averiguar quién tiene cuenta. Frenos: 5 por minuto por IP y 3 por hora por correo (`429`).

```json
{ "pedido": true }
```

### `POST /v1/usuarios`

*Acceso: admin*

Invita a una persona (`correo`, `nombre`, `rol`: `admin` o `editor`). Devuelve `enlace`, de un solo uso y por 7 días, para que ponga su clave. Si la organización tiene correo de salida, además se lo manda; `envio` dice qué pasó: `null` sin correo de salida (el enlace se comparte a mano), `{enviado: true, para}` o `{enviado: false, error, detalle}` (el enlace sirve igual).

```json
{ "id": 7, "correo": "ana@ejemplo.com", …, "enlace": "https://TU-HUB/#/activar/…", "envio": { "enviado": true, "para": "ana@ejemplo.com" } }
```

### `POST /v1/usuarios/:id/invitacion`

*Acceso: admin*

Otro enlace para la misma persona (el anterior deja de servir). También sirve para que ponga una clave nueva. Devuelve `enlace` y `envio`, como al invitar.

### `POST /v1/auth/activar`

*Acceso: público*

Con el `token` del enlace (de la invitación o de «¿Olvidaste tu clave?») y la `clave` nueva. Devuelve la sesión. Si el enlace venció o ya se usó, `410 invitacion_vencida`.

### `POST /v1/llaves`

*Acceso: admin*

Crea una llave (`nombre`, `permisos`, `apps`). La llave completa se ve solo en esta respuesta; se guarda hasheada.

### `DELETE /v1/llaves/:id`

*Acceso: admin*

Revoca una llave. La fila se queda: explica quién publicó qué.

## Organización

### `GET /v1/org/correo`

*Acceso: admin*

El correo de salida de la organización, sin la clave: `clave_puesta` dice si hay una. Con él salen las invitaciones y los enlaces de «¿Olvidaste tu clave?».

```json
{ "host": "smtp.gmail.com", "puerto": 587, "seguridad": "starttls", "remitente": "avisos@ejemplo.com", "usuario": "avisos@ejemplo.com", "nombre": "apk-server de Ejemplo", "clave_puesta": true, "configurado": true }
```

### `PUT /v1/org/correo`

*Acceso: admin*

Guarda el correo de salida. La clave no vuelve nunca; si no viene, o viene vacía, se queda la que estaba. `{"quitar": true}` lo borra. Devuelve lo mismo que el `GET`.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `host` | texto | sí | El servidor SMTP (`smtp.gmail.com`). |
| `puerto` | entero | sí | Suele ser 587 (STARTTLS) o 465 (TLS). |
| `seguridad` | texto | no | `starttls` (por defecto), `tls` o `ninguna` (solo en una red propia). |
| `remitente` | texto | sí | La dirección del «De:». |
| `usuario` | texto | no | Para autenticar; sin él no se autentica. |
| `clave` | texto | no | En Gmail, una contraseña de aplicación. |
| `nombre` | texto | no | El nombre que se ve en el «De:». |

### `POST /v1/org/correo/prueba`

*Acceso: admin (persona)*

Manda un correo de prueba a quien lo pide. Si el servidor no lo acepta, `502` con lo que contestó (`correo_autenticacion`, `correo_conexion`, `correo_tls`…).

```json
{ "enviado": true, "para": "tu@ejemplo.com" }
```

## Errores

| HTTP | Código | Cuándo |
|---|---|---|
| 400 | `apk_invalido` | Lo subido no es un APK que se pueda leer (el mensaje dice por qué). |
| 400 | `build_no_coincide` | La build dicha en la consulta no es la del APK. |
| 401 | `no_autenticado` | Falta la credencial o no es válida. |
| 403 | `sin_permiso` | La llave no tiene el permiso que hace falta. |
| 404 | `app_no_existe` | No hay una app con ese nombre (o no es de tu organización). |
| 409 | `paquete_distinto` | El APK es de otro `applicationId` que la app. |
| 409 | `app_distinta` | El manifiesto del APK dice que es de otra app (`apkServerApp`). |
| 409 | `hub_distinto` | El manifiesto del APK pregunta a otro hub (`apkServerHub`). |
| 409 | `firma_distinta` | El APK está firmado con otra llave: los equipos no podrían actualizar. |
| 409 | `build_repetida` | Esa build ya está publicada con otro APK. |
| 410 | `retirada` | Se pidió el APK de una versión retirada. |
| 410 | `invitacion_vencida` | El enlace para poner la clave venció o ya se usó. |
| 413 | `apk_grande` | Pasa del tope del hub (`APK_MAX_APK_MB`). |
| 429 | `demasiadas_consultas` | Más de 240 consultas por minuto desde la misma IP. |
| 429 | `demasiados_intentos` | Entrar, activar o «¿Olvidaste tu clave?» demasiadas veces seguidas. |
| 502 | `correo_*` | El servidor de correo no aceptó el de prueba (el mensaje dice qué contestó). |
