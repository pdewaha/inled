// Activity email outbox → SMTP. Single file, no external imports (self-hosted).
// Env on **functions** container: SMTP_*, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, EXLED_APP_URL
// Deploy: volumes/functions/send-activity-email/index.ts  (+ chmod 755 on the folder)
// Health: GET .../send-activity-email?health=1

// --- smtp_native (inlined) ---
type NativeSmtpConfig = {
  host: string;
  port: number;
  secure: boolean;
  user: string;
  pass: string;
  from: string;
};

const smtpEnc = new TextEncoder();
const smtpDec = new TextDecoder();
const SMTP_CONNECT_MS = 15000;
const SMTP_READ_MS = 45000;
const SMTP_TOTAL_MS = 90000;

function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) => {
      setTimeout(
        () => reject(new Error(`${label} timed out after ${ms}ms`)),
        ms,
      );
    }),
  ]);
}

function smtpLines(out: string): string[] {
  return out.split(/\r?\n/).filter((l) => l.length > 0);
}

/** True when the buffer contains a full SMTP response (e.g. 220 … or 250 …). */
function smtpReplyComplete(out: string): boolean {
  const lines = smtpLines(out);
  if (lines.length === 0) return false;
  const last = lines[lines.length - 1]!;
  if (!/^\d{3}[- ]/.test(last)) return false;
  const code = last.slice(0, 3);
  return !lines.some((l) => l.startsWith(`${code}-`));
}

async function smtpReadReply(
  conn: Deno.Conn,
  timeoutMs = SMTP_READ_MS,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  const buf = new Uint8Array(8192);
  let out = "";
  while (true) {
    if (smtpReplyComplete(out)) return out;

    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      const preview = out.length > 0
        ? out.replace(/\r?\n/g, " ").slice(0, 160)
        : "(no bytes from server — wrong port/TLS?)";
      throw new Error(`SMTP read timed out after ${timeoutMs}ms; got: ${preview}`);
    }

    let n: number | null;
    try {
      n = await withTimeout(conn.read(buf), remaining, "SMTP read");
    } catch (e) {
      try {
        conn.close();
      } catch {
        // ignore
      }
      throw e;
    }

    if (n === null) continue;
    if (n === 0) {
      if (smtpReplyComplete(out)) return out;
      throw new Error("SMTP connection closed before a complete reply");
    }
    out += smtpDec.decode(buf.subarray(0, n));
  }
}

function smtpExpectCode(reply: string, codes: string[]): void {
  const line = smtpLines(reply).find((l) => /^\d{3}[- ]/.test(l)) ?? "";
  const code = line.slice(0, 3);
  if (!codes.includes(code)) {
    throw new Error(`SMTP unexpected reply ${code}: ${line}`);
  }
}

async function smtpWriteLine(conn: Deno.Conn, line: string): Promise<string> {
  await conn.write(smtpEnc.encode(`${line}\r\n`));
  return await smtpReadReply(conn);
}

function smtpB64(s: string): string {
  return btoa(s);
}

function smtpExtractAddr(from: string): string {
  const m = from.match(/<([^>]+)>/);
  return (m?.[1] ?? from).trim();
}

function smtpEncodeSubject(subject: string): string {
  if (/^[\x20-\x7E]*$/.test(subject)) return subject;
  return `=?UTF-8?B?${btoa(subject)}?=`;
}

/** Client hostname for EHLO (not the SMTP server hostname). */
function smtpEhloName(cfg: NativeSmtpConfig): string {
  const explicit = envFirst("SMTP_EHLO_NAME");
  if (explicit) {
    return explicit.replace(/[^a-zA-Z0-9.-]/g, "").slice(0, 255) || "localhost";
  }
  const appUrl = Deno.env.get("EXLED_APP_URL");
  if (appUrl) {
    try {
      const host = new URL(appUrl).hostname;
      if (host) return host;
    } catch {
      // ignore
    }
  }
  const addr = smtpExtractAddr(cfg.user) || smtpExtractAddr(cfg.from);
  const domain = addr.includes("@") ? addr.split("@")[1]! : "";
  if (domain) return domain;
  return "localhost";
}

