#!/bin/sh
# Deploy the upload server to its host as a rootless systemd user service.
#   ./deploy.sh [user@host]        default espo@upload-server
# Needs: node >= 18 on the host, and loginctl linger for that user so the
# service starts at boot. node_modules are pure JS and are shipped from here,
# so the host needs no npm access.
set -eu
host=${1:-espo@upload-server}
here=$(cd "$(dirname "$0")" && pwd)

[ -d "$here/node_modules" ] || (cd "$here" && npm ci --omit=dev)

# The dev box's http proxy answers LAN hosts with a bogus 503; keep it out.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

rsync -az --delete \
  --exclude .env --exclude test/ \
  "$here/" "$host:bermon-upload/"

ssh "$host" sh -s <<'EOF'
set -eu
cd ~/bermon-upload
if [ ! -e .env ]; then
  pass=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
  umask 077
  cat > .env <<ENV
PORT=8300
SCREENS=bermon01,bermon02
AUTH_USER=bermon
AUTH_PASS=$pass
DATA_DIR=$HOME/bermon-upload-data
PURGE_DAYS=30
MAX_UPLOAD_MB=2048
ENV
  echo "created .env with a new password (user bermon)"
fi
mkdir -p ~/.config/systemd/user
cp bermon-upload.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now bermon-upload.service
systemctl --user restart bermon-upload.service
sleep 1
port=$(sed -n 's/^PORT=//p' .env)
curl -fsS "http://127.0.0.1:${port:-8300}/healthz"
systemctl --user is-active bermon-upload.service
EOF
