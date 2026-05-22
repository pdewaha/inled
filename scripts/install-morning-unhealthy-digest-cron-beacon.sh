#!/bin/bash
# Daily morning unhealthy-expectations digest. leam / exled — see BEACON-ENVIRONMENTS.md
#
# Default: 07:00 Europe/Berlin (adjust CRON_TZ or hour if your server uses UTC only).

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=beacon-environments.sh
. "$SCRIPT_DIR/beacon-environments.sh"

if [ -n "${1:-}" ]; then
  beacon_use_env "$1"
else
  beacon_use_env_from_pwd "${DOCKER_DIR:-$HOME/exled/docker}" || exit 1
fi

SEND="$DOCKER_DIR/scripts/send-morning-unhealthy-digest.sh"
LOG="${CRON_LOG:-/var/log/${BEACON_ENV}-morning-unhealthy-digest.log}"
CRON_LINE="0 7 * * * cd $DOCKER_DIR && set -a && . ./.env && set +a && /bin/bash $SEND >> $LOG 2>&1"

(
  crontab -l 2>/dev/null | grep -v send-morning-unhealthy-digest || true
  echo "CRON_TZ=Europe/Berlin"
  echo "$CRON_LINE"
) | crontab -

echo "Cron installed for $BEACON_ENV (07:00 Europe/Berlin)."
echo "Log: $LOG"
echo "Dry run: cd $DOCKER_DIR && source .env && bash $SEND --dry-run"
echo "Send now: cd $DOCKER_DIR && source .env && bash $SEND"
