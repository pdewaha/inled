#!/usr/bin/env bash
# Enable immediate activity email dispatch (pg_net on INSERT → send-activity-email).
# leam = dev (leam-kong), exled = prod (exled-kong). See scripts/BEACON-ENVIRONMENTS.md
#
# Usage:
#   cd ~/leam/docker && source .env && bash scripts/setup-activity-email-immediate-dispatch.sh
#   cd ~/exled/docker && source .env && bash scripts/setup-activity-email-immediate-dispatch.sh

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=beacon-environments.sh
source "$SCRIPT_DIR/beacon-environments.sh"
DOCKER_DIR="${DOCKER_DIR:-$(pwd)}"
beacon_use_env_from_pwd "$DOCKER_DIR"

PSQL_USER="${PSQL_USER:-postgres}"

if [[ -f "$DOCKER_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$DOCKER_DIR/.env"
  set +a
fi

SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY:-${SUPABASE_SERVICE_ROLE_KEY:-}}"
if [[ -z "$SERVICE_ROLE_KEY" ]]; then
  echo "ERROR: Set SERVICE_ROLE_KEY (or SUPABASE_SERVICE_ROLE_KEY) in $DOCKER_DIR/.env" >&2
  exit 1
fi

find_migration() {
  local name="$1"
  local d
  for d in \
    "${MIGRATIONS_DIR:-}" \
    "$SCRIPT_DIR/../supabase-db/migrations" \
    "$SCRIPT_DIR/../../supabase-db/migrations" \
    "$DOCKER_DIR/../supabase-db/migrations" \
    "$DOCKER_DIR/../../inled/supabase-db/migrations"; do
    [[ -n "$d" && -f "$d/$name" ]] && echo "$d/$name" && return 0
  done
  return 1
}

compose() {
  if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
    docker compose -f "$DOCKER_DIR/docker-compose.yml" "$@"
  else
    docker compose "$@"
  fi
}

echo "==> Activity email immediate dispatch ($BEACON_ENV)"
echo "    Function URL: $ACTIVITY_EMAIL_FUNCTION_URL"
echo "    Public API:   $PUBLIC_URL"
echo "    Database:     $POSTGRES_DB (service: $DB_CONTAINER)"
echo "    Compose dir:  $DOCKER_DIR"

run_psql() {
  local user="${1:-$PSQL_USER}"
  shift
  compose exec -T "$DB_CONTAINER" psql -U "$user" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"
}

# Apply SQL file; on "must be owner" for functions, retry as each login superuser.
apply_sql_file() {
  local file="$1"
  local user
  if run_psql "$PSQL_USER" < "$file" 2>/tmp/psql_apply.err; then
    return 0
  fi
  if ! grep -qE "must be owner of function|permission denied for table" /tmp/psql_apply.err 2>/dev/null; then
    cat /tmp/psql_apply.err >&2
    return 1
  fi
  echo "WARN: $PSQL_USER lacks rights; trying superuser roles..." >&2
  while IFS= read -r user; do
    user="$(echo "$user" | tr -d '[:space:]')"
    [[ -z "$user" ]] && continue
    echo "    trying psql -U $user ..."
    if run_psql "$user" < "$file" 2>/tmp/psql_apply.err; then
      echo "    applied as $user"
      return 0
    fi
  done < <(run_psql "$PSQL_USER" -tAc \
    "SELECT rolname FROM pg_roles WHERE rolsuper AND rolcanlogin AND rolname NOT LIKE 'pg\\_%' ORDER BY rolname")
  cat /tmp/psql_apply.err >&2
  echo "" >&2
  echo "If all failed: open Supabase Dashboard → SQL and run DROP + CREATE from:" >&2
  echo "  supabase-db/migrations/012_activity_email_dispatch_config_table.sql" >&2
  return 1
}

apply_embedded_schema() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOSQL'
CREATE TABLE IF NOT EXISTS inled_activity_email_dispatch_config (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  function_url text NOT NULL,
  service_role_key text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE inled_activity_email_dispatch_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON inled_activity_email_dispatch_config FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON inled_activity_email_dispatch_config TO postgres;
GRANT SELECT, INSERT, UPDATE, DELETE ON inled_activity_email_dispatch_config TO supabase_admin;

DROP FUNCTION IF EXISTS public.inled_dispatch_activity_email_outbox() CASCADE;

CREATE FUNCTION public.inled_dispatch_activity_email_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $fn$
DECLARE
  fn_url text;
  sr_key text;
BEGIN
  SELECT c.function_url, c.service_role_key INTO fn_url, sr_key
  FROM inled_activity_email_dispatch_config c WHERE c.id = 1;
  IF fn_url IS NULL OR fn_url = '' OR sr_key IS NULL OR sr_key = '' THEN
    RAISE WARNING 'activity_email_outbox %: immediate dispatch not configured.', NEW.id;
    RETURN NEW;
  END IF;
  PERFORM net.http_post(
    url := fn_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || sr_key,
      'apikey', sr_key
    ),
    body := jsonb_build_object('outbox_id', NEW.id::text),
    timeout_milliseconds := 300000
  );
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'activity_email_outbox %: pg_net dispatch failed: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$fn$;

ALTER FUNCTION public.inled_dispatch_activity_email_outbox() OWNER TO postgres;
EOSQL
  apply_sql_file "$tmp"
  rm -f "$tmp"
}

