#!/bin/bash
# Drain pending activity_email_outbox. Auto: leam=dev, exled=prod (BEACON-ENVIRONMENTS.md)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=beacon-environments.sh
. "$SCRIPT_DIR/beacon-environments.sh"
DOCKER_DIR="${DOCKER_DIR:-$(dirname "$SCRIPT_DIR")}"
beacon_use_env_from_pwd "$DOCKER_DIR" || exit 1
cd "$DOCKER_DIR"
[ -f .env ] && set -a && . ./.env && set +a

KEY="${SERVICE_ROLE_KEY:-$SUPABASE_SERVICE_ROLE_KEY}"
URL="${PUBLIC_URL}/functions/v1/send-activity-email"
ANON="${ANON_KEY:-$KEY}"
[ -n "$KEY" ] || { echo "Missing SERVICE_ROLE_KEY in .env"; exit 1; }

BODY='{"process_pending":true,"limit":30}'
echo "==> Drain $BEACON_ENV: POST $URL"
CODE=$(curl -sS -w "%{http_code}" -o /tmp/drain-out.json -X POST "$URL" \
  -H "apikey: $ANON" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" --data-binary "$BODY")
echo "HTTP $CODE"
cat /tmp/drain-out.json
echo
docker compose exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -c \
  "SELECT id,status,sent_at FROM activity_email_outbox ORDER BY created_at DESC LIMIT 5;"
