#!/usr/bin/env bash
# Self-hosted Supabase: fix permissions + recreate functions after you copy files
# into COMPOSE_DIR/volumes/functions/ (scp, rsync, etc.).
#
# Usage:
#   bash scripts/setup-beacon-edge-functions.sh /root/leam/docker
#
# Optional second arg = local repo supabase/functions (copy FROM dev machine):
#   bash scripts/setup-beacon-edge-functions.sh /root/leam/docker /path/to/inled/supabase/functions
#
# Expected layout (what the edge runtime mounts):
#   volumes/functions/main/index.ts
#   volumes/functions/hello/index.ts          (optional smoke test)
#   volumes/functions/send-activity-email/index.ts

set -euo pipefail

COMPOSE_DIR="${1:-/root/leam/docker}"
SOURCE_DIR="${2:-}"

# Pass the compose dir whose Kong serves your API (be.exled.app may differ from leam):
#   docker inspect exled-auth --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'

VOL="$COMPOSE_DIR/volumes/functions"

# Auto source only when run from a full repo clone (scripts/ -> ../supabase/functions).
if [[ -z "$SOURCE_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CANDIDATE="$(cd "$SCRIPT_DIR/../supabase/functions" 2>/dev/null && pwd || true)"
  if [[ -n "$CANDIDATE" && -f "$CANDIDATE/send-activity-email/index.ts" ]]; then
    SOURCE_DIR="$CANDIDATE"
  fi
fi

echo "==> Compose dir: $COMPOSE_DIR"
echo "==> Deploy target: $VOL"
if [[ -n "$SOURCE_DIR" ]]; then
  echo "==> Copy from: $SOURCE_DIR"
else
  echo "==> Copy from: (none — using files already in $VOL)"
fi

mkdir -p "$VOL/main" "$VOL/hello" "$VOL/send-activity-email" "$VOL/send-unhealthy-digest" "$VOL/send-invite-email"

install_fn() {
  local name="$1"
  local required="${2:-yes}"
  local dest="$VOL/$name/index.ts"

  if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/$name/index.ts" ]]; then
    cp "$SOURCE_DIR/$name/index.ts" "$dest"
    echo "==> $name: copied from repo"
    if [[ "$name" == "send-activity-email" ]]; then
      rm -f "$VOL/$name/deno.json" 2>/dev/null || true
    fi
    return 0
  fi

  if [[ -f "$dest" ]]; then
    echo "==> $name: already present in volume"
    return 0
  fi

  if [[ "$required" == "no" ]]; then
    echo "==> $name: skipped (optional)"
    return 0
  fi

  if [[ "$name" == "main" || "$name" == "hello" ]]; then
    echo "==> $name: downloading Supabase template..."
    curl -fsSL -o "$dest" \
      "https://raw.githubusercontent.com/supabase/supabase/master/docker/volumes/functions/$name/index.ts"
    return 0
  fi

  echo "ERROR: missing $dest"
  echo "  SCP from your PC (index.ts only — do NOT copy deno.json or smtp_native.ts):"
  echo "    scp supabase/functions/send-activity-email/index.ts root@beacon:$VOL/send-activity-email/"
  echo "    scp supabase/functions/main/index.ts root@beacon:$VOL/main/"
  echo "  Or pass repo path as 2nd argument."
  exit 1
}

install_fn main yes
install_fn hello no
install_fn send-activity-email yes
install_fn send-unhealthy-digest yes
install_fn send-invite-email yes

# Self-hosted: single index.ts only. Extra files often cause
# "could not find an appropriate entrypoint" on edge-runtime v1.71+.
SAE="$VOL/send-activity-email"
if [[ -f "$SAE/index.ts" ]] && ! grep -q 'Deno\.serve' "$SAE/index.ts" 2>/dev/null; then
  echo "WARN: $SAE/index.ts has no Deno.serve — replace with repo copy"
fi
# deno.json in this folder breaks edge-runtime v1.71 ("appropriate entrypoint").
rm -f "$SAE/smtp_native.ts" "$SAE/deno.json" "$SAE/deno.json.bak" "$SAE/deno.lock" 2>/dev/null || true
if [[ -f "$SAE/deno.json" ]]; then
  echo "ERROR: $SAE/deno.json still present — remove it (scp index.ts only)"
  exit 1
fi

# drwx------ on the function dir makes the worker unable to read index.ts.
chmod -R a+rX "$VOL"
find "$VOL" -type f -name '*.ts' -exec chmod 644 {} +

echo "==> Layout:"
ls -la "$VOL"
ls -la "$VOL/main" "$VOL/send-activity-email" "$VOL/send-unhealthy-digest" 2>/dev/null || true

cd "$COMPOSE_DIR"
docker compose up -d --force-recreate functions

echo "==> Wait for functions..."
sleep 5
docker compose ps functions || docker ps | grep -i edge

echo ""
echo "==> Inside container (expect drwxr-xr-x, only index.ts ~14k):"
docker compose exec -T functions ls -la /home/deno/functions/send-activity-email/ 2>/dev/null || true

if [[ -f "$COMPOSE_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "$COMPOSE_DIR/.env" && set +a
  echo ""
  echo "==> Health check:"
  curl -sS "https://be.exled.app/functions/v1/send-activity-email?health=1" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" || true
  echo ""
fi

echo ""
echo "==> Manual test:"
echo "  source .env"
echo "  curl -s 'https://be.exled.app/functions/v1/hello'"
echo "  curl -s 'https://be.exled.app/functions/v1/send-activity-email?health=1' \\"
echo "    -H \"apikey: \$ANON_KEY\" -H \"Authorization: Bearer \$SERVICE_ROLE_KEY\""

echo ""
echo "==> functions service env (docker-compose / .env):"
echo "  SUPABASE_URL=http://kong:8000"
echo "  SUPABASE_SERVICE_ROLE_KEY=\${SERVICE_ROLE_KEY}"
echo "  SMTP_HOSTNAME=smtp.openxchange.eu"
echo "  SMTP_PORT=587"
echo "  SMTP_SECURE=false"
echo "  SMTP_USERNAME=..."
echo "  SMTP_PASSWORD=..."
echo "  SMTP_FROM=..."
echo "  EXLED_APP_URL=https://be.exled.app"
echo "  ALLOW_DEBUG_TEST_EMAIL=true   # debug menu: Send test SMTP email"
echo ""
echo "==> Immediate activity email (send on outbox INSERT):"
echo "  cd ~/leam/docker && source .env"
echo "  bash scripts/setup-activity-email-immediate-dispatch.sh"
echo "  # If Kong service is leam-kong: KONG_HOST=leam-kong bash scripts/setup-activity-email-immediate-dispatch.sh"
echo "  EDGE_WORKER_TIMEOUT_MS=600000  # optional; main default is 10m for npm+SMTP"
