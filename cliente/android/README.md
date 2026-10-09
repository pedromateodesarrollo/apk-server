# apk-server para Android

La biblioteca que hace que **cualquier app Android** se actualice sola desde
su hub de apk-server: nativa (Kotlin o Java), Flutter (por el paquete
`apk_server_flutter`, que la usa por debajo) o lo que compile con Gradle.

Lo que hace, sin que la app tenga que hacer nada más:

* **Se entera al instante.** Abre el WebSocket del hub; al publicar, el aviso
  llega en el momento. Por si acaso pregunta cada hora, y al volver la red.
* **Baja en segundo plano.** Con la pantalla apagada (wakelock) y con la app
  detrás. Si se corta, sigue desde donde quedó (`Range`) y reintenta sola. Al
  terminar comprueba el tamaño y el sha256 que publicó el hub.
* **Avisa cuando está lista.** Una notificación «Actualización 1.62.0 lista —
  toca para instalarla». Se queda hasta que la versión se instala.
* **Instala sin preguntar** desde Android 12, si la persona le dio una vez a la
  app «Permitir de esta fuente». Si no, al tocar la notificación sale la
  pantalla del sistema (la de dar el permiso, o la de confirmar).
* **Recuerda lo bajado.** Si el proceso muere, al volver el APK sigue listo y
  no se baja otra vez. Cuando la app ya se actualizó, borra el APK y la
  notificación.
* **Cuenta qué equipo es** en cada consulta: ANDROID_ID, modelo, versión y lo
  que la app quiera (`contexto`). Es lo que se ve en la pestaña Equipos.

## El hub va en el build, una vez

En el `build.gradle.kts` de la app, por sabor si los hay:

```kotlin
android {
    defaultConfig {
        manifestPlaceholders["apkServerHub"] = "https://apk.ejemplo.com"
        manifestPlaceholders["apkServerApp"] = "inventario"
    }
    productFlavors {
        create("marca") {
            applicationIdSuffix = ".marca"
            manifestPlaceholders["apkServerApp"] = "inventario-marca" // un applicationId es una app
        }
    }
}
```

De ahí lo lee la biblioteca para saber **de dónde** actualizarse, y el comando
de publicar lo lee del APK para saber **a dónde** subirlo. La app y su
publicación no pueden decir cosas distintas. Sin esos dos valores la app no
compila: instalar la biblioteca es decir a qué hub va. Con el hub vacío (`""`)
la app compila y no se actualiza.

## Usarla

### Desde una app nativa

```kotlin
// settings.gradle.kts: la biblioteca como un proyecto más (este repositorio clonado al lado)
include(":apk-server")
project(":apk-server").projectDir = file("../apk-server/cliente/android")

// app/build.gradle.kts
dependencies { implementation(project(":apk-server")) }
```

El `settings.gradle.kts` de la app tiene que tener `com.android.library` (y el
plugin de Kotlin, si la app lo usa aparte) en su bloque `plugins` con
`apply false`. La biblioteca toma esas versiones y no trae las suyas.

```kotlin
class MiApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Opcional: todo tiene valor por defecto.
        ApkServer.configurar(this) {
            contexto = { JSONObject().put("usuario", sesion.nombre) }
            icono = R.drawable.ic_stat_mi_app
        }
    }
}

// Donde la app quiera estar al día: la pantalla principal o su servicio.
ApkServer.de(this).iniciar()            // pregunta ya, cada hora y cuando el hub avisa
ApkServer.de(this).escuchar { e -> … }  // el estado, en el hilo principal
ApkServer.de(this).instalar()           // el botón de «Instalar ahora»
```

Una app que vive de fondo, sin pantalla (un servicio que reporta cada tanto):

