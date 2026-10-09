# Compila el hub y el sitio, y deja una imagen con el binario y poco más.
FROM node:22-alpine AS sitio
WORKDIR /sitio
COPY manager/package*.json ./
RUN npm install --silent
COPY manager/ ./
COPY docs/ /docs/
RUN npm run docs && npm run build

FROM dart:stable AS compilador
WORKDIR /app
# El cliente de Dart (el lector de APK) va por ruta: ../cliente/dart.
COPY cliente/dart/ /cliente/dart/
# El pubspec y su lockfile primero: mientras no cambien, esta capa se reusa y
# la compilación no vuelve a bajar nada.
COPY hub/pubspec.yaml hub/pubspec.lock ./
RUN dart pub get
COPY hub/ ./
RUN dart compile exe bin/apk_server_hub.dart -o /app/apk-server-hub

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/apk-server
COPY --from=compilador /app/apk-server-hub ./
COPY --from=compilador /app/migraciones ./migraciones
COPY --from=sitio /sitio/dist ./manager
ENV APK_MANAGER=/opt/apk-server/manager \
    APK_ARCHIVOS=/var/lib/apk-server/archivos
# Los APK viven aquí: móntalo en un volumen o se pierden con el contenedor.
VOLUME /var/lib/apk-server
EXPOSE 3130
CMD ["./apk-server-hub"]
