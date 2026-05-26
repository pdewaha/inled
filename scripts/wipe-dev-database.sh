#!/usr/bin/env bash
# Wipe the leam (dev) database so you can restart onboarding and ledger data from scratch.
#
# Removes: all app rows (companies → expectations, people, invites, …), auth users,
#          pending activity-email outbox, and storage objects in the "storage" bucket.
# Keeps: schema, RLS, functions/triggers, inled_activity_email_dispatch_config (SMTP URL/key).
#
# Usage (on beacon dev):
#   cd ~/leam/docker && source .env
#   bash scripts/wipe-dev-database.sh
#   bash scripts/wipe-dev-database.sh --yes          # skip interactive confirm
#   bash scripts/wipe-dev-database.sh --reapply-dispatch  # also refresh pg_net dispatch config
#
# CRLF (Windows) breaks ./script on Linux. On beacon once: sed -i 's/\r$//' scripts/*.sh
# Or: bash scripts/fix-scripts-on-beacon.sh
#
# Safety: refuses exled/prod unless you pass --allow-prod and type the environment name.

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=beacon-environments.sh
source "$SCRIPT_DIR/beacon-environments.sh"

DOCKER_DIR="${DOCKER_DIR:-$(pwd)}"
SKIP_CONFIRM=0
ALLOW_PROD=0
REAPPLY_DISPATCH=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) SKIP_CONFIRM=1 ;;
    --allow-prod) ALLOW_PROD=1 ;;
    --reapply-dispatch) REAPPLY_DISPATCH=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

beacon_use_env_from_pwd "$DOCKER_DIR"

if [[ "$BEACON_ENV" == "exled" && "$ALLOW_PROD" -ne 1 ]]; then
  echo "ERROR: This script targets dev (leam) only." >&2
  echo "  cd ~/leam/docker && bash scripts/wipe-dev-database.sh" >&2
  echo "  To wipe prod you must pass --allow-prod and confirm interactively." >&2
  exit 1
fi

if [[ -f "$DOCKER_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$DOCKER_DIR/.env"
  set +a
fi

POSTGRES_DB="${POSTGRES_DB:-postgres}"
PSQL_USER="${PSQL_USER:-postgres}"

compose() {
  if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
    docker compose -f "$DOCKER_DIR/docker-compose.yml" "$@"
  else
    docker compose "$@"
  fi
}

run_psql() {
  local user="${1:-$PSQL_USER}"
  shift
  compose exec -T "$DB_CONTAINER" psql -U "$user" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"
}

# Migrations may create sequences as supabase_admin; RESTART IDENTITY needs sequence
# owner. Wipe uses TRUNCATE without RESTART IDENTITY; retry as superuser roles if needed.
run_psql_wipe() {
  local sql_file="$1"
  local user
  if run_psql "$PSQL_USER" < "$sql_file" 2>/tmp/wipe_psql.err; then
    return 0
  fi
  if ! grep -qE 'must be owner|permission denied|insufficient privilege' /tmp/wipe_psql.err 2>/dev/null; then
    cat /tmp/wipe_psql.err >&2
    return 1
  fi
  echo "WARN: $PSQL_USER lacks rights; trying superuser roles…" >&2
  for user in supabase_admin postgres; do
    [[ "$user" == "$PSQL_USER" ]] && continue
    echo "    trying psql -U $user …" >&2
    if run_psql "$user" < "$sql_file" 2>/tmp/wipe_psql.err; then
      echo "    applied as $user" >&2
      return 0
    fi
  done
  cat /tmp/wipe_psql.err >&2
  return 1
}

WIPE_APP_SQL="$(mktemp)"
WIPE_AUTH_SQL="$(mktemp)"
WIPE_STORAGE_SQL="$(mktemp)"
trap 'rm -f "$WIPE_APP_SQL" "$WIPE_AUTH_SQL" "$WIPE_STORAGE_SQL"' EXIT

cat > "$WIPE_APP_SQL" <<'SQL'
BEGIN;

-- No RESTART IDENTITY: sequences may be owned by supabase_admin after Dashboard migrations.
TRUNCATE TABLE public.companies CASCADE;
TRUNCATE TABLE public.activity_email_outbox;

COMMIT;
SQL

cat > "$WIPE_AUTH_SQL" <<'SQL'
BEGIN;
TRUNCATE TABLE auth.users CASCADE;
COMMIT;
SQL

cat > "$WIPE_STORAGE_SQL" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) THEN
    RETURN;
  END IF;

  -- Supabase blocks direct DELETE unless this session flag is set (storage.protect_delete).
  PERFORM set_config('storage.allow_delete_query', 'true', true);

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'prefixes'
  ) THEN
    DELETE FROM storage.prefixes WHERE bucket_id = 'storage';
  END IF;

  DELETE FROM storage.objects WHERE bucket_id = 'storage';
