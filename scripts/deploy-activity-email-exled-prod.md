# Activity email on **exled** (prod) — copy from working **leam** (test)

**Canonical map:** [BEACON-ENVIRONMENTS.md](BEACON-ENVIRONMENTS.md) — scripts auto-pick from `~/leam/docker` vs `~/exled/docker`.

| | **leam (dev)** | **exled (prod)** |
|---|----------------|------------------|
| Compose dir | `~/leam/docker` | `~/exled/docker` |
| Kong (internal) | `http://leam-kong:8000` | `http://exled-kong:8000` |
| Public API | `https://leam.tauworks.org` | `https://be.exled.app` |
| App links in mail | `https://leam.tauworks.org` | `https://be.exled.app` |

**Never use bare `kong`** — on this host only `leam-kong` and `exled-kong` exist.

---

## 1. Database (exled Postgres)

Tunnel or Studio pointed at **exled** DB (not leam). Apply in order:

1. `supabase-db/migrations/010_activity_email_notifications.sql`
2. `supabase-db/migrations/012_activity_email_dispatch_config_table.sql`
3. `supabase-db/migrations/013_activity_email_dispatch_trigger.sql`

From PC (adjust port/password for **exled** tunnel):

```bash
psql "postgresql://postgres:PASSWORD@127.0.0.1:PORT/postgres" \
  -f supabase-db/migrations/010_activity_email_notifications.sql
psql "postgresql://..." -f supabase-db/migrations/012_activity_email_dispatch_config_table.sql
psql "postgresql://..." -f supabase-db/migrations/013_activity_email_dispatch_trigger.sql
```

Or paste those three files in **exled** Supabase Studio → SQL.

Sanity:

```sql
SELECT count(*) FROM activity_email_outbox;  -- table exists
SELECT tgname FROM pg_trigger WHERE tgrelid = 'activity_email_outbox'::regclass AND NOT tgisinternal;
-- expect: trg_dispatch_activity_email_outbox
```

---

## 2. Edge functions (exled volumes)

From repo root on your PC:

```bash
scp supabase/functions/main/index.ts \
  root@beacon:~/exled/docker/volumes/functions/main/
scp supabase/functions/send-activity-email/index.ts \
  root@beacon:~/exled/docker/volumes/functions/send-activity-email/
```

On beacon:

```bash
cd ~/exled/docker
chmod -R a+rX volumes/functions/
docker compose up -d --force-recreate functions
```

Remove bad layouts if present:

```bash
rm -f volumes/functions/send-activity-email/deno.json \
      volumes/functions/send-activity-email/smtp_native.ts
```

---

## 3. Functions container env (exled)

On the **exled** `functions` service, set the same SMTP as GoTrue (copy from `docker compose exec auth printenv | grep SMTP` on **exled**):

```env
SUPABASE_URL=http://exled-kong:8000
SUPABASE_SERVICE_ROLE_KEY=<exled SERVICE_ROLE_KEY from ~/exled/docker/.env>
SMTP_HOSTNAME=...
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_FROM=...
EXLED_APP_URL=https://be.exled.app
ALLOW_DEBUG_TEST_EMAIL=false
EDGE_WORKER_TIMEOUT_MS=600000
```

Then: `docker compose up -d --force-recreate functions`

---

## 4. Immediate dispatch (pg_net + config table)

Copy scripts from repo to exled (once), fix line endings, run setup:

```bash
# From PC — copy whole scripts folder or at least:
scp scripts/setup-activity-email-immediate-dispatch.sh \
    scripts/check-activity-email-dispatch.sh \
    scripts/drain-activity-email-queue.sh \
    scripts/show-activity-email-queue.sh \
    scripts/fix-scripts-on-beacon.sh \
    root@beacon:~/exled/docker/scripts/

# On beacon
cd ~/exled/docker
sed -i 's/\r$//' scripts/*.sh
source .env
cd ~/exled/docker && source .env
bash scripts/setup-activity-email-immediate-dispatch.sh
# (uses exled-kong automatically)
```

---

## 5. Verify prod

```bash
cd ~/exled/docker
source .env

curl -sS "https://be.exled.app/functions/v1/send-activity-email?health=1" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}"

bash scripts/check-activity-email-dispatch.sh
```

Trigger real activity in the **prod** app (user with `people.email`), then:

```bash
bash scripts/show-activity-email-queue.sh
```

Expect new row → `sent` within seconds. Section 3 of check script must show `trg_dispatch_activity_email_outbox`.

---

## 6. Optional: cron backup (exled)

```bash
cd ~/exled/docker
DOCKER_DIR=~/exled/docker \
  ACTIVITY_EMAIL_CRON_LOG=/var/log/exled-activity-email.log \
  bash scripts/install-activity-email-cron-beacon.sh
```

Use a **different log path** than leam (`/var/log/leam-activity-email.log`) so the two envs do not clash.

---

## Do not mix leam and exled

- Run migrations against **exled** DB only.
- `setup-activity-email-immediate-dispatch.sh` must use **`exled-kong`** and **exled** `.env` keys.
- Health/drain URLs use **`https://be.exled.app`**, not `leam.tauworks.org`.

Leam can stay as-is for test; repeat the same steps with the table above for prod.
