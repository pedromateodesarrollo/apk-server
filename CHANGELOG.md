# Cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/).

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
