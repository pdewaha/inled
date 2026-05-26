# Invite email

When someone taps **Invite** (or adds an email for an @mentioned placeholder), the app:

1. Inserts a row in `invites`
2. Calls edge function `send-invite-email` with `{ "invite_id": "<uuid>" }`

Personalized invites (`token_hash` prefix `personalized:<person_id>:`) include open expectations and talking points already assigned to that person.

While a colleague has a **pending invite**, the activity-email trigger skips redundant **“Created a new expectation/talking point”** mail (migration `021`) — the invite email is the single onboarding notification.

## Deploy (beacon)

1. Apply migrations `020_invite_pending_items.sql` and `021_activity_email_skip_pending_invite.sql` on the target DB.
2. Copy function and restart:

```bash
bash scripts/setup-beacon-edge-functions.sh /root/exled/docker /path/to/inled/supabase/functions
```

3. Ensure the **functions** container has the same SMTP env as GoTrue (`SMTP_*` or `GOTRUE_SMTP_*`) and `EXLED_APP_URL` (e.g. `https://be.exled.app`).

## Test

1. @mention a new handle, create an expectation for them.
2. Open details → **Invite**, enter their email.
3. Check inbox; email should list the expectation and a sign-in link.
