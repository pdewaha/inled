// SMTP via Nodemailer — dynamic import() so worker boot does not block on npm.
// First send may take a while while registry.npmjs.org is reached.
// Deploy: volumes/functions/send-activity-email/index.ts  (+ chmod 755 on the folder)
// Health: GET .../send-activity-email?health=1&diagnose=1
// Logs: docker compose logs -f functions | grep send-activity-email-trace

type NodemailerLike = {
  createTransport: (opts: Record<string, unknown>) => {
    sendMail: (opts: Record<string, unknown>) => Promise<unknown>;
    close: (cb: () => void) => void;
  };
};

type SmtpConfig = {
  host: string;
  port: number;
  secure: boolean;
  user: string;
  pass: string;
  from: string;
};

const SMTP_TOTAL_MS = 90000;

/** One-line JSON for log pipelines. Never logs passwords. */
function trace(event: string, data?: Record<string, unknown>) {
  console.log(
    JSON.stringify({
      svc: "send-activity-email-trace",
      event,
      ts: new Date().toISOString(),
      ...(data ?? {}),
    }),
  );
}

function smtpDiag(cfg: SmtpConfig) {
  return {
    smtpHost: cfg.host,
    smtpPort: cfg.port,
    smtpSecure: cfg.secure,
    smtpAuthUser: cfg.user,
    mailFrom: cfg.from,
    passwordLen: cfg.pass.length,
  };
}

let nodemailerPromise: Promise<NodemailerLike> | null = null;

async function loadNodemailer(): Promise<NodemailerLike> {
  if (!nodemailerPromise) {
    nodemailerPromise = (async () => {
      trace("nodemailer_fetch_start", {});
      const mod = await import("npm:nodemailer@6.9.16");
      trace("nodemailer_fetch_ok", {});
      return mod.default as NodemailerLike;
    })();
  }
  return nodemailerPromise;
}

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

/** Nodemailer close() can hang on some runtimes; never block HTTP on it. */
async function closeSmtpTransport(
  transporter: { close: (cb: () => void) => void },
  deadlineMs: number,
): Promise<void> {
  let done = false;
  await Promise.race([
    new Promise<void>((resolve) => {
      try {
        transporter.close(() => {
          if (!done) {
            done = true;
            resolve();
          }
        });
      } catch {
        if (!done) {
          done = true;
          resolve();
        }
      }
    }),
    new Promise<void>((resolve) => {
      setTimeout(() => {
        if (!done) {
          done = true;
          trace("smtp_close_deadline", { ms: deadlineMs });
          resolve();
        }
      }, deadlineMs);
    }),
  ]);
}

