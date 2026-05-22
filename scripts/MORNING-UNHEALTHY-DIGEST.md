# Morning unhealthy-expectations digest

Daily email to each **receiver** listing **published open expectations** assigned to them that are **unhealthy** (same rules as Home **Urgent** / outbox warning icon). **Authors do not** get a digest for expectations they sent to someone else.

## Unhealthy means (expectations only)

Still open (not finished / abandoned) **and** any of:

- **Not accepted** (`status = pending`)
- **No progress defined** (`health = unknown`)
- **At risk** or **off track**
- Email also calls out **no deadline set** when `deadline_at` is null / TBD

Talking points are **not** included.

## Who gets mail

- People with `auth_user_id` + email in `people`
- **Receiver only** on **published** (`echo`) expectations — **both**:
  - **Primary receiver** (`expectations.target_person_id` — first `@` on the expectation)
  - **Co-receivers** (every other `@person` row in `expectation_mentions`)
- Each person gets **their own** morning email listing every unhealthy published expectation where they are primary **or** co-receiver (not one shared mail to primary only).
- **Not** the author unless they are also a named receiver (e.g. self-assigned).
- Private drafts (`shadow`) are excluded — nothing to act on until published

## Deploy

1. Apply migrations `017` and `018_morning_unhealthy_digest_receivers_only.sql` on the DB.
2. Deploy edge function:

```bash
bash scripts/setup-beacon-edge-functions.sh ~/exled/docker /path/to/inled/supabase/functions
```

3. Ensure `functions` service has same SMTP env as activity email (`SMTP_*`, `EXLED_APP_URL`).

## Manual test

```bash
cd ~/exled/docker && source .env
bash scripts/send-morning-unhealthy-digest.sh --dry-run
bash scripts/send-morning-unhealthy-digest.sh
```

## Cron (07:00 Europe/Berlin)

```bash
bash scripts/install-morning-unhealthy-digest-cron-beacon.sh exled
# or leam
bash scripts/install-morning-unhealthy-digest-cron-beacon.sh leam
```

## API

`POST /functions/v1/send-unhealthy-digest`

```json
{ "run": true }
```

Dry run (no SMTP):

```json
{ "dry_run": true }
```

Health: `GET .../send-unhealthy-digest?health=1`
