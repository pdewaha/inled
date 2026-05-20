# Self-hosted: deploy & test activity email (no Supabase CLI)

## A. Apply the database migration

1. SSH tunnel (from README):
   ```powershell
   ssh -L 5433:127.0.0.1:5436 root@beacon.tauworks.org
   ```
2. Run `supabase-db/migrations/010_activity_email_notifications.sql` in:
   - Supabase Studio → SQL, or
   - `psql "postgresql://postgres:PASSWORD@127.0.0.1:5433/postgres" -f supabase-db/migrations/010_activity_email_notifications.sql`

3. Sanity check:
   ```powershell
   psql "postgresql://..." -f supabase-db/scripts/test_activity_email.sql
   ```

## B. Enqueue a row (real app or SQL)

**In the app (easiest):**

1. Sign in as user A.
2. Ensure user B has `people.email` set (People / invite flow).
3. Create or **publish** an expectation/talking point that targets B (not a private shadow talking point draft).
4. In SQL:
   ```sql
   SELECT id, status, recipient_email, activity_line
   FROM activity_email_outbox ORDER BY created_at DESC LIMIT 5;
   ```
   You should see `status = pending`.

**If nothing appears:** recipient has no email, or the event was shadow-only prep (no email until publish).

## C. Deploy the Edge Function on Docker (manual)

On **beacon**, copy into the **compose volume** (what Docker mounts). This is **not** `supabase/functions` on the server unless you keep a full git clone there:

```text
/root/leam/docker/volumes/functions/send-activity-email/index.ts   ← scp from your PC
/root/leam/docker/volumes/functions/main/index.ts                 ← required router
```

From your dev machine (repo root):

```bash
scp supabase/functions/main/index.ts root@beacon:~/leam/docker/volumes/functions/main/
scp supabase/functions/send-activity-email/index.ts root@beacon:~/leam/docker/volumes/functions/send-activity-email/
ssh root@beacon 'bash -s' < scripts/setup-beacon-edge-functions.sh   # or copy script and run on server
```

The function uses **`npm:nodemailer`** (Deno). The **functions** container needs outbound **HTTPS to `registry.npmjs.org`** on first load so the runtime can fetch the package; after that it is cached in the worker cache.

0. **Required:** `volumes/functions/main/index.ts` (Supabase router). Without it the
   `functions` container crash-loops with `main worker boot error … entrypoint`.
   Copy from this repo: `supabase/functions/main/` (and optionally `hello/`).

1. Copy the **whole folder** (must contain `index.ts` at this exact path):
   ```text
   volumes/functions/main/index.ts                  (required router)
   volumes/functions/send-activity-email/index.ts
   volumes/functions/hello/index.ts                 (optional smoke test)
   ```
   **Permissions:** the functions container user must read the folder. If you see `drwx------`, fix:
   ```bash
   chmod -R a+rX /root/leam/docker/volumes/functions/
   ```
   Compare with `hello`: `ls -la volumes/functions/hello/`
   ```bash
   cp /path/to/inled/supabase/functions/send-activity-email/index.ts \
     /path/to/supabase/docker/volumes/functions/send-activity-email/
   ```
   Wrong layouts that cause `could not find an appropriate entrypoint`:
   - `volumes/functions/send-activity-email.ts` (file, not folder)
   - `volumes/functions/index.ts` (missing function name folder)
   - only `main.ts` without `index.ts`

2. Add env to the **functions** service (same values as GoTrue SMTP), e.g. in `.env` or `docker-compose.yml`:
   ```env
   SMTP_HOSTNAME=smtp.open-xchange.com
   SMTP_PORT=587
   SMTP_SECURE=false
   SMTP_USERNAME=...
   SMTP_PASSWORD=...
   SMTP_FROM=...
   SMTP_SENDER_NAME=Exled
   EXLED_APP_URL=https://be.exled.app
   ```

3. Restart functions (and Kong if needed):
   ```bash
   docker compose restart functions
   ```

4. Smoke test the route:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" \
     https://be.exled.app/functions/v1/send-activity-email \
     -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
     -H "Content-Type: application/json" \
     -d '{"process_pending":true,"limit":1}'
   ```
   Expect `200` or `207` (not `404`).

## D. Send pending emails (Windows on your PC)

```powershell
$env:SUPABASE_URL = "https://be.exled.app"
$env:SUPABASE_SERVICE_ROLE_KEY = "<SERVICE_ROLE_JWT from beacon .env>"

# Drain all pending
.\scripts\invoke-send-activity-email.ps1 -ProcessPending

