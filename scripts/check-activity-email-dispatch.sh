#!/usr/bin/env bash
# Diagnose activity email on leam (dev) or exled (prod). See BEACON-ENVIRONMENTS.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=beacon-environments.sh
source "$SCRIPT_DIR/beacon-environments.sh"
DOCKER_DIR="${DOCKER_DIR:-$(pwd)}"
beacon_use_env_from_pwd "$DOCKER_DIR"

if [ -f "$DOCKER_DIR/docker-compose.yml" ]; then
  DC="docker compose -f $DOCKER_DIR/docker-compose.yml"
else
  DC="docker compose"
fi

psqlq() {
  $DC exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=0 -c "$1"
}

echo "==> Environment: $BEACON_ENV ($PUBLIC_URL)"
echo "==> 1) Outbox"
psqlq "SELECT id, status, created_at, sent_at FROM activity_email_outbox ORDER BY created_at DESC LIMIT 5;"
psqlq "SELECT status, count(*) FROM activity_email_outbox GROUP BY status;"

echo "==> 2) Dispatch config (must be $ACTIVITY_EMAIL_FUNCTION_URL)"
psqlq "SELECT id, function_url, updated_at FROM inled_activity_email_dispatch_config;"

echo "==> 3) Trigger on outbox (need trg_dispatch_activity_email_outbox)"
psqlq "SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = 'public.activity_email_outbox'::regclass AND NOT tgisinternal;"
TGCOUNT="$($DC exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.activity_email_outbox'::regclass AND tgname = 'trg_dispatch_activity_email_outbox';" 2>/dev/null | tr -d '[:space:]' || echo 0)"
if [ "$TGCOUNT" = "0" ]; then
  echo "FAIL: trigger missing — paste 013 SQL in exled Studio, or re-run setup-activity-email-immediate-dispatch.sh"
fi

echo "==> 4) pg_net"
psqlq "SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_net';"
psqlq "SELECT id, method, url FROM net.http_request_queue ORDER BY id DESC LIMIT 5;" || true
psqlq "SELECT id, status_code, error_msg, created FROM net._http_response ORDER BY created DESC LIMIT 5;" || true

echo "==> 5) Kong from db ($KONG_HOST)"
$DC exec -T "$DB_CONTAINER" sh -c "getent hosts $KONG_HOST; wget -q -O- --timeout=5 http://$KONG_HOST:8000/functions/v1/send-activity-email?health=1 | head -c 120" || true

CFG_URL="$($DC exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -tAc \
  "SELECT function_url FROM inled_activity_email_dispatch_config WHERE id=1" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$CFG_URL" ] && [ "$CFG_URL" != "$ACTIVITY_EMAIL_FUNCTION_URL" ]; then
  echo "WARN: config has $CFG_URL — run: cd $DOCKER_DIR && bash scripts/setup-activity-email-immediate-dispatch.sh"
fi