echo "==> pg_net extension"
run_psql "$PSQL_USER" -c "CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;"

M012="$(find_migration 012_activity_email_dispatch_config_table.sql || true)"

if [[ -n "$M012" ]]; then
  echo "==> Applying $M012"
  apply_sql_file "$M012"
else
  echo "==> Applying embedded schema (012 migration file not on server)"
  apply_embedded_schema
fi

echo "==> Saving dispatch config (config table row id=1)"
escaped_url="${ACTIVITY_EMAIL_FUNCTION_URL//\'/\'\'}"
escaped_key="${SERVICE_ROLE_KEY//\'/\'\'}"
run_psql "$PSQL_USER" <<SQL
INSERT INTO inled_activity_email_dispatch_config (id, function_url, service_role_key, updated_at)
VALUES (1, '${escaped_url}', '${escaped_key}', now())
ON CONFLICT (id) DO UPDATE SET
  function_url = EXCLUDED.function_url,
  service_role_key = EXCLUDED.service_role_key,
  updated_at = now();
SQL

echo "==> Ensure dispatch trigger on activity_email_outbox"
TRIG_TMP="$(mktemp)"
cat >"$TRIG_TMP" <<'EOSQL'
DROP TRIGGER IF EXISTS trg_dispatch_activity_email_outbox ON activity_email_outbox;
CREATE TRIGGER trg_dispatch_activity_email_outbox
  AFTER INSERT ON activity_email_outbox
  FOR EACH ROW
  WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION inled_dispatch_activity_email_outbox();
EOSQL
M013="$(find_migration 013_activity_email_dispatch_trigger.sql || true)"
if [[ -n "$M013" ]]; then
  apply_sql_file "$M013" || apply_sql_file "$TRIG_TMP"
else
  apply_sql_file "$TRIG_TMP"
fi
rm -f "$TRIG_TMP"

echo "==> Verify"
run_psql "$PSQL_USER" -c "SELECT id, function_url, left(service_role_key, 20) || '…' AS key_prefix, updated_at FROM inled_activity_email_dispatch_config;"
run_psql "$PSQL_USER" -c "SELECT proname, pg_get_userbyid(proowner) AS owner FROM pg_proc WHERE proname = 'inled_dispatch_activity_email_outbox';"
run_psql "$PSQL_USER" -c "SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = 'public.activity_email_outbox'::regclass AND NOT tgisinternal;"

echo ""
echo "Done. New outbox rows should POST to send-activity-email immediately."
echo "  SELECT id, status, sent_at FROM activity_email_outbox ORDER BY created_at DESC LIMIT 5;"
echo ""
echo "Wrong Kong host? Re-run:"
echo "  cd ~/leam/docker && bash $0   # dev"
echo "  cd ~/exled/docker && bash $0  # prod"
