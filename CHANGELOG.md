# Cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/).

## Sin publicar

Correo de salida por organización y, con él, «¿Olvidaste tu clave?».

### Hub

* **Correo de salida de cada organización** (migración `0002_correo.sql`):
  `GET`/`PUT /v1/org/correo`, solo quien administra; la clave no vuelve nunca y
  guardar sin ella deja la que estaba; `{"quitar": true}` lo borra.
  `POST /v1/org/correo/prueba` le manda uno de prueba a quien lo pide. El
  cliente SMTP es propio, con `dart:io` (TLS 465, STARTTLS 587), sin
  dependencias nuevas: el mismo de device-track.
* **Las invitaciones salen por ese correo.** `POST /v1/usuarios` y
  `POST /v1/usuarios/:id/invitacion` traen `envio`: `null` sin correo de
  salida, `{enviado: true, para}` o `{enviado: false, error, detalle}`. El
  enlace se devuelve igual. A quien ya entraba, el correo es de «clave nueva»,
  no de invitación.
* **«¿Olvidaste tu clave?»**: `POST /v1/auth/recuperar {correo}` manda, por el
  correo de salida de la organización de esa persona, el mismo enlace de la
  invitación, de un solo uso y que vence en una hora. Contesta siempre
  `{"pedido": true}`, exista o no la cuenta, y no espera al correo. Frenos: 5
  por minuto por IP y 3 por hora por correo.
* `GET /salud` suma `recuperar`: si alguna organización tiene correo de salida.
* El enlace vencido (`POST /v1/auth/activar`) dice cómo pedir otro.
* CORS acepta `PUT` (el icono de una app y el correo de salida).

### Panel

* «¿Olvidaste tu clave?» en la entrada, solo cuando el hub puede mandar el
  enlace.
* Pantalla **Organización** (quien administra), con el correo de salida y su
  prueba.
* Usuarios dice si el enlace salió por correo o si hay que compartirlo a mano.

## 0.2.0 — 2026-10-09

Una sola biblioteca de actualización para cualquier app Android, y el proyecto
dice una vez a qué hub va.

### Clientes

* **`cliente/android`, biblioteca nueva**: toda la lógica de actualizarse, en
  Kotlin, para cualquier app (nativa o Flutter). Escucha el WebSocket, pregunta
  cada hora y al volver la red, baja en segundo plano con la pantalla apagada y
  retoma lo cortado, comprueba tamaño y **sha256** e instala sin preguntar desde
  Android 12. Antes la lógica estaba en Dart dentro del plugin de Flutter, y
  cada app nativa tenía su copia.
* **Notificación de «lista»** al terminar de bajar. Al tocarla se instala, y si
  hace falta la persona (falta «Permitir de esta fuente», o Android pide
  confirmar) sale la pantalla del sistema. Se queda hasta que la versión se
  instala; un receptor de `MY_PACKAGE_REPLACED` la quita, con el APK, en cuanto
  la app se actualiza. Con `notificarDescarga`, una callada con el avance.
* **El hub y la app van en el `build.gradle.kts`** (`manifestPlaceholders`
  `apkServerHub` y `apkServerApp`, por sabor), y la biblioteca los lee del
  manifiesto. Sin ellos la app no compila; con el hub vacío no se actualiza.
* **Lo bajado sobrevive al proceso**: si la app se cierra, al volver el APK
  sigue listo. Una versión que el hub deja de ofrecer (retirada) se borra.
* Ajustes para apps de fondo: `soloWifi`, `autoInstalar`, `puedeInstalar`,
  `quizas()`, `pingSegundos`, `esperaMaxAvisosMs`.
* `apk_server_flutter` 0.2.0 compila la biblioteca dentro del plugin. Su API en
  Dart sigue igual (`UpdateService`, `UpdateTarjeta`, `UpdateBanner`,
  `UpdateAccion`); `servidor` y `app` pasan a opcionales (salen del
  manifiesto), suma `urlInstalar`, y `UpdateEstado` trae `build` y `falta`. Sale
  `UpdateInstalador` y ya no depende de `open_filex`, `package_info_plus` ni
  `path_provider`. Arreglado: dos toques seguidos a «Instalar» podían armar dos
  instalaciones.
* La clave de la instalación se conserva al pasar de la 0.1 (o de los
  actualizadores nativos de antes): para el panel es el mismo equipo. Probado
  en Android 15: una app con la 0.1.2 se actualizó sola a una con la 0.2.0 y
  siguió con su clave.
* **`publicar`**: `dart run apk_server_flutter:publicar --apk …` (o
  `apk_server:publicar`) lee del APK a qué hub y a qué app va y lo sube.
  Comprueba `--build`/`--version`, revisa todos los sabores antes de subir el
  primero y tiene `--simular`.
