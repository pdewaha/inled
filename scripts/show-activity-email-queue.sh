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
  "SELECT status,count(*) AS n FROM activity_email_outbox GROUP BY status ORDER BY status;"
docker compose exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -c \
  "SELECT source_type,status,count(*) AS n FROM activity_email_outbox GROUP BY source_type,status ORDER BY 1,2;"
docker compose exec -T "$DB_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -c \
  "SELECT count(*) AS sent_last_24h FROM activity_email_outbox WHERE status='sent' AND sent_at IS NOT NULL AND sent_at >= now() - interval '24 hours';"
