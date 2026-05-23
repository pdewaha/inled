# Invite email

When someone taps **Invite** (or adds an email for an @mentioned placeholder), the app:

1. Inserts a row in `invites`
2. Calls edge function `send-invite-email` with `{ "invite_id": "<uuid>" }`

Personalized invites (`token_hash` prefix `personalized:<person_id>:`) include open expectations and talking points already assigned to that person.

## Deploy (beacon)

1. Apply migration `020_invite_pending_items.sql` on the target DB.
2. Copy function and restart:

```bash
bash scripts/setup-beacon-edge-functions.sh /root/exled/docker /path/to/inled/supabase/functions
```

3. Ensure the **functions** container has the same SMTP env as GoTrue (`SMTP_*` or `GOTRUE_SMTP_*`) and `EXLED_APP_URL` (e.g. `https://be.exled.app`).

## Test

1. @mention a new handle, create an expectation for them.
2. Open details → **Invite**, enter their email.
3. Check inbox; email should list the expectation and a sign-in link.
