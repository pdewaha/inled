#!/bin/bash
# Morning unhealthy-expectations digest. Auto: leam=dev, exled=prod (BEACON-ENVIRONMENTS.md)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=beacon-environments.sh
. "$SCRIPT_DIR/beacon-environments.sh"
DOCKER_DIR="${DOCKER_DIR:-$(dirname "$SCRIPT_DIR")}"
beacon_use_env_from_pwd "$DOCKER_DIR" || exit 1
cd "$DOCKER_DIR"
[ -f .env ] && set -a && . ./.env && set +a

KEY="${SERVICE_ROLE_KEY:-$SUPABASE_SERVICE_ROLE_KEY}"
URL="${PUBLIC_URL}/functions/v1/send-unhealthy-digest"
ANON="${ANON_KEY:-$KEY}"
[ -n "$KEY" ] || { echo "Missing SERVICE_ROLE_KEY in .env"; exit 1; }

DRY="${1:-}"
BODY='{"run":true}'
if [ "$DRY" = "--dry-run" ]; then
  BODY='{"dry_run":true}'
fi

echo "==> Morning digest $BEACON_ENV: POST $URL ($BODY)"
CODE=$(curl -sS -w "%{http_code}" -o /tmp/morning-digest-out.json -X POST "$URL" \
  -H "apikey: $ANON" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" --data-binary "$BODY")
echo "HTTP $CODE"
cat /tmp/morning-digest-out.json
echo
