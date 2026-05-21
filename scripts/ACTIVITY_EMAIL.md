# Activity email (Edge Function)

The database enqueues `activity_email_outbox` (migration `010`). The **`send-activity-email`** Edge Function sends SMTP mail (same mailbox as GoTrue OTP).

## Self-hosted beacon (no Supabase CLI)

1. Apply migrations `010`–`015` (at minimum `010`, `012`, `013`, `014`, `015` for changelog mail including **Request update**), then `012_activity_email_dispatch_config_table.sql` for immediate pg_net dispatch (011 optional if 012 applied).

   **Request update:** when the author taps Request update, the app inserts `expectation_messages.type = 15`; migration `015` enqueues mail to every receiver (`target_person_id` + `expectation_mentions`) who has an email and is not the sender.

2. Copy function files into the **Docker volume** (not `supabase/functions` on the server unless you keep a full git clone there):

   SMTP is implemented with **Nodemailer** (`npm:nodemailer@6.9.16`). The **functions** container must reach **https://registry.npmjs.org** on first cold start to download the package (then cached in the runtime).

   ```text
   ~/leam/docker/volumes/functions/main/index.ts
   ~/leam/docker/volumes/functions/send-activity-email/index.ts
   ```

   From your PC (repo root):

   ```bash
   scp supabase/functions/main/index.ts root@beacon:~/leam/docker/volumes/functions/main/
   scp supabase/functions/send-activity-email/index.ts root@beacon:~/leam/docker/volumes/functions/send-activity-email/
   ```

   Do **not** copy `deno.json` or `smtp_native.ts` — `deno.json` causes `could not find an appropriate entrypoint` on self-hosted edge-runtime v1.71.

3. Fix permissions and recreate the container:

   ```bash
   bash scripts/setup-beacon-edge-functions.sh ~/leam/docker
   ```

   The script uses **what is already in `volumes/functions/`**. It only copies from `supabase/functions` if you pass that path as a 2nd argument or run from a full repo clone on the server.

4. Set env on the **functions** service (match GoTrue / `GOTRUE_SMTP_*`):

   ```env
   SUPABASE_URL=http://kong:8000
   SUPABASE_SERVICE_ROLE_KEY=<same as SERVICE_ROLE_KEY in .env>
   SMTP_HOSTNAME=smtp.openxchange.eu
   SMTP_PORT=587
   SMTP_SECURE=false
   SMTP_USERNAME=...
   SMTP_PASSWORD=...
   SMTP_FROM=ExLed <a@exled.app>
   # Or bare email + name: SMTP_FROM=a@exled.app and SMTP_SENDER_NAME=ExLed
   # Or label only: SMTP_FROM=ExLed (no @) — function uses SMTP_USERNAME as address
   EXLED_APP_URL=https://be.exled.app
   ALLOW_DEBUG_TEST_EMAIL=true
   ```

   `EXLED_APP_URL` is for **links in emails** (can stay prod even if you debug API on leam). EHLO uses the mailbox domain (`exled.app` from `a@exled.app`) unless you set `SMTP_EHLO_NAME`. `ALLOW_DEBUG_TEST_EMAIL` enables the debug menu test send.

### `[smtp] connect` fails in `docker compose logs functions`

Login OTP uses **auth** (GoTrue); activity email uses **functions** — separate containers.

```bash
# Compare env (auth vs functions)
docker compose exec auth printenv | grep -i smtp | sort
docker compose exec functions printenv | grep -i smtp | sort

# DNS + TCP from functions container
docker compose exec functions sh -c 'getent hosts smtp.openxchange.eu; nc -zv smtp.openxchange.eu 587'
```

If `nc` fails from `functions` but auth can send OTP, add to **functions** in `docker-compose.yml`:

```yaml
    dns:
      - 8.8.8.8
      - 1.1.1.1
```

Copy the same `GOTRUE_SMTP_*` values as `SMTP_HOSTNAME`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM` on the functions service, then `docker compose up -d --force-recreate functions`.

### `SMTP read timed out` (function boots, mail does not send)

TCP may connect but the server never sends a normal SMTP greeting. Check auth uses the **same port/TLS** as functions:

```bash
docker compose exec auth printenv | grep -iE 'GOTRUE_SMTP_(HOST|PORT|USER)'
docker compose exec functions printenv | grep -iE 'SMTP_(HOSTNAME|PORT|USERNAME)'
```

If webmail uses **SSL on 465**, set on functions:

```yaml
SMTP_PORT: "465"
SMTP_SECURE: "true"
```

Redeploy latest `send-activity-email/index.ts` (improved SMTP reader + longer timeouts), then retry test email.

5. Health check:

   ```bash
   curl -s "https://be.exled.app/functions/v1/send-activity-email?health=1" \
     -H "Authorization: Bearer $SERVICE_ROLE_KEY"
   ```

   Redacted snapshot (URLs, SMTP summary, JWT length — **not** secrets): add `&diagnose=1` to that URL.

   **Live trace lines** on the server: `docker compose logs -f functions | grep send-activity-email-trace` — each line is JSON with `event` (`smtp_send_begin`, `postgrest_error`, `handler_error`, …).

6. **Immediate send on queue** (after health check works — no cron):

   ```bash
   cd ~/leam/docker && source .env
   bash scripts/setup-activity-email-immediate-dispatch.sh
   ```

   Each outbox `INSERT` → pg_net POST `send-activity-email` with `{ "outbox_id": "…" }`. Use `KONG_HOST=leam-kong` if your compose network uses that instead of `kong`.

7. **Backlog only:** `bash scripts/drain-activity-email-queue.sh` (from `~/leam/docker` after `source .env`). Inspect: `bash scripts/show-activity-email-queue.sh`.

Full walkthrough + troubleshooting: [deploy-send-activity-email-selfhosted.md](deploy-send-activity-email-selfhosted.md).

### `hello` works but `send-activity-email` → entrypoint

Routing is fine; fix the function folder only:

```bash
# On beacon — remove split-deploy leftovers, keep one self-contained index.ts
rm -f ~/leam/docker/volumes/functions/send-activity-email/smtp_native.ts \
      ~/leam/docker/volumes/functions/send-activity-email/deno.json \
      ~/leam/docker/volumes/functions/send-activity-email/deno.json.bak

# From your PC (repo): copy fresh index.ts (~14 KB, starts with // Activity email)
scp supabase/functions/send-activity-email/index.ts \
  root@beacon:~/leam/docker/volumes/functions/send-activity-email/

bash scripts/setup-beacon-edge-functions.sh ~/leam/docker

# Confirm inside container
docker compose exec functions head -3 /home/deno/functions/send-activity-email/index.ts
docker compose exec functions wc -c /home/deno/functions/send-activity-email/index.ts
```

If it still fails, temporarily replace `index.ts` with:

```typescript
Deno.serve(() => new Response('"ok"', { headers: { "Content-Type": "application/json" } }));
```

If that works, the full `index.ts` from your PC is stale or corrupt (re-scp). If minimal also fails, check `docker compose logs functions --tail 50`.

## Supabase Cloud

```bash
supabase functions deploy send-activity-email --no-verify-jwt
supabase secrets set SMTP_HOSTNAME=... SMTP_PORT=587 ...
```

## Optional fallback

If Edge Functions are blocked on a host, `scripts/process_activity_email_outbox.py` can drain the same outbox without Deno.
