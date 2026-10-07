# apk-server

Tus apps Android, al día solas, sin Play Store.

Publicas una versión con un `curl` y cada equipo se entera al momento, la baja
y la instala —en Android 12+, sin diálogo—. Y desde el panel sabes qué build
tiene cada terminal, qué modelo es y cuándo se vio por última vez.

```
  Tu script de publicación          Hub                     Equipos
  ────────────────────────      ─────────────────      ─────────────────────
  POST /v1/apps/wms/versiones ─►  lee el APK,     ──►  WebSocket: «salió la 84»
  (curl --data-binary @app.apk)   lo guarda,           consulta, baja, instala
                                  avisa                (sin preguntar, Android 12+)
                                       ▲
                                       └── cada equipo dice qué build tiene
                                           y cuándo se vio por última vez
```

## Qué resuelve

* **Apps que no van a una tienda.** Las terminales de un almacén, la app de un
  cliente, una herramienta interna. Se reparten desde tu servidor, con un
  enlace y un código QR para el primer equipo.
* **Que la versión nueva llegue.** Cada app abre un WebSocket con el hub; al
  publicar, todas se enteran en el acto. El sondeo cada hora queda de respaldo
  para la que estaba apagada.
* **Publicar mal.** El hub abre el APK y lee el `applicationId`, el
  `versionCode` y el certificado de firma. Un APK de otro sabor, con un número
  que no es el que dijiste o firmado con otra llave se rechaza ahí, no cuando
  Android se niega a instalarlo en el teléfono.
* **No saber qué hay instalado.** Cada consulta deja anotado el equipo: build,
  modelo, versión de Android, ANDROID_ID y lo que la app quiera contar (la
  empresa, quién tiene la sesión). Le pones nombre a cada terminal y ves cuáles
  están conectadas ahora.
* **La que tiene que llegar sí o sí.** Una versión obligatoria obliga a todo el
  que esté por debajo, aunque después salgan otras opcionales.

## Publicar

```bash
curl -X POST "https://tu-hub/v1/apps/inventario/versiones?notas=Arreglos%20de%20la%20toma" \
  -H "authorization: Bearer cak_tu_llave" \
  --data-binary @build/app/outputs/flutter-apk/app-release.apk
```

O con el script de `herramientas/`, que además comprueba que el `versionCode`
sea el que esperas:

```bash
APK_SERVER_LLAVE=cak_... herramientas/apk-publicar \
  --hub https://tu-hub --app inventario --apk app-release.apk --build 84 --notas "Arreglos"
```

Repetir la misma publicación no es un error: un script que se cortó a la mitad
se puede volver a correr.

## Que la app se actualice sola

```yaml
# pubspec.yaml
dependencies:
  apk_server_flutter:
    git:
      url: https://github.com/pedromateodesarrollo/apk-server
      path: cliente/flutter
```

```dart
final update = UpdateService(
  servidor: 'https://tu-hub',
  app: 'inventario',
  contexto: () => {'empresa': sesion.empresa, 'usuario': sesion.nombre},
);
update.iniciar();        // pregunta ya, cada hora y cuando el hub avisa

Scaffold(bottomNavigationBar: UpdateBanner(update), ...);
```

El paquete trae el plugin de Android: instala con `PackageInstaller` sin
diálogo desde Android 12 (si la persona ya permitió instalar desde la app) y,
si no se puede, con el instalador de siempre. **Instalar cierra la app** y
Android no la vuelve a abrir: cuándo instalar lo decide la app (`autoInstalar`,
`puedeInstalar`, o el botón del banner).

Para Dart sin Flutter está `cliente/dart` (`apk_server`): solo el protocolo.

## Levantar tu propio hub

```bash
docker compose up -d
docker compose exec hub ./apk-server-hub org --nombre "Mi empresa" --correo tu@correo.com
```

La segunda línea crea tu organización y te devuelve el enlace para poner tu
clave. Sin Docker:

```bash
cd hub
dart pub get
APK_DATABASE_URL=postgres://usuario:clave@localhost:5432/apk_server \
  dart run bin/apk_server_hub.dart
```

Necesita un Postgres y una carpeta donde guardar los APK. Las migraciones se
aplican solas al arrancar.

| Variable | Por defecto | Para qué |
|---|---|---|
| `APK_DATABASE_URL` | — | Obligatoria |
| `APK_HOST` | `0.0.0.0` | `127.0.0.1` detrás de un nginx en la misma máquina |
| `APK_PUERTO` | 3130 | |
| `APK_SECRETO_JWT` | aleatoria | Fíjala: si cambia, se cierran todas las sesiones |
| `APK_REGISTRO` | `cerrado` | `cerrado` (por invitación) o `abierto` |
| `APK_ARCHIVOS` | `archivos` | Carpeta de los APK (uno por archivo, con su sha256 por nombre) |
| `APK_MAX_APK_MB` | 300 | Tope de un APK |
| `APK_URL_PUBLICA` | se deduce del proxy | `https://tu-hub`, para las URL de descarga |
| `APK_CORS` | `*` | Lista de orígenes separada por comas |
| `APK_MANAGER` | `manager` | Carpeta del sitio compilado |

**El registro va cerrado por defecto**, al revés que en print-server. Un hub
abierto es un sitio donde cualquiera sube un APK y lo reparte con el nombre de
tu dominio: lo que buscan quienes distribuyen malware, y el camino directo a
que el navegador marque tu dominio como peligroso.

Órdenes de consola, para lo que no se puede hacer desde el panel porque todavía
no hay nadie que entre:

```bash
apk-server-hub org --nombre N --correo C     # organización + su administrador (imprime el enlace)
apk-server-hub invitar --correo C            # enlace nuevo para alguien que ya existe
apk-server-hub llave --org 1 --nombre "CI" --permisos publicar --apps inventario
```

Imprimen el resultado —un enlace, una llave— en stdout y nada más, para que se
pueda mandar directo a un archivo sin que pase por la pantalla.

Con nginx delante: `hub/nginx-hub.conf` (límites de peticiones, subidas
grandes sin pasar por un temporal, el WebSocket). Con systemd:
`hub/deploy-hub.sh`.

## Cómo está armado

| Carpeta | Qué hay |
|---|---|
| `hub/` | Servidor: REST, WebSocket de las apps, lectura del APK. Dart, dos dependencias |
| `manager/` | Sitio web: presentación, documentación, panel y la página de instalación de cada app |
| `cliente/dart/` | Cliente Dart puro: consulta y avisos. Sin dependencias |
| `cliente/flutter/` | Paquete Flutter: actualizarse solo, con el plugin de Android |
| `herramientas/` | `apk-publicar`, para scripts y CI |
| `docs/` | Referencia del API (generada desde el sitio) |

Los APK no van en la base: viven en disco, uno por archivo y con el sha256 de
su contenido por nombre. La base guarda de qué app y versión es cada uno. Así
la URL de descarga no cambia nunca, se cachea para siempre y dos
publicaciones no pueden pisarse los bytes.

## Seguridad

Antes de montarlo para clientes conviene leer [SECURITY.md](SECURITY.md): qué
es público y qué no, cómo se guardan las credenciales y qué no hace todavía.

Fallos de seguridad: pedromateo.desarrollo@gmail.com, no un issue público.

## Licencia

Apache-2.0. Úsalo, cámbialo, móntalo para tus clientes.
