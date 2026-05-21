#!/bin/bash
# Print deploy checklist. Usage: bash scripts/deploy-activity-email-to-env.sh leam|exled

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=beacon-environments.sh
. "$SCRIPT_DIR/beacon-environments.sh"
beacon_use_env "${1:?Usage: $0 leam|exled}" || exit 1

cat <<EOF
# === Activity email: $BEACON_ENV ===
cd $DOCKER_DIR && source .env
sed -i 's/\\r\$//' scripts/*.sh

# DB: migrations 010, 012, 013 (this database only)
docker compose up -d --force-recreate functions
sleep 10

bash scripts/setup-activity-email-immediate-dispatch.sh

curl -sS "$PUBLIC_URL/functions/v1/send-activity-email?health=1" \\
  -H "apikey: \${ANON_KEY}" -H "Authorization: Bearer \${SERVICE_ROLE_KEY}"

bash scripts/check-activity-email-dispatch.sh

# Internal Kong: $KONG_INTERNAL_URL
# Config must be: $ACTIVITY_EMAIL_FUNCTION_URL
EOF
