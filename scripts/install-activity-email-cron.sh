#!/usr/bin/env bash
# Install a 2-minute cron job to send pending activity emails (no Edge Functions).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="$SCRIPT_DIR/activity-email.env"
if [[ ! -f "$ENV" ]]; then
  echo "Create $ENV from activity-email.env.example first."
  exit 1
fi
LINE="*/2 * * * * cd $SCRIPT_DIR && /usr/bin/python3 $SCRIPT_DIR/process_activity_email_outbox.py >> /var/log/exled-activity-email.log 2>&1"
( crontab -l 2>/dev/null | grep -v process_activity_email_outbox || true; echo "$LINE" ) | crontab -
echo "Installed cron. Log: /var/log/exled-activity-email.log"
echo "Test now: python3 $SCRIPT_DIR/process_activity_email_outbox.py"
