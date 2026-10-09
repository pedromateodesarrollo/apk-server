# Contribuir

## Levantar el entorno

```bash
# Base de datos (o usa la tuya)
docker compose up -d bd

# Hub, en el puerto que espera el sitio en desarrollo
cd hub && dart pub get
APK_DATABASE_URL=postgres://apk:apk@localhost:5432/apk_server APK_PUERTO=3131 \
  dart run bin/apk_server_hub.dart

# Tu organización (imprime el enlace para poner la clave)
APK_DATABASE_URL=... APK_URL_PUBLICA=http://localhost:5173 \
  dart run bin/apk_server_hub.dart org --nombre Prueba --correo tu@correo.com

# Sitio, con proxy al hub en :3131
cd manager && npm install && npm run dev
```

## Antes de mandar un cambio

```bash
cd hub && dart analyze && dart test
cd cliente/android && ./gradlew testDebugUnitTest lintRelease   # necesita el SDK de Android (local.properties)
cd cliente/dart && dart analyze && dart test
cd cliente/flutter && flutter analyze && flutter test
cd manager && npm run docs && npm run build
```

Las pruebas del hub contra Postgres (`hub/test/hub_test.dart`) se saltan si no
está `APK_PRUEBA_DATABASE_URL`. Apúntala a una base **desechable**: la prueba
borra el esquema `apk` al empezar.

```bash
docker run -d --name apk-bd -e POSTGRES_PASSWORD=apk -p 55432:5432 postgres:16-alpine
APK_PRUEBA_DATABASE_URL='postgres://postgres:apk@127.0.0.1:55432/postgres?sslmode=disable' dart test
```

Los APK de las pruebas se arman byte a byte en `cliente/dart/lib/src/apk_sintetico.dart`
(lo usan las pruebas del cliente y las del hub): no subas APK de verdad al
repositorio. Para mirar qué lee el hub de un APK real:
`dart run tool/leer_apk.dart <archivo.apk>` (en `hub/`), o
`dart run apk_server:publicar --apk <archivo.apk> --simular` para ver a qué hub
y a qué app se subiría.

La documentación del API se escribe en `manager/src/docs.js`; `docs/api.md`
sale de ahí con `npm run docs`.

## Convenciones

* El código, los comentarios y los mensajes van en español. Los mensajes de
  error son para la persona que los lee: dicen qué pasó y qué hacer.
* Un comentario explica el porqué, no el qué.
* El hub tiene dos dependencias (`postgres` y `crypto`). Una tercera necesita
  una buena razón.
* La documentación del API se escribe en `manager/src/docs.js`; `npm run docs`
  regenera `docs/api.md`. No edites el `.md` a mano.
* Una migración aplicada no se edita: se añade otra.