# Or one row
.\scripts\invoke-send-activity-email.ps1 -OutboxId "00000000-0000-0000-0000-000000000000"
```

Check SQL again — `status` should be `sent` and `sent_at` set. Check the recipient inbox (and spam).

## E. Automatic delivery (after manual test works)

Pick one:

1. **Database Webhook** (Studio → Database → Webhooks):  
   Table `activity_email_outbox`, Insert → POST  
   `https://be.exled.app/functions/v1/send-activity-email`  
   Body: `{"outbox_id":"{{ record.id }}"}`  
   Header: `Authorization: Bearer <SERVICE_ROLE_KEY>`

2. **Cron on beacon** every 2 minutes:
   ```bash
   */2 * * * * curl -s -X POST https://be.exled.app/functions/v1/send-activity-email \
     -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
     -H "Content-Type: application/json" \
     -d '{"process_pending":true,"limit":30}'
   ```

3. **pg_net** (migration trigger): set DB settings `app.activity_email_function_url` and `app.service_role_key` if you use immediate dispatch.

## F. Troubleshooting

| Symptom | Fix |
|--------|-----|
| No outbox rows | Migration not applied; recipient missing `people.email`; shadow talking point not published |
| `pending` forever | Function not deployed / webhook not configured / cron not running |
| `failed` + SMTP error | Wrong host/port/`SMTP_SECURE`; try 465 + `true`; match GoTrue settings exactly |
| 404 on `/functions/v1/...` | Functions container not running or Kong route missing |
| 500 `could not find an appropriate entrypoint` | **`hello` OK but this function fails:** remove `smtp_native.ts`, `deno.json`, `deno.json.bak` from `volumes/functions/send-activity-email/`; scp fresh single-file `index.ts` (~14 KB, must contain `Deno.serve`); recreate `functions`. Wrong layout: `send-activity-email.ts` as a file instead of folder. |
| 503 `name resolution failed` | **DNS inside `functions` container** — cannot resolve `SMTP_HOSTNAME` and/or `kong`. Copy **exact** `GOTRUE_SMTP_*` into functions env; add `dns: [8.8.8.8, 1.1.1.1]` under `functions` in compose; test health URL below |
| `wall clock duration` / `early termination` after nodemailer | **Router** `main/index.ts` `workerTimeoutMs` too low. Redeploy `main/index.ts` (default **10 minutes**) or set `EDGE_WORKER_TIMEOUT_MS=900000` on **functions** and recreate. Mail may still send; the HTTP response is cut off. |
| 502 after ~60s on test email | SMTP hang from **functions** container — `docker compose logs functions --tail 80` (look for `[smtp]` lines). Copy `GOTRUE_SMTP_*` → `SMTP_*` on functions service. Redeploy `index.ts` with timeouts. |
| 400 `Provide "test_email"…` + `"receivedKeys":[]` | **Body never reached the function** (Kong/nginx) or **invalid JSON** (smart quotes, truncated `-d`). Ensure `Content-Type: application/json`. Redeploy `send-activity-email/index.ts` (clear empty/JSON errors). Check trace `http_body_in.byteLen`. Router must use **`worker.fetch(req)`** only — not `req.clone()` or a rebuilt `Request`. |
| 400 `Invalid JSON body` … `position 34` / `after JSON` | Extra characters after `}` — often **`##` pasted inside** `-d '...##'`. Use `-d '{"test_email":"you@example.com"}'` with **nothing after the closing `'`**. Response includes `tailPreview` (last 12 chars). |
| 400 `Empty request body` | Missing `-d` or empty POST body. |
| `BadResource` / `streamRid` / `main worker has been destroyed` | Router must **`worker.fetch(req)`** (upstream Supabase pattern). Do **not** use `req.clone()` or `new Request(..., { body: arrayBuffer })` — both break self-hosted edge-runtime body forwarding. |

**Health check (from beacon or your PC):**

```bash
curl -s "https://be.exled.app/functions/v1/send-activity-email?health=1" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY"
```

Returns `smtp_tcp: ok` / `kong_reachable: ok` when DNS and env are correct.

**Structured logs** (every request): `docker compose logs -f functions | grep send-activity-email-trace` — JSON lines with `event` (`smtp_send_begin`, `postgrest_error`, `handler_error`, …). No passwords.

**Diagnose in HTTP** (redacted env snapshot): append `&diagnose=1` to the health URL — response includes `diagnose: { supabaseUrlRaw, supabaseUrlInternal, mailFrom, … }`.

**Service role key:** on beacon, usually `SERVICE_ROLE_KEY` or `SUPABASE_SERVICE_ROLE_KEY` in the Supabase `.env` (never commit it).
