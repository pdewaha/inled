#!/usr/bin/env python3
"""
Drain activity_email_outbox via SMTP (no Supabase Edge Functions).

On beacon, copy scripts/activity-email.env.example -> activity-email.env, then:
  python3 scripts/process_activity_email_outbox.py
  # or cron every 2 min — see scripts/install-activity-email-cron.sh

Requires: Python 3.9+, network to PostgREST + SMTP.
"""

from __future__ import annotations

import json
import os
import smtplib
import ssl
import sys
import urllib.error
import urllib.request
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ENV_FILE = Path(os.environ.get("ACTIVITY_EMAIL_ENV", SCRIPT_DIR / "activity-email.env"))


def load_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        print(f"Missing config: {path}", file=sys.stderr)
        print("Copy scripts/activity-email.env.example to scripts/activity-email.env", file=sys.stderr)
        sys.exit(1)
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def rest_request(
    cfg: dict[str, str],
    method: str,
    path: str,
    body: dict | list | None = None,
) -> tuple[int, str]:
    base = cfg["SUPABASE_URL"].rstrip("/")
    url = f"{base}/rest/v1/{path.lstrip('/')}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "apikey": cfg["SERVICE_ROLE_KEY"],
            "Authorization": f"Bearer {cfg['SERVICE_ROLE_KEY']}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def fetch_pending(cfg: dict[str, str], limit: int) -> list[dict]:
    q = (
        "activity_email_outbox"
        "?status=eq.pending"
        "&order=created_at.asc"
        f"&limit={limit}"
        "&select=id,recipient_email,sender_label,kind_label,activity_line,summary_snippet,expectation_id"
    )
    code, body = rest_request(cfg, "GET", q)
    if code != 200:
        raise RuntimeError(f"fetch pending failed {code}: {body}")
    return json.loads(body) if body else []


def mark_row(cfg: dict[str, str], row_id: str, status: str, error: str | None) -> None:
    from datetime import datetime, timezone

    patch = {"status": status}
    if status == "sent":
        patch["sent_at"] = datetime.now(timezone.utc).isoformat()
        patch["error_message"] = None
    elif error:
        patch["error_message"] = error[:500]
    path = f"activity_email_outbox?id=eq.{row_id}"
    code, body = rest_request(cfg, "PATCH", path, patch)
    if code not in (200, 204):
        raise RuntimeError(f"patch {row_id} failed {code}: {body}")


def build_messages(row: dict, app_url: str) -> tuple[str, str, str]:
    subject = f"[Exled] {row['kind_label']}: {row['summary_snippet']}"
    open_url = f"{app_url.rstrip('/')}/?expectation={row['expectation_id']}"
    text = (
        "Hi,\n\n"
        f"{row['sender_label']}: {row['activity_line']}\n\n"
        f"Summary: {row['summary_snippet']}\n\n"
        f"Open in Exled: {open_url}\n\n"
        "— Exled notifications\n"
    )
    html = f"""<!DOCTYPE html><html><body style="font-family:system-ui,sans-serif">
<p><strong>{_esc(row['sender_label'])}</strong>: {_esc(row['activity_line'])}</p>
<p style="background:#f4f4f5;padding:12px;border-radius:8px">{_esc(row['summary_snippet'])}</p>
<p><a href="{_esc(open_url)}">Open in Exled</a></p>
</body></html>"""
    return subject, text, html


def _esc(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def send_smtp(cfg: dict[str, str], to: str, subject: str, text: str, html: str) -> None:
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = cfg["SMTP_FROM"]
    msg["To"] = to
    msg.attach(MIMEText(text, "plain", "utf-8"))
    msg.attach(MIMEText(html, "html", "utf-8"))

    host = cfg["SMTP_HOST"]
    port = int(cfg.get("SMTP_PORT", "587"))
    secure = cfg.get("SMTP_SECURE", "false").lower() in ("1", "true", "yes")
    user = cfg["SMTP_USER"]
    password = cfg["SMTP_PASSWORD"]

    if secure or port == 465:
        context = ssl.create_default_context()
        with smtplib.SMTP_SSL(host, port, context=context) as smtp:
            smtp.login(user, password)
            smtp.sendmail(cfg["SMTP_FROM"], [to], msg.as_string())
    else:
        with smtplib.SMTP(host, port) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ssl.create_default_context())
            smtp.ehlo()
            smtp.login(user, password)
            smtp.sendmail(cfg["SMTP_FROM"], [to], msg.as_string())


def main() -> int:
    cfg = load_env(ENV_FILE)
    for key in (
        "SUPABASE_URL",
        "SERVICE_ROLE_KEY",
        "SMTP_HOST",
        "SMTP_USER",
        "SMTP_PASSWORD",
        "SMTP_FROM",
        "EXLED_APP_URL",
    ):
        if not cfg.get(key):
            print(f"Missing {key} in {ENV_FILE}", file=sys.stderr)
            return 1

    limit = int(cfg.get("BATCH_LIMIT", "20"))
    app_url = cfg["EXLED_APP_URL"]

    pending = fetch_pending(cfg, limit)
    if not pending:
        print("No pending rows.")
        return 0

    sent = failed = 0
    for row in pending:
        rid = row["id"]
        to = (row.get("recipient_email") or "").strip()
        if not to:
            mark_row(cfg, rid, "skipped", "no recipient email")
            continue
        try:
            subject, text, html = build_messages(row, app_url)
            send_smtp(cfg, to, subject, text, html)
            mark_row(cfg, rid, "sent", None)
            sent += 1
            print(f"sent {rid} -> {to}")
        except Exception as e:
            mark_row(cfg, rid, "failed", str(e))
            failed += 1
            print(f"failed {rid}: {e}", file=sys.stderr)

    print(f"Done: sent={sent} failed={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