async function sendSmtpMail(
  cfg: SmtpConfig,
  to: string,
  subject: string,
  text: string,
  html: string,
): Promise<void> {
  trace("smtp_send_begin", {
    to,
    subjectLen: subject.length,
    ...smtpDiag(cfg),
  });
  const nodemailer = await loadNodemailer();
  const transporter = nodemailer.createTransport({
    host: cfg.host,
    port: cfg.port,
    secure: cfg.secure,
    auth: { user: cfg.user, pass: cfg.pass },
    pool: false,
    maxConnections: 1,
    connectionTimeout: 15000,
    greetingTimeout: 45000,
    socketTimeout: 90000,
    requireTLS: !cfg.secure && cfg.port !== 465,
    tls: { minVersion: "TLSv1.2" as const },
  });
  trace("smtp_transport_created", { host: cfg.host, port: cfg.port });

  try {
    const info = await withTimeout(
      transporter.sendMail({
        from: cfg.from,
        to,
        subject,
        text,
        html,
      }) as Promise<{ messageId?: string; response?: string }>,
      SMTP_TOTAL_MS,
      "SMTP sendMail",
    );
    trace("smtp_send_ok", {
      messageId: info.messageId ?? null,
      responsePreview: (info.response ?? "").slice(0, 240),
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("smtp_send_error", { error: msg.slice(0, 500) });
    throw e;
  } finally {
    // Do not combine with sendMail inside one withTimeout: close() may never
    // call back after 250 Ok, so the handler would idle until SMTP_TOTAL_MS.
    await closeSmtpTransport(transporter, 1000);
  }
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

/** Read body once; do not swallow parse errors (old code turned them into `{}` → misleading 400). */
async function parseRequestJsonBody(
  req: Request,
): Promise<
  | { ok: true; body: Record<string, unknown> }
  | { ok: false; response: Response }
> {
  const contentType = req.headers.get("content-type") ?? "";
  let text: string;
  try {
    text = await req.text();
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("http_body_read_error", { error: msg.slice(0, 200) });
    return {
      ok: false,
      response: jsonResponse({ error: "Could not read request body" }, 400),
    };
  }
  trace("http_body_in", {
    byteLen: text.length,
    contentType: contentType.slice(0, 120),
  });
  let trimmed = text.trim();
  // Common paste: -d '{"test_email":"..."}##' with ## inside the quoted payload.
  if (trimmed.endsWith("#")) {
    const withoutHash = trimmed.replace(/#+$/, "").trim();
    if (withoutHash !== trimmed) {
      trace("http_body_stripped_trailing_hash", {
        beforeLen: trimmed.length,
        afterLen: withoutHash.length,
      });
      trimmed = withoutHash;
    }
  }
  if (!trimmed) {
    return {
      ok: false,
      response: jsonResponse(
        {
          error: "Empty request body",
          hint: 'POST JSON like {"test_email":"you@example.com"}',
        },
        400,
      ),
    };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("http_body_json_error", {
      message: msg.slice(0, 200),
      byteLen: trimmed.length,
      tailPreview: trimmed.slice(-12),
    });
    return {
      ok: false,
      response: jsonResponse(
        {
          error: "Invalid JSON body",
          detail: msg.slice(0, 200),
          byteLen: trimmed.length,
          tailPreview: trimmed.slice(-12),
          hint:
            'Body must be only JSON, e.g. {"test_email":"you@example.com"} — no ## or shell comment after the closing brace.',
        },
        400,
      ),
    };
  }
  if (parsed !== null && typeof parsed === "string") {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      /* leave as string; will fail object check below */
    }
  }
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    Array.isArray(parsed)
  ) {
    return {
      ok: false,
      response: jsonResponse(
        {
          error: "JSON body must be one object {...}, not an array or primitive",
          got: parsed === null ? "null" : Array.isArray(parsed) ? "array" : typeof parsed,
        },
        400,
      ),
    };
  }
  return { ok: true, body: parsed as Record<string, unknown> };
}

function envFirst(...keys: string[]): string | undefined {
  for (const k of keys) {
    const v = Deno.env.get(k)?.trim();
    if (v) return v;
  }
  return undefined;
}

/** Build RFC From header; if SMTP_FROM has no @, treat as display name and use SMTP_USERNAME. */
function buildSmtpFromHeader(
  senderName: string | undefined,
  fromRaw: string | undefined,
  smtpUser: string,
): string {
  const nameOpt = senderName?.trim();
  if (!fromRaw?.trim()) {
    return nameOpt ? `${nameOpt} <${smtpUser}>` : smtpUser;
  }
  const f = fromRaw.trim();
  // Already "Display Name <email@host>"
  if (f.includes("<") && f.includes(">") && f.includes("@")) {
    return f;
  }
  // Bare email
  if (f.includes("@")) {
    return nameOpt ? `${nameOpt} <${f}>` : f;
  }
  // Label only (e.g. SMTP_FROM=ExLed) — same idea as GoTrue admin email + display name
  const display = nameOpt || f;
  return `${display} <${smtpUser}>`;
}

function readSmtpConfig(): SmtpConfig | { error: string } {
  const host = envFirst("SMTP_HOSTNAME", "SMTP_HOST", "GOTRUE_SMTP_HOST");
  const portRaw = envFirst("SMTP_PORT", "GOTRUE_SMTP_PORT") ?? "587";
  const port = Number(portRaw);
  // GoTrue has no SMTP_SECURE flag: port 587 → STARTTLS; 465 → TLS. Same here.
  const secureRaw = envFirst("SMTP_SECURE", "GOTRUE_SMTP_SECURE")?.toLowerCase();
  const secure = secureRaw === "true" || secureRaw === "1" || port === 465;
  const user = envFirst("SMTP_USERNAME", "SMTP_USER", "GOTRUE_SMTP_USER");
  const pass = envFirst("SMTP_PASSWORD", "SMTP_PASS", "GOTRUE_SMTP_PASS");
  const fromRaw = envFirst("SMTP_FROM", "SMTP_ADMIN_EMAIL", "GOTRUE_SMTP_ADMIN_EMAIL");
  const senderName = envFirst("SMTP_SENDER_NAME", "GOTRUE_SMTP_SENDER_NAME");

  if (!host) {
    trace("smtp_config_error", { reason: "missing_host" });
    return { error: "SMTP_HOSTNAME not set on functions container" };
  }
  if (!Number.isFinite(port) || port <= 0) {
    trace("smtp_config_error", { reason: "bad_port", portRaw });
    return { error: `Invalid SMTP_PORT: ${portRaw}` };
  }
  if (!user || !pass) {
    trace("smtp_config_error", { reason: "missing_user_or_pass" });
    return { error: "SMTP_USERNAME / SMTP_PASSWORD not set on functions container" };
  }

  const fromHeader = buildSmtpFromHeader(senderName, fromRaw, user);
  if (!fromHeader.trim()) {
    trace("smtp_config_error", {
      reason: "empty_from_header",
    });
    return { error: "SMTP_FROM / SMTP_USERNAME could not build a From header" };
  }

  const cfg = { host, port, secure, user, pass, from: fromHeader };
  trace("smtp_config_ready", smtpDiag(cfg));
  return cfg;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Intro line only; title lives in summary_snippet (gray box). */
function emailIntroLine(activityLine: string, summarySnippet: string): string {
  const line = activityLine.trim();
  const snip = summarySnippet.trim();
  if (!snip || snip === "—") return line;
  const lower = line.toLowerCase();
  if (lower.startsWith("created a new expectation:")) {
    return "Created a new expectation.";
  }
  if (lower.startsWith("created a new talking point:")) {
    return "Created a new talking point.";
  }
  if (lower.startsWith("published this expectation:") ||
    lower.startsWith("published this talking point:")) {
    return line.includes("talking point")
      ? "Published this talking point."
      : "Published this expectation.";
  }
  const colon = line.indexOf(":");
  if (colon > 0 && line.slice(colon + 1).trim() === snip) {
    const head = line.slice(0, colon).trim();
    return head.endsWith(".") ? head : `${head}.`;
  }
  return line;
}

function buildEmail(row: OutboxRow, appUrl: string) {
  const base = appUrl.replace(/\/$/, "");
  const openUrl = `${base}/?expectation=${row.expectation_id}`;
  const intro = emailIntroLine(row.activity_line, row.summary_snippet);
  const subject = `[Exled] ${row.kind_label}: ${row.summary_snippet}`;
  const text = [
    "Hi,",
    "",
    `${row.sender_label}: ${intro}`,
    "",
    row.summary_snippet,
    "",
    `Open in Exled: ${openUrl}`,
    "",
    "— Exled notifications",
  ].join("\n");

  const html = `<!DOCTYPE html>
<html><body style="font-family:system-ui,sans-serif;line-height:1.5;max-width:560px">
  <p><strong>${escapeHtml(row.sender_label)}</strong>: ${escapeHtml(intro)}</p>
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
      const txt = await res.text();
      trace("postgrest_error", {
        op: "selectOne",
        table,
        status: res.status,
        bodyPreview: txt.slice(0, 400),
      });
      throw new Error(`PostgREST ${res.status}: ${txt}`);
    }
    return (await res.json()) as T;
  }

  async selectMany<T>(table: string, query: string): Promise<T[]> {
    const url = `${this.baseUrl}/rest/v1/${table}?${query}`;
    const res = await fetch(url, { headers: this.headers() });
    if (!res.ok) {
      const txt = await res.text();
      trace("postgrest_error", {
        op: "selectMany",
        table,
        status: res.status,
        bodyPreview: txt.slice(0, 400),
      });
      throw new Error(`PostgREST ${res.status}: ${txt}`);
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
      const txt = await res.text();
      trace("postgrest_error", {
        op: "patch",
        table,
        status: res.status,
        bodyPreview: txt.slice(0, 400),
      });
      throw new Error(`PostgREST patch ${res.status}: ${txt}`);
    }
  }
}

const OUTBOX_SELECT =
  "id,company_id,expectation_id,recipient_person_id,recipient_email,sender_label,source_type,kind_label,activity_line,summary_snippet,status";

async function processOutboxRow(
  rest: RestClient,
  smtp: SmtpConfig,
  appUrl: string,
  id: string,
): Promise<{ id: string; ok: boolean; error?: string }> {
  trace("outbox_row_start", { outboxId: id });
  const row = await rest.selectOne<OutboxRow>(
    "activity_email_outbox",
    `id=eq.${encodeURIComponent(id)}&select=${OUTBOX_SELECT}`,
  );

  if (!row) {
    trace("outbox_row_not_found", { outboxId: id });
    return { id, ok: false, error: "outbox row not found" };
  }
  if (row.status !== "pending") {
    trace("outbox_row_skip_status", { outboxId: id, status: row.status });
    return { id, ok: true };
  }

  if (!row.recipient_email?.trim()) {
    trace("outbox_row_skip_no_email", { outboxId: id });
    await rest.patch(
      "activity_email_outbox",
      `id=eq.${encodeURIComponent(id)}`,
      { status: "skipped", error_message: "no recipient email" },
    );
    return { id, ok: true };
  }

  const { subject, text, html } = buildEmail(row, appUrl);

  try {
    trace("outbox_row_smtp", {
      outboxId: id,
      to: row.recipient_email.trim(),
    });
    await sendSmtpMail(
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
    trace("outbox_row_sent", { outboxId: id });
    return { id, ok: true };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("outbox_row_failed", { outboxId: id, error: msg.slice(0, 500) });
    await rest.patch(
      "activity_email_outbox",
      `id=eq.${encodeURIComponent(id)}`,
      { status: "failed", error_message: msg.slice(0, 500) },
    );
    return { id, ok: false, error: msg };
  }
}

async function sendDebugTestEmail(
  smtp: SmtpConfig,
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
  trace("test_email_start", { to });
  try {
    await sendSmtpMail(smtp, to, subject, text, html);
    trace("test_email_ok", { to });
    return { ok: true };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("test_email_error", { to, error: msg.slice(0, 500) });
    return { ok: false, error: msg };
  }
}

async function runHealthCheck(
  smtp: SmtpConfig,
  supabaseUrl: string,
  diagnose: boolean,
  supabaseUrlRaw: string,
  serviceKeyLen: number,
): Promise<Response> {
  const checks: Record<string, string> = {
    supabase_url: supabaseUrl,
    smtp_host: smtp.host,
    smtp_port: String(smtp.port),
    worker_imports: "npm:nodemailer@6.9.16",
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
  trace("health_done", {
    ok,
    kong: checks.kong_reachable === "ok",
    smtpTcp: checks.smtp_tcp === "ok",
  });

  const payload: Record<string, unknown> = { ok, checks };
  if (diagnose) {
    payload.diagnose = {
      supabaseUrlRaw,
      supabaseUrlInternal: supabaseUrl,
      ...smtpDiag(smtp),
      serviceRoleJwtLen: serviceKeyLen,
      exledAppUrl: Deno.env.get("EXLED_APP_URL") ?? null,
      allowDebugTestEmail: Deno.env.get("ALLOW_DEBUG_TEST_EMAIL") ?? null,
      edgeWorkerTimeoutMs: Deno.env.get("EDGE_WORKER_TIMEOUT_MS") ?? null,
    };
  }
  return jsonResponse(payload, ok ? 200 : 503);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname;
  trace("http_request", { method: req.method, path });

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const smtpResult = readSmtpConfig();
  if ("error" in smtpResult) {
    trace("smtp_config_failed", { error: smtpResult.error });
    return jsonResponse({ error: smtpResult.error }, 500);
  }
  const smtp = smtpResult;

  const supabaseUrlRaw = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  let supabaseUrl = supabaseUrlRaw;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const appUrl = Deno.env.get("EXLED_APP_URL") ?? "https://be.exled.app";

  // PostgREST must use internal Kong, not the public API hostname.
  if (supabaseUrl.startsWith("https://") || supabaseUrl.includes("be.exled.app") ||
    supabaseUrl.includes("tauworks.org")) {
    const internal = (Deno.env.get("SUPABASE_INTERNAL_URL") ?? "http://kong:8000")
      .replace(/\/$/, "");
    trace("supabase_url_rewrite", { from: supabaseUrl, to: internal });
    supabaseUrl = internal;
  } else {
    trace("supabase_url_as_env", { url: supabaseUrl });
  }

  if (url.searchParams.get("health") === "1") {
    if (!supabaseUrl || !serviceKey) {
      trace("health_aborted", { reason: "missing_url_or_key" });
      return jsonResponse({ error: "SUPABASE_URL / SERVICE_ROLE_KEY missing" }, 500);
    }
    const diagnose = url.searchParams.get("diagnose") === "1";
    return await runHealthCheck(
      smtp,
      supabaseUrl,
      diagnose,
      supabaseUrlRaw,
      serviceKey.length,
    );
  }

  if (!supabaseUrl || !serviceKey) {
    trace("request_aborted", { reason: "missing_supabase_or_service_key" });
    return jsonResponse({ error: "Supabase service env missing" }, 500);
  }

  const rest = new RestClient(supabaseUrl, serviceKey);

  const parsedBody = await parseRequestJsonBody(req);
  if (!parsedBody.ok) {
    return parsedBody.response;
  }
  const body = parsedBody.body;
  const processPending =
    body.process_pending === true ||
    body.process_pending === "true";
  trace("http_body_parsed", {
    hasTestEmail: typeof body.test_email === "string",
    processPending,
    hasOutboxId: typeof body.outbox_id === "string",
  });

  const results: Array<{ id: string; ok: boolean; error?: string }> = [];

  try {
    if (typeof body.test_email === "string" && body.test_email.trim()) {
      if (Deno.env.get("ALLOW_DEBUG_TEST_EMAIL") !== "true") {
        trace("test_email_blocked", { reason: "ALLOW_DEBUG_TEST_EMAIL_not_true" });
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
    } else if (processPending) {
      const limit =
        typeof body.limit === "number" && body.limit > 0
          ? Math.min(body.limit, 50)
          : 20;
      const pending = await rest.selectMany<{ id: string }>(
        "activity_email_outbox",
        `status=eq.pending&order=created_at.asc&limit=${limit}&select=id`,
      );
      trace("outbox_pending_fetched", { count: pending.length, limit });
      for (const row of pending) {
        results.push(await processOutboxRow(rest, smtp, appUrl, row.id));
      }
    } else {
      trace("http_bad_body", {
        reason: "no_action",
        receivedKeys: Object.keys(body),
      });
      return jsonResponse(
        {
          error:
            'Provide "test_email", "outbox_id", or "process_pending": true',
          receivedKeys: Object.keys(body),
        },
        400,
      );
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("handler_error", {
      error: msg.slice(0, 800),
      stack: e instanceof Error ? (e.stack ?? "").slice(0, 1200) : undefined,
    });
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
  trace("http_response_ok", {
    processed: results.length,
    failed: failed.length,
  });
  return jsonResponse(
    { processed: results.length, failed: failed.length, results },
    failed.length > 0 ? 207 : 200,
  );
});