```kotlin
ApkServer.configurar(this) {
    soloWifi = true       // de fondo, el APK pesa decenas de MB
    autoInstalar = true   // instala sola al terminar, si va sin preguntar
    avisos = false        // sin socket, si ya tiene el suyo: pregunta cada hora
}
// tras cada tarea del servicio (barato: solo pregunta si pasó la hora)
ApkServer.de(this).quizas()
```

### Desde Flutter

Con el paquete `apk_server_flutter` (`cliente/flutter`), que compila esta
biblioteca dentro del plugin. En Dart es `UpdateService` y los widgets; ver el
README principal.

## Ajustes

| | Por defecto | |
|---|---|---|
| `hub`, `app` | los del manifiesto | Pisan `apkServerHub` / `apkServerApp`. |
| `avisos` | `true` | El WebSocket del hub, con `iniciar()`. |
| `intervaloMs` | 1 h | Cada cuánto pregunta por si el aviso no llegó. |
| `minEntreChequeosMs` | 5 min | Freno entre consultas que no son a pedido. |
| `esperasReintentoMs` | 5 s, 15 s, 30 s, 1 min, 2 min, 5 min | Entre un corte de la descarga y el siguiente intento. La última se repite. |
| `soloWifi` | `false` | De fondo, bajar solo sin medidor. A pedido (`verificar(manual = true)`) baja igual. |
| `autoInstalar` | `false` | Al terminar, instalar si va sin preguntar. **Instalar cierra la app.** |
| `puedeInstalar` | `{ true }` | Con `autoInstalar`, si en ese momento se puede. |
| `notificarLista` | `true` | La notificación de «lista». |
| `notificarDescarga` | `false` | Una notificación callada con el avance. |
| `icono` | el del sistema | Icono (monocromo) de las notificaciones. |
| `contexto` | — | `() -> JSONObject?`, en cada consulta. Si devuelve null, va lo último que contó. |
| `pingSegundos` | 30 | Ping del socket. Más espaciado gasta menos batería. |
| `esperaMaxAvisosMs` | 32 s | Tope de espera entre reconexiones del socket. |
| `sinDatosMs` | 45 s | Tanto sin recibir un byte es un corte. |

## Estado

`Estado(fase, progreso, version, build, requerido, apk, error, falta)`, con
`fase` una de `AL_DIA`, `VERIFICANDO`, `ESPERANDO_WIFI`, `DESCARGANDO`, `LISTO`,
`INSTALANDO` o `ERROR`. Con `LISTO`, `falta` dice por qué no va sin preguntar:
`permiso` (falta «Permitir de esta fuente») o `confirmar` (Android pidió que
alguien confirme). Un `ERROR` con `version` es una descarga cortada que sigue
sola.

`instalar(conDialogo) { r -> }` contesta `instalada` (casi nunca: la app se
cierra antes), `dialogo` (salió la pantalla del sistema), `confirmar`,
`permiso`, `no_soportado`, `error`, `sin_respuesta`, `sin_apk`, `en_curso` o
`hace_falta_dialogo`.

## Lo que pone en el manifiesto de la app

Permisos: `INTERNET`, `ACCESS_NETWORK_STATE`, `WAKE_LOCK`, `POST_NOTIFICATIONS`
(desde Android 13 lo concede la persona; sin él la app se actualiza igual),
`REQUEST_INSTALL_PACKAGES` y `UPDATE_PACKAGES_WITHOUT_USER_ACTION`. Además, un
receptor del resultado de la instalación, otro de `MY_PACKAGE_REPLACED`, la
pantalla transparente que abre la notificación y un proveedor de solo lectura
que le pasa el APK al instalador del sistema. Ninguno exportado.

## Publicar

```bash
dart run apk_server_flutter:publicar --apk app-release.apk   # desde una app Flutter
dart run apk_server:publicar --apk app-release.apk           # desde cliente/dart, para cualquier otra
```

Hub y app salen del APK. Ver `--help`.

## Probar

```bash
./gradlew testDebugUnitTest   # la lógica entera (consulta, descarga, reintentos, socket), en la JVM
```
