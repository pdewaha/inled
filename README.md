# exled

A new Flutter project.

## Activity email notifications (offline bell → inbox)

When changelog or @mention rows would appear in the activity bell, the database enqueues
`activity_email_outbox` and the **`send-activity-email`** Edge Function sends email via SMTP
(same Open-Xchange mailbox as GoTrue OTP).

1. Run migration `supabase-db/migrations/010_activity_email_notifications.sql`.
2. Deploy the function and set secrets (Cloud) or copy to Docker volumes (self-hosted):
   - Quick: [scripts/ACTIVITY_EMAIL.md](scripts/ACTIVITY_EMAIL.md)
   - Beacon test (leam): `bash scripts/setup-beacon-edge-functions.sh ~/leam/docker`
   - Beacon prod (exled): [scripts/deploy-activity-email-exled-prod.md](scripts/deploy-activity-email-exled-prod.md)
   - Details: [scripts/deploy-send-activity-email-selfhosted.md](scripts/deploy-send-activity-email-selfhosted.md)
3. Enable **immediate send on queue**: migration `012` + `scripts/setup-activity-email-immediate-dispatch.sh` (pg_net on INSERT). Optional cron / `process_pending` only for backlog.

Recipients need `people.email` set. Private prep talking points (shadow) do not email until published.

Start tunnel for postgres

ssh -L 5433:127.0.0.1:5436  root@beacon.tauworks.org   