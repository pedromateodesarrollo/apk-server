# Cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/).

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
