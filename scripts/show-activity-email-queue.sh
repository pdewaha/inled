#!/bin/bash
# Show activity_email_outbox. Auto: leam=dev, exled=prod

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=beacon-environments.sh
. "$SCRIPT_DIR/beacon-environments.sh"
DOCKER_DIR="${DOCKER_DIR:-$(dirname "$SCRIPT_DIR")}"
beacon_use_env_from_pwd "$DOCKER_DIR" || exit 1
cd "$DOCKER_DIR"

echo "==> $BEACON_ENV queue"
docker compose exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -c \
  "SELECT id,status,sent_at,left(coalesce(error_message,''),60) FROM activity_email_outbox ORDER BY created_at DESC LIMIT 10;"
docker compose exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -c \
  "SELECT status,count(*) FROM activity_email_outbox GROUP BY status;"