END $$;
SQL

echo "==> Wipe database ($BEACON_ENV)"
echo "    Compose dir:  $DOCKER_DIR"
echo "    Database:     $POSTGRES_DB (service: $DB_CONTAINER)"
echo "    Public API:   $PUBLIC_URL"
echo ""
echo "This will DELETE:"
echo "  - All companies, people, expectations, messages, invites, tags, captures"
echo "  - All auth.users (everyone must sign in again with OTP)"
echo "  - All files in storage bucket \"storage\""
echo "  - Pending rows in activity_email_outbox"
echo ""
echo "This will KEEP schema, migrations, RLS, triggers, and dispatch config."

if [[ "$SKIP_CONFIRM" -ne 1 ]]; then
  if [[ "$BEACON_ENV" == "exled" ]]; then
    echo ""
    echo "WARNING: You are about to wipe PRODUCTION ($PUBLIC_URL)."
    read -r -p "Type exled to continue: " typed
    if [[ "$typed" != "exled" ]]; then
      echo "Aborted."
      exit 1
    fi
  else
    read -r -p "Type wipe to continue: " typed
    if [[ "$typed" != "wipe" ]]; then
      echo "Aborted."
      exit 1
    fi
  fi
fi

echo ""
echo "==> Truncating app tables…"
run_psql_wipe "$WIPE_APP_SQL"

echo "==> Clearing auth users…"
run_psql_wipe "$WIPE_AUTH_SQL"

echo "==> Clearing storage objects (bucket \"storage\")…"
run_psql_wipe "$WIPE_STORAGE_SQL"

STORAGE_STORED="$DOCKER_DIR/volumes/storage/stored"
if [[ -d "$STORAGE_STORED" ]]; then
  echo "==> Removing on-disk files under volumes/storage/stored …"
  find "$STORAGE_STORED" -mindepth 1 -delete 2>/dev/null || rm -rf "${STORAGE_STORED:?}/"* 2>/dev/null || true
fi

echo "==> Done. Row counts:"
run_psql "$PSQL_USER" -c \
  "SELECT 'companies' AS tbl, count(*) FROM public.companies
   UNION ALL SELECT 'people', count(*) FROM public.people
   UNION ALL SELECT 'expectations', count(*) FROM public.expectations
   UNION ALL SELECT 'auth.users', count(*) FROM auth.users
   UNION ALL SELECT 'activity_email_outbox', count(*) FROM public.activity_email_outbox
   UNION ALL SELECT 'storage.objects (storage bucket)', count(*) FROM storage.objects WHERE bucket_id = 'storage';"

if [[ "$REAPPLY_DISPATCH" -eq 1 ]]; then
  echo ""
  echo "==> Re-applying activity-email dispatch config…"
  bash "$SCRIPT_DIR/setup-activity-email-immediate-dispatch.sh"
fi

echo ""
echo "Database is empty. Sign up again in the app to create a fresh company space."
