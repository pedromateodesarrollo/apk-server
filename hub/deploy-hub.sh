#!/usr/bin/env bash
# Compila el hub (AOT) e instala un servicio systemd.
#
#   ./deploy-hub.sh --local        → esta máquina: /opt/apk-server-hub + systemd
#   ./deploy-hub.sh --produccion   → servidor remoto por SSH (DEPLOY_HOST)
#
# Requiere dart en PATH y, para --produccion, acceso SSH con sudo.
# La URL de la base y el secreto JWT viven en /etc/apk-server-hub.env (600, root):
#
#   APK_DATABASE_URL=postgres://usuario:clave@localhost:5432/apk_server
#   APK_SECRETO_JWT=<48 bytes al azar en hex>
#   APK_URL_PUBLICA=https://tu-dominio
#   APK_HOST=127.0.0.1
#   APK_ARCHIVOS=/var/lib/apk-server/archivos
#
# Ese archivo no lo escribe este script: las claves no viajan por aquí.
[[ -n "$BASH_VERSION" ]] || exec bash "$0" "$@"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sin valor por defecto a propósito: un despliegue tiene que decir a dónde va.
readonly DEPLOY_HOST="${DEPLOY_HOST:-}"
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/apk-server-hub}"
readonly DATA_DIR="${DATA_DIR:-/var/lib/apk-server}"
readonly SERVICE_NAME="apk-server-hub"
readonly BINARY_NAME="apk-server-hub"
readonly PORT="${PORT:-3130}"

usage() {
  cat <<'AYUDA'
deploy-hub.sh --local | --produccion

  --local        Compila e instala en ESTA máquina (systemd).
  --produccion   Compila aquí y despliega en DEPLOY_HOST por SSH.

Variables: DEPLOY_HOST (obligatoria para --produccion), INSTALL_DIR, DATA_DIR, PORT
AYUDA
}

compila() {
  echo "→ compilando (AOT)…"
  cd "$SCRIPT_DIR"
  dart pub get >/dev/null
  dart compile exe bin/apk_server_hub.dart -o "/tmp/$BINARY_NAME"
}

# El servicio corre con un usuario propio, sin shell ni casa: lo único que
# escribe es la carpeta de los APK.
unidad() {
  cat <<UNIDAD
[Unit]
Description=apk-server: repositorio y actualización de APK
After=network.target postgresql.service

[Service]
Type=simple
User=apk-server
Group=apk-server
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=/etc/apk-server-hub.env
Environment=APK_MANAGER=$INSTALL_DIR/manager
Environment=APK_MIGRACIONES=$INSTALL_DIR/migraciones
ExecStart=$INSTALL_DIR/$BINARY_NAME
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
UNIDAD
}

prepara_remoto='
  id apk-server >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin apk-server
  sudo mkdir -p '"$INSTALL_DIR"' '"$DATA_DIR"'/archivos
  sudo chown -R apk-server:apk-server '"$DATA_DIR"'
  sudo chown $USER '"$INSTALL_DIR"'
'

case "${1:-}" in
  --local)
    compila
    bash -c "$prepara_remoto"
    cp "/tmp/$BINARY_NAME" "$INSTALL_DIR/"
    rm -rf "$INSTALL_DIR/migraciones" && cp -r "$SCRIPT_DIR/migraciones" "$INSTALL_DIR/"
    unidad | sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager | head -5
    ;;
  --produccion)
    [[ -n "$DEPLOY_HOST" ]] || { echo "Define DEPLOY_HOST con el servidor de destino."; exit 64; }
    compila
    echo "→ subiendo a $DEPLOY_HOST…"
    ssh "$DEPLOY_HOST" "$prepara_remoto"
    # A un nombre temporal: el binario en uso no se puede sobrescribir («text
    # file busy»), así que se sustituye con el servicio parado y de un `mv`,
    # que es atómico.
    scp -q "/tmp/$BINARY_NAME" "$DEPLOY_HOST:$INSTALL_DIR/$BINARY_NAME.nuevo"
    ssh "$DEPLOY_HOST" "rm -rf $INSTALL_DIR/migraciones"
    scp -qr "$SCRIPT_DIR/migraciones" "$DEPLOY_HOST:$INSTALL_DIR/"
    unidad | ssh "$DEPLOY_HOST" "sudo tee /etc/systemd/system/$SERVICE_NAME.service >/dev/null"
    ssh "$DEPLOY_HOST" "sudo test -f /etc/apk-server-hub.env || { echo 'Falta /etc/apk-server-hub.env (ver la cabecera de este script).'; exit 1; }
      sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
      mv $INSTALL_DIR/$BINARY_NAME.nuevo $INSTALL_DIR/$BINARY_NAME
      chmod +x $INSTALL_DIR/$BINARY_NAME
      sudo systemctl daemon-reload
      sudo systemctl enable $SERVICE_NAME >/dev/null 2>&1
      sudo systemctl start $SERVICE_NAME
      sleep 2
      systemctl status $SERVICE_NAME --no-pager | head -5
      echo '→ salud:'; curl -sf http://127.0.0.1:$PORT/salud || echo '(sin respuesta)'"
    ;;
  *)
    usage; exit 64;;
esac
