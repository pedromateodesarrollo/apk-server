#!/usr/bin/env bash
# Compila el sitio (presentación + documentación + panel) y lo sube al hub.
#
#   ./deploy-manager.sh --produccion   → DEPLOY_HOST, carpeta del hub
#   ./deploy-manager.sh --local        → /opt/apk-server-hub/manager
[[ -n "$BASH_VERSION" ]] || exec bash "$0" "$@"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sin valor por defecto a propósito: un despliegue tiene que decir a dónde va.
readonly DEPLOY_HOST="${DEPLOY_HOST:-}"
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/apk-server-hub}"

cd "$SCRIPT_DIR"
echo "→ compilando el sitio…"
npm install --silent
npm run docs --silent
npm run build --silent

case "${1:-}" in
  --local)
    sudo rm -rf "$INSTALL_DIR/manager"
    sudo cp -r dist "$INSTALL_DIR/manager"
    ;;
  --produccion)
    [[ -n "$DEPLOY_HOST" ]] || { echo "Define DEPLOY_HOST con el servidor de destino."; exit 64; }
    echo "→ subiendo a $DEPLOY_HOST…"
    tar -C dist -czf /tmp/apk-server-manager.tgz .
    scp -q /tmp/apk-server-manager.tgz "$DEPLOY_HOST:/tmp/"
    # A una carpeta nueva y después el cambio: el hub nunca sirve un sitio a medias.
    ssh "$DEPLOY_HOST" "rm -rf $INSTALL_DIR/manager.nuevo && mkdir -p $INSTALL_DIR/manager.nuevo \
      && tar -C $INSTALL_DIR/manager.nuevo -xzf /tmp/apk-server-manager.tgz && rm /tmp/apk-server-manager.tgz \
      && rm -rf $INSTALL_DIR/manager.viejo && { [ -d $INSTALL_DIR/manager ] && mv $INSTALL_DIR/manager $INSTALL_DIR/manager.viejo || true; } \
      && mv $INSTALL_DIR/manager.nuevo $INSTALL_DIR/manager && rm -rf $INSTALL_DIR/manager.viejo && ls $INSTALL_DIR/manager"
    ;;
  *)
    echo "Uso: ./deploy-manager.sh --local | --produccion"; exit 64;;
esac
echo "listo."