* `apk_server` (Dart) suma `ApkInfo` (lee paquete, versión, firma y los
  meta-data de un APK) y depende de `crypto`.

### Hub

* Usa el lector de APK de `cliente/dart`, que ahora también lee los meta-data.
* Rechaza el APK cuyo manifiesto dice que es de otra app (`app_distinta`) o
  que pregunta a otro hub (`hub_distinto`).

## 0.1.2 — 2026-10-08

### Hub

* El WebSocket de avisos va sin compresión. dart:io contestaba
  `permessage-deflate` con `client_max_window_bits` aunque el cliente no lo
  hubiera pedido, y OkHttp (el socket de una app Android nativa) cortaba con
  1010: esas apps nunca quedaban conectadas y solo se enteraban de una
  versión nueva por el sondeo de cada hora.
* Sirve `.jpg` como `image/jpeg`.

### Sitio

* La portada y el README explican en simple qué es y cómo funciona; lo
  técnico queda al final. Resumen en inglés al principio del README.
* El enlace de una invitación ya usada lleva a entrar al panel, y el de
  cambiar la clave reconoce a quien ya tiene la sesión abierta.
* El botón «Panel» de la barra ya no sale gris y la documentación no queda
  pegada al borde en el teléfono.

### Clientes

* `apk_server_flutter`: una descarga que se cortaba se quedaba en error y nada
  la volvía a arrancar hasta reabrir la app —el sondeo y los avisos entregan
  cada build una sola vez, y esa ya se había entregado—. Visto el 2026-10-08
  con una versión obligatoria del WMS: el aviso llegó y las dos terminales
  empezaron a bajar, pero a una la cortó un cambio de punto de acceso en 26 de
  61 MB y ahí se quedó, sin que la tarjeta dijera nada. Ahora:
  * La descarga sigue desde donde se cortó (`Range`; el hub ya lo atendía). El
    pedazo lleva la huella de la URL y solo se retoma con el mismo archivo; al
    final se comprueba el tamaño que dijo el hub.
  * 45 s sin recibir nada es un corte (`UpdateInstalador.sinDatos`): antes una
    conexión colgada dejaba la descarga «bajando» para siempre.
  * `UpdateService` reintenta solo, volviendo a preguntar (así se entera de
    que la versión se retiró o de que salió otra), a los 5 s, 15 s, 30 s,
    1 min, 2 min y después cada 5 min (`esperasReintento`), y en cuanto el
    WebSocket reconecta.
  * El estado de error de una descarga lleva la versión y el progreso, y
    `UpdateTarjeta` lo enseña: «Se cortó la descarga… Sigue sola», con
    «Reintentar ahora». Probado en una Zebra TC56 (Android 8.1).

## 0.1.1 — 2026-10-07

### Hub

* Un equipo recién instalado figuraba como desconectado aunque tuviera el
  WebSocket abierto. La app abre el socket y hace su primera consulta a la
  vez; el socket solía llegar antes, cuando la fila del equipo todavía no
  existía, y la marca de «conectado» no encontraba nada que marcar. Ahora la
  consulta toma el estado del registro de sockets vivos. Visto con la primera
  terminal real (un emulador con Android 15).

## 0.1.0 — 2026-10-07

Primera versión. Nace del mecanismo de actualización de las apps de Chalona,
que vivía dentro de su plataforma (APK en la base de datos, consulta con la
sesión de la persona) y aquí pasa a ser un servicio aparte, con su propia base
y sin depender de nada de Chalona.

### Hub

* Publicar con un `POST` del APK tal cual. El hub lee del APK el paquete, el
  `versionCode`, el `versionName`, los SDK y el certificado de firma, y rechaza
  otro paquete, otra firma o una build repetida con otro contenido.
* APK en disco, con su sha256 por nombre: URL de descarga inmutable, con
  `Range` y caché para siempre.
* Consulta de versión pública que anota la instalación (clave, ANDROID_ID,
  modelo, Android, contexto de la app). Una build obligatoria obliga a todo el
  que esté por debajo, aunque después salgan otras opcionales.
* WebSocket de avisos: al publicar, retirar o marcar obligatoria, las apps
  conectadas preguntan en el acto; el equipo figura conectado mientras el
  socket vive.
* Organizaciones, personas por invitación (enlace de un solo uso), llaves de
  API acotables a unas apps, registro cerrado por defecto.
* Órdenes de consola `org`, `invitar`, `llave` y `migrar`.

### Sitio

* Presentación, documentación del API, panel (apps, versiones, equipos, llaves,
  usuarios) y página de instalación `/i/<app>` con código QR.

### Clientes

* `cliente/dart` (`apk_server`): consulta y WebSocket, sin dependencias.
* `cliente/flutter` (`apk_server_flutter`): descarga, instalación sin preguntar
  en Android 12+ con `PackageInstaller`, datos del equipo y widgets de estado.
