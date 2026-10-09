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
| Enlaces para poner la clave | Solo el sha256; un uso. Siete días los de invitación, una hora los de «¿Olvidaste tu clave?» |
| Sesiones del panel | JWT HS256 con `APK_SECRETO_JWT`, siete días |
| Clave del correo de salida | En claro (hace falta para autenticar ante el servidor SMTP). La API nunca la devuelve: el panel solo sabe si está puesta. Usa una cuenta o una clave de aplicación solo para esto |

Las comparaciones van en tiempo constante. El log nunca lleva una llave ni un
token. Los errores internos devuelven una referencia, no el texto de la
excepción (que trae nombres de tablas).

## «¿Olvidaste tu clave?»

Solo existe si la organización tiene correo de salida. El enlace va al correo
de la cuenta, por el correo de salida de SU organización, y nunca a otro: quien
lo pide no elige a dónde llega. La respuesta es siempre la misma, exista o no
la cuenta, y no espera a que salga el correo: ni lo que contesta ni lo que
tarda dicen qué correos tienen cuenta. `/salud` sí dice si alguna organización
del hub tiene correo de salida (es lo que usa la entrada para ofrecerlo).

Quien controla el buzón de una persona puede poner su clave: es lo que hace
cualquier «¿Olvidaste tu clave?». Si eso no vale para tu hub, no pongas correo
de salida.

## Frenos

* Login, registro e invitaciones: 10 intentos por minuto por IP (y por correo
  en el login).
* «¿Olvidaste tu clave?»: 5 por minuto por IP y 3 por hora por correo, exista
  o no la cuenta.
* Consulta de versión: 240 por minuto por IP en el hub; `hub/nginx-hub.conf`
  pone además 5/s con ráfaga de 40 delante.
* WebSocket: 300 conexiones por IP y 10 000 en total.
* Subidas: `APK_MAX_APK_MB` (300 por defecto). El icono de una app, 512 KB y
  solo PNG, JPEG o WebP reconocidos por sus bytes (un SVG puede llevar script).

## Lo que todavía no hace

* No tiene doble factor.
* No firma ni verifica criptográficamente los APK (ver arriba).
* No hay apps privadas: toda app publicada se puede bajar conociendo su nombre.
