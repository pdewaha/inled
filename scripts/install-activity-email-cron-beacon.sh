#!/bin/bash
# 1-minute cron to drain pending emails. leam / exled — see BEACON-ENVIRONMENTS.md

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=beacon-environments.sh
. "$SCRIPT_DIR/beacon-environments.sh"

if [ -n "${1:-}" ]; then
  beacon_use_env "$1"
else
  beacon_use_env_from_pwd "${DOCKER_DIR:-$HOME/leam/docker}" || exit 1
fi

DRAIN="$DOCKER_DIR/scripts/drain-activity-email-queue.sh"
LINE="* * * * * cd $DOCKER_DIR && set -a && . ./.env && set +a && /bin/bash $DRAIN >> $CRON_LOG 2>&1"
( crontab -l 2>/dev/null | grep -v drain-activity-email-queue || true; echo "$LINE" ) | crontab -
echo "Cron installed for $BEACON_ENV. Log: $CRON_LOG"
echo "Test: cd $DOCKER_DIR && source .env && bash $DRAIN"
