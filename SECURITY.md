# Seguridad

## Reportar un fallo

Escribe a **pedromateo.desarrollo@gmail.com** con «apk-server» en el asunto.
Si el fallo permite publicar en una app ajena, sustituir un APK o leer los
equipos de otra organización, dilo en la primera línea.

No abras un issue público para eso. Para todo lo demás, los issues son el sitio.

## Qué es público y qué no

**Público, a propósito:** la ficha de cada app, la consulta de versión, la
descarga del APK, `/install/<app>`, la página `/i/<app>` y el WebSocket de
avisos. Un equipo nuevo no tiene credencial ninguna, y lo que se reparte —un
APK que se instala en cualquier teléfono— es público en cuanto sale. Quien
conoce el nombre de una app puede bajarla. Si una app no debe estar al alcance
de cualquiera, este no es el sitio para repartirla.

**Protegido:** publicar, retirar, marcar obligatoria, el panel y todo lo de los
equipos (qué hay instalado, dónde, con qué contexto).

**Lo que un equipo anota de sí** (clave de la instalación, ANDROID_ID, modelo,
IP y el `contexto` que mande la app) lo ve quien administra la organización
dueña de la app, nadie más. El `contexto` lo decide la app: no le pongas nada
que no quieras que vea quien administra el hub.

## Lo que el hub comprueba al publicar

Un hub comprometido —o una llave de publicar filtrada— puede repartir el APK
que quiera a todos los equipos de una app. Por eso el hub abre cada APK y
rechaza el que:

* es de otro `applicationId` que la app (lo fija la primera versión);
* está firmado con otro certificado que el de la primera versión.

La segunda comprobación es la que importa: sin la llave de firma de la app, un
atacante con la llave de publicar no consigue que los equipos instalen su APK
como actualización (Android tampoco lo aceptaría). **Guarda la llave de firma
de tus apps lejos del hub y del CI que publica.**

El hub no verifica la firma criptográficamente (eso lo hace Android al
instalar): compara el certificado que trae el APK. Un APK con el certificado
correcto pero mal firmado lo rechaza el teléfono.

## Cómo se guardan las credenciales

| Qué | Cómo |
|---|---|
| Claves de usuario | PBKDF2-HMAC-SHA256, 210 000 iteraciones, sal por clave |
| Llaves de API | Solo el sha256 del secreto. El secreto se enseña una vez |
| Enlaces de invitación | Solo el sha256; un uso, siete días |
| Sesiones del panel | JWT HS256 con `APK_SECRETO_JWT`, siete días |

Las comparaciones van en tiempo constante. El log nunca lleva una llave ni un
token. Los errores internos devuelven una referencia, no el texto de la
excepción (que trae nombres de tablas).

## Frenos

* Login, registro e invitaciones: 10 intentos por minuto por IP (y por correo
  en el login).
* Consulta de versión: 240 por minuto por IP en el hub; `hub/nginx-hub.conf`
  pone además 5/s con ráfaga de 40 delante.
* WebSocket: 300 conexiones por IP y 10 000 en total.
* Subidas: `APK_MAX_APK_MB` (300 por defecto). El icono de una app, 512 KB y
  solo PNG, JPEG o WebP reconocidos por sus bytes (un SVG puede llevar script).

## Lo que todavía no hace

* No manda correos: las invitaciones son enlaces que se comparten a mano.
* No tiene doble factor.
* No firma ni verifica criptográficamente los APK (ver arriba).
* No hay apps privadas: toda app publicada se puede bajar conociendo su nombre.