async function smtpConnect(cfg: NativeSmtpConfig): Promise<Deno.Conn> {
  console.log(`[smtp] connect ${cfg.host}:${cfg.port} secure=${cfg.secure}`);
  try {
    const connectPromise = (cfg.secure || cfg.port === 465)
      ? Deno.connectTls({ hostname: cfg.host, port: cfg.port })
      : Deno.connect({ hostname: cfg.host, port: cfg.port });
    const conn = await withTimeout(connectPromise, SMTP_CONNECT_MS, "SMTP connect");
    console.log("[smtp] TCP connected");
    return conn;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[smtp] connect failed: ${msg}`);
    throw new Error(
      `Cannot reach SMTP ${cfg.host}:${cfg.port} from functions container (${msg}). ` +
        "Check SMTP_* env matches GoTrue, outbound port 587, and dns: [8.8.8.8] on the functions service.",
    );
  }
}

async function sendNativeSmtpInner(
  cfg: NativeSmtpConfig,
  to: string,
  subject: string,
  text: string,
  html: string,
): Promise<void> {
  let conn = await smtpConnect(cfg);

  try {
    let reply = await smtpReadReply(conn);
    smtpExpectCode(reply, ["220"]);
    console.log("[smtp] banner OK");

    const ehlo = smtpEhloName(cfg);
    console.log(`[smtp] EHLO ${ehlo}`);
    reply = await smtpWriteLine(conn, `EHLO ${ehlo}`);
    smtpExpectCode(reply, ["250"]);
    console.log("[smtp] EHLO OK");

    if (!cfg.secure && cfg.port !== 465) {
      console.log("[smtp] STARTTLS");
      reply = await smtpWriteLine(conn, "STARTTLS");
      smtpExpectCode(reply, ["220"]);
      conn = await withTimeout(
        Deno.startTls(conn, { hostname: cfg.host }),
        SMTP_CONNECT_MS,
        "SMTP STARTTLS",
      );
      console.log("[smtp] STARTTLS OK");
      reply = await smtpWriteLine(conn, `EHLO ${ehlo}`);
      smtpExpectCode(reply, ["250"]);
    }

    console.log("[smtp] AUTH");
    reply = await smtpWriteLine(conn, "AUTH LOGIN");
    smtpExpectCode(reply, ["334"]);
    reply = await smtpWriteLine(conn, smtpB64(cfg.user));
    smtpExpectCode(reply, ["334"]);
    reply = await smtpWriteLine(conn, smtpB64(cfg.pass));
    smtpExpectCode(reply, ["235"]);

    reply = await smtpWriteLine(conn, `MAIL FROM:<${smtpExtractAddr(cfg.from)}>`);
    smtpExpectCode(reply, ["250"]);
    reply = await smtpWriteLine(conn, `RCPT TO:<${to}>`);
    smtpExpectCode(reply, ["250", "251"]);

    console.log("[smtp] DATA");
    reply = await smtpWriteLine(conn, "DATA");
    smtpExpectCode(reply, ["354"]);

    const boundary = `exled_${Date.now()}`;
    const body = [
      `From: ${cfg.from}`,
      `To: ${to}`,
      `Subject: ${smtpEncodeSubject(subject)}`,
      "MIME-Version: 1.0",
      `Content-Type: multipart/alternative; boundary="${boundary}"`,
      "",
      `--${boundary}`,
      "Content-Type: text/plain; charset=utf-8",
      "",
      text,
      "",
      `--${boundary}`,
      "Content-Type: text/html; charset=utf-8",
      "",
      html,
      "",
      `--${boundary}--`,
      ".",
    ].join("\r\n");

    await conn.write(smtpEnc.encode(`${body}\r\n`));
    reply = await smtpReadReply(conn);
    smtpExpectCode(reply, ["250"]);
    console.log("[smtp] sent OK");

    await smtpWriteLine(conn, "QUIT");
  } finally {
    try {
      conn.close();
    } catch {
      // ignore
    }
  }
}

async function sendNativeSmtp(
  cfg: NativeSmtpConfig,
  to: string,
  subject: string,
  text: string,
  html: string,
): Promise<void> {
  await withTimeout(
    sendNativeSmtpInner(cfg, to, subject, text, html),
    SMTP_TOTAL_MS,
    "SMTP",
  );
}

// --- main ---
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type OutboxRow = {
  id: string;
  company_id: string;
  expectation_id: string;
  recipient_person_id: string;
  recipient_email: string;
  sender_label: string;
  source_type: string;
  kind_label: string;
  activity_line: string;
  summary_snippet: string;
  status: string;
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function envFirst(...keys: string[]): string | undefined {
  for (const k of keys) {
    const v = Deno.env.get(k)?.trim();
    if (v) return v;
  }
  return undefined;
}

function readSmtpConfig(): NativeSmtpConfig | { error: string } {
  const host = envFirst("SMTP_HOSTNAME", "SMTP_HOST", "GOTRUE_SMTP_HOST");
  const portRaw = envFirst("SMTP_PORT", "GOTRUE_SMTP_PORT") ?? "587";
  const port = Number(portRaw);
  // GoTrue has no SMTP_SECURE flag: port 587 → STARTTLS; 465 → TLS. Same here.
  const secureRaw = envFirst("SMTP_SECURE", "GOTRUE_SMTP_SECURE")?.toLowerCase();
  const secure = secureRaw === "true" || secureRaw === "1" || port === 465;
  const user = envFirst("SMTP_USERNAME", "SMTP_USER", "GOTRUE_SMTP_USER");
  const pass = envFirst("SMTP_PASSWORD", "SMTP_PASS", "GOTRUE_SMTP_PASS");
  const from = envFirst("SMTP_FROM", "SMTP_ADMIN_EMAIL", "GOTRUE_SMTP_ADMIN_EMAIL");
  const senderName = envFirst("SMTP_SENDER_NAME", "GOTRUE_SMTP_SENDER_NAME");
  const fromHeader = senderName && from ? `${senderName} <${from}>` : from;

  if (!host) return { error: "SMTP_HOSTNAME not set on functions container" };
  if (!Number.isFinite(port) || port <= 0) {
    return { error: `Invalid SMTP_PORT: ${portRaw}` };
  }
  if (!user || !pass) {
    return { error: "SMTP_USERNAME / SMTP_PASSWORD not set on functions container" };
  }
  if (!fromHeader) return { error: "SMTP_FROM not set on functions container" };

  return { host, port, secure, user, pass, from: fromHeader };
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function buildEmail(row: OutboxRow, appUrl: string) {
  const base = appUrl.replace(/\/$/, "");
  const openUrl = `${base}/?expectation=${row.expectation_id}`;
  const subject = `[Exled] ${row.kind_label}: ${row.summary_snippet}`;
  const text = [
    "Hi,",
    "",
    `${row.sender_label}: ${row.activity_line}`,
    "",
    `Summary: ${row.summary_snippet}`,
    "",
    `Open in Exled: ${openUrl}`,
    "",
    "— Exled notifications",
  ].join("\n");

  const html = `<!DOCTYPE html>
<html><body style="font-family:system-ui,sans-serif;line-height:1.5;max-width:560px">
  <p><strong>${escapeHtml(row.sender_label)}</strong>: ${escapeHtml(row.activity_line)}</p>
  <p style="background:#f4f4f5;padding:12px;border-radius:8px">${escapeHtml(row.summary_snippet)}</p>
  <p><a href="${escapeHtml(openUrl)}">Open in Exled</a></p>
</body></html>`;

  return { subject, text, html };
}

class RestClient {
  constructor(
    private baseUrl: string,
    private serviceKey: string,
  ) {}

  private headers(extra: Record<string, string> = {}): Record<string, string> {
    return {
      apikey: this.serviceKey,
      Authorization: `Bearer ${this.serviceKey}`,
      "Content-Type": "application/json",
      ...extra,
    };
  }

  async selectOne<T>(table: string, query: string): Promise<T | null> {
    const url = `${this.baseUrl}/rest/v1/${table}?${query}`;
    const res = await fetch(url, {
      headers: this.headers({
        Accept: "application/vnd.pgrst.object+json",
      }),
    });
    if (res.status === 406) return null;
    if (!res.ok) {
      throw new Error(`PostgREST ${res.status}: ${await res.text()}`);
    }
    return (await res.json()) as T;
  }

  async selectMany<T>(table: string, query: string): Promise<T[]> {
    const url = `${this.baseUrl}/rest/v1/${table}?${query}`;
    const res = await fetch(url, { headers: this.headers() });
    if (!res.ok) {
      throw new Error(`PostgREST ${res.status}: ${await res.text()}`);
    }
    return (await res.json()) as T[];
  }

  async patch(table: string, query: string, body: Record<string, unknown>) {
    const url = `${this.baseUrl}/rest/v1/${table}?${query}`;
    const res = await fetch(url, {
      method: "PATCH",
      headers: this.headers({ Prefer: "return=minimal" }),
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      throw new Error(`PostgREST patch ${res.status}: ${await res.text()}`);
    }
  }
}

const OUTBOX_SELECT =
  "id,company_id,expectation_id,recipient_person_id,recipient_email,sender_label,source_type,kind_label,activity_line,summary_snippet,status";

async function processOutboxRow(
  rest: RestClient,
  smtp: NativeSmtpConfig,
  appUrl: string,
  id: string,
): Promise<{ id: string; ok: boolean; error?: string }> {
  const row = await rest.selectOne<OutboxRow>(
    "activity_email_outbox",
    `id=eq.${encodeURIComponent(id)}&select=${OUTBOX_SELECT}`,
  );

  if (!row) return { id, ok: false, error: "outbox row not found" };
  if (row.status !== "pending") return { id, ok: true };

  if (!row.recipient_email?.trim()) {
    await rest.patch(
      "activity_email_outbox",
      `id=eq.${encodeURIComponent(id)}`,
      { status: "skipped", error_message: "no recipient email" },
    );
    return { id, ok: true };
  }

  const { subject, text, html } = buildEmail(row, appUrl);

  try {
    await sendNativeSmtp(
      smtp,
      row.recipient_email.trim(),
      subject,
      text,
      html,
    );
    await rest.patch(
      "activity_email_outbox",
      `id=eq.${encodeURIComponent(id)}`,
      {
        status: "sent",
        sent_at: new Date().toISOString(),
        error_message: null,
      },
    );
    return { id, ok: true };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await rest.patch(
      "activity_email_outbox",
      `id=eq.${encodeURIComponent(id)}`,
      { status: "failed", error_message: msg.slice(0, 500) },
    );
    return { id, ok: false, error: msg };
  }
}

async function sendDebugTestEmail(
  smtp: NativeSmtpConfig,
  to: string,
  appUrl: string,
): Promise<{ ok: boolean; error?: string }> {
  const when = new Date().toISOString();
  const subject = "[Exled] SMTP test";
  const text = [
    "This is a test message from the Exled send-activity-email Edge Function.",
    "",
    `Time: ${when}`,
    `App: ${appUrl}`,
    "",
    "If you received this, SMTP from the functions container is working.",
  ].join("\n");
  const html = `<!DOCTYPE html><html><body style="font-family:system-ui,sans-serif">
  <p>This is a <strong>test</strong> from the Exled activity email function.</p>
  <p style="color:#666">${escapeHtml(when)} · ${escapeHtml(appUrl)}</p>
  <p>If you received this, SMTP from the functions container is working.</p>
</body></html>`;
  try {
    await sendNativeSmtp(smtp, to, subject, text, html);
    return { ok: true };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { ok: false, error: msg };
  }
}

async function runHealthCheck(
  smtp: NativeSmtpConfig,
  supabaseUrl: string,
): Promise<Response> {
  const checks: Record<string, string> = {
    supabase_url: supabaseUrl,
    smtp_host: smtp.host,
    smtp_port: String(smtp.port),
    worker_imports: "single index.ts",
  };

  try {
    const u = new URL(supabaseUrl);
    const port = u.port
      ? Number(u.port)
      : (u.protocol === "https:" ? 443 : 80);
    await Deno.connect({ hostname: u.hostname, port }).then((c) => c.close());
    checks.kong_reachable = "ok";
  } catch (e) {
    checks.kong_reachable = `fail: ${e}`;
  }

  try {
    await Deno.connect({ hostname: smtp.host, port: smtp.port }).then((c) =>
      c.close()
    );
    checks.smtp_tcp = "ok";
  } catch (e) {
    checks.smtp_tcp = `fail: ${e}`;
  }

  const ok = checks.kong_reachable === "ok" && checks.smtp_tcp === "ok";
  return jsonResponse({ ok, checks }, ok ? 200 : 503);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const smtpResult = readSmtpConfig();
  if ("error" in smtpResult) {
    return jsonResponse({ error: smtpResult.error }, 500);
  }
  const smtp = smtpResult;

  let supabaseUrl = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const appUrl = Deno.env.get("EXLED_APP_URL") ?? "https://be.exled.app";

  // PostgREST must use internal Kong, not the public API hostname.
  if (supabaseUrl.startsWith("https://") || supabaseUrl.includes("be.exled.app") ||
    supabaseUrl.includes("tauworks.org")) {
    const internal = (Deno.env.get("SUPABASE_INTERNAL_URL") ?? "http://kong:8000")
      .replace(/\/$/, "");
    supabaseUrl = internal;
  }

  const url = new URL(req.url);
  if (url.searchParams.get("health") === "1") {
    if (!supabaseUrl || !serviceKey) {
      return jsonResponse({ error: "SUPABASE_URL / SERVICE_ROLE_KEY missing" }, 500);
    }
    return await runHealthCheck(smtp, supabaseUrl);
  }

  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: "Supabase service env missing" }, 500);
  }

  const rest = new RestClient(supabaseUrl, serviceKey);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const results: Array<{ id: string; ok: boolean; error?: string }> = [];

  try {
    if (typeof body.test_email === "string" && body.test_email.trim()) {
      if (Deno.env.get("ALLOW_DEBUG_TEST_EMAIL") !== "true") {
        return jsonResponse({
          error:
            "test_email disabled. Set ALLOW_DEBUG_TEST_EMAIL=true on the functions service.",
        }, 403);
      }
      const to = body.test_email.trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) {
        return jsonResponse({ error: "Invalid test_email address" }, 400);
      }
      const sent = await sendDebugTestEmail(smtp, to, appUrl);
      return jsonResponse(
        { test_email: to, sent: sent.ok, error: sent.error },
        sent.ok ? 200 : 500,
      );
    }

    if (typeof body.outbox_id === "string" && body.outbox_id.trim()) {
      results.push(
        await processOutboxRow(rest, smtp, appUrl, body.outbox_id.trim()),
      );
    } else if (body.process_pending === true) {
      const limit =
        typeof body.limit === "number" && body.limit > 0
          ? Math.min(body.limit, 50)
          : 20;
      const pending = await rest.selectMany<{ id: string }>(
        "activity_email_outbox",
        `status=eq.pending&order=created_at.asc&limit=${limit}&select=id`,
      );
      for (const row of pending) {
        results.push(await processOutboxRow(rest, smtp, appUrl, row.id));
      }
    } else {
      return jsonResponse(
        {
          error:
            'Provide "test_email", "outbox_id", or "process_pending": true',
        },
        400,
      );
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes("name resolution") || msg.includes("failed to lookup")) {
      return jsonResponse({
        error:
          "DNS failed inside functions container. Add dns: [8.8.8.8] to functions service, or fix SUPABASE_URL (use http://kong:8000).",
        detail: msg,
      }, 503);
    }
    return jsonResponse({ error: msg }, 500);
  }

  const failed = results.filter((r) => !r.ok);
  return jsonResponse(
    { processed: results.length, failed: failed.length, results },
    failed.length > 0 ? 207 : 200,
  );
});
