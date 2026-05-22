// Morning digest: unhealthy published expectations — email receivers only (not authors).
// Deploy: volumes/functions/send-unhealthy-digest/index.ts
// Invoke: POST .../send-unhealthy-digest  { "run": true }  (service role)
// Cron: scripts/install-morning-unhealthy-digest-cron-beacon.sh

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

type DigestRow = {
  recipient_person_id: string;
  recipient_email: string;
  recipient_name: string;
  company_id: string;
  expectation_id: string;
  summary: string;
  expectation_status: number;
  expectation_health: number;
  deadline_label: string | null;
  deadline_at: string | null;
  involvement: string;
  sender_handle?: string;
  sender_label?: string;
  issues: string[];
};

type GroupedRecipient = {
  personId: string;
  email: string;
  name: string;
  items: DigestRow[];
};

const SMTP_TOTAL_MS = 90000;
const MAX_ITEMS_PER_EMAIL = 40;

function trace(event: string, data?: Record<string, unknown>) {
  console.log(
    JSON.stringify({
      svc: "send-unhealthy-digest-trace",
      event,
      ts: new Date().toISOString(),
      ...(data ?? {}),
    }),
  );
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: unknown, status = 200) {
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
  if (f.includes("<") && f.includes(">") && f.includes("@")) return f;
  if (f.includes("@")) return nameOpt ? `${nameOpt} <${f}>` : f;
  return `${nameOpt || f} <${smtpUser}>`;
}

function readSmtpConfig(): SmtpConfig | { error: string } {
  const host = envFirst("SMTP_HOSTNAME", "SMTP_HOST", "GOTRUE_SMTP_HOST");
  const portRaw = envFirst("SMTP_PORT", "GOTRUE_SMTP_PORT") ?? "587";
  const port = Number(portRaw);
  const secureRaw = envFirst("SMTP_SECURE", "GOTRUE_SMTP_SECURE")?.toLowerCase();
  const secure = secureRaw === "true" || secureRaw === "1" || port === 465;
  const user = envFirst("SMTP_USERNAME", "SMTP_USER", "GOTRUE_SMTP_USER");
  const pass = envFirst("SMTP_PASSWORD", "SMTP_PASS", "GOTRUE_SMTP_PASS");
  const fromRaw = envFirst("SMTP_FROM", "SMTP_ADMIN_EMAIL", "GOTRUE_SMTP_ADMIN_EMAIL");
  const senderName = envFirst("SMTP_SENDER_NAME", "GOTRUE_SMTP_SENDER_NAME");
  if (!host || !user || !pass) {
    return { error: "SMTP not configured on functions container" };
  }
  const from = buildSmtpFromHeader(senderName, fromRaw, user);
  return { host, port, secure, user, pass, from };
}

let nodemailerPromise: Promise<NodemailerLike> | null = null;

async function loadNodemailer(): Promise<NodemailerLike> {
  if (!nodemailerPromise) {
    nodemailerPromise = import("npm:nodemailer@6.9.16").then((mod) =>
      mod.default as NodemailerLike
    );
  }
  return nodemailerPromise;
}

async function sendSmtpMail(
  cfg: SmtpConfig,
  to: string,
  subject: string,
  text: string,
  html: string,
): Promise<void> {
  const nodemailer = await loadNodemailer();
  const transporter = nodemailer.createTransport({
    host: cfg.host,
    port: cfg.port,
    secure: cfg.secure,
    auth: { user: cfg.user, pass: cfg.pass },
    connectionTimeout: 20000,
    greetingTimeout: 20000,
    socketTimeout: SMTP_TOTAL_MS,
  });
  try {
    await transporter.sendMail({ from: cfg.from, to, subject, text, html });
  } finally {
    try {
      transporter.close(() => {});
    } catch {
      /* ignore */
    }
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clip(s: string, max: number): string {
  const t = s.trim();
  if (t.length <= max) return t;
  return `${t.slice(0, max - 1)}…`;
}

function groupRows(rows: DigestRow[]): GroupedRecipient[] {
  const byPerson = new Map<string, GroupedRecipient>();
  for (const row of rows) {
    const pid = row.recipient_person_id;
    let g = byPerson.get(pid);
    if (!g) {
      g = {
        personId: pid,
        email: row.recipient_email.trim(),
        name: row.recipient_name.trim(),
        items: [],
      };
      byPerson.set(pid, g);
    }
    const seen = g.items.some((x) => x.expectation_id === row.expectation_id);
    if (!seen) g.items.push(row);
  }
  return [...byPerson.values()].filter((g) =>
    g.email.length > 0 && g.items.length > 0
  );
}

function buildDigestEmail(
  recipient: GroupedRecipient,
  appUrl: string,
): { subject: string; text: string; html: string } {
  const base = appUrl.replace(/\/$/, "");
  const count = recipient.items.length;
  const subject = count === 1
    ? "[Exled] Morning reminder: 1 expectation needs your action"
    : `[Exled] Morning reminder: ${count} expectations need your action`;

  const intro = [
    `Hi${recipient.name ? ` ${recipient.name}` : ""},`,
    "",
    "The following expectations assigned to you are still open and unhealthy in Exled.",
    "Please accept them, define progress, set a deadline where missing, or update status — as soon as possible.",
    "",
  ];

  const lines: string[] = [];
  const htmlItems: string[] = [];
  const items = recipient.items.slice(0, MAX_ITEMS_PER_EMAIL);
  for (let i = 0; i < items.length; i++) {
    const row = items[i];
    const snip = clip(row.summary, 120);
    const issueText = (row.issues ?? []).filter(Boolean).join(" · ") ||
      "Needs attention";
    const from = (row.sender_handle ?? "").trim();
    const fromLine = from ? `From @${from.replace(/^@/, "")}` : "Assigned to you";
    const openUrl = `${base}/?expectation=${row.expectation_id}`;
    lines.push(
      `${i + 1}. ${snip}`,
      `   ${fromLine}`,
      `   Issues: ${issueText}`,
      `   Open: ${openUrl}`,
      "",
    );
    htmlItems.push(
      `<li style="margin-bottom:12px">${escapeHtml(snip)}<br><span style="color:#555">${escapeHtml(fromLine)} · ${escapeHtml(issueText)}</span><br><a href="${escapeHtml(openUrl)}">Open in Exled</a></li>`,
    );
  }
  if (recipient.items.length > MAX_ITEMS_PER_EMAIL) {
    lines.push(
      `(+${recipient.items.length - MAX_ITEMS_PER_EMAIL} more — open Exled for the full list.)`,
      "",
    );
  }
  lines.push("Please address these ASAP.", "", "— Exled");

  const text = [...intro, ...lines].join("\n");
  const greeting = recipient.name
    ? `Hi ${escapeHtml(recipient.name)},`
    : "Hi,";
  const html = `<!DOCTYPE html>
<html><body style="font-family:system-ui,sans-serif;line-height:1.5;max-width:600px">
  <p>${greeting}</p>
  <p>The following expectations <strong>assigned to you</strong> are open and unhealthy (not accepted, no progress, at risk, off track, and/or no deadline). Please take action <strong>as soon as possible</strong>:</p>
  <ul>${htmlItems.join("")}</ul>
  <p>Please address these ASAP.</p>
  <p style="color:#666">— Exled</p>
</body></html>`;

  return { subject, text, html };
}

async function fetchDigestRows(
  supabaseUrl: string,
  serviceKey: string,
): Promise<DigestRow[]> {
  const url = `${supabaseUrl}/rest/v1/rpc/inled_morning_unhealthy_digest_rows`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`RPC inled_morning_unhealthy_digest_rows failed: ${res.status} ${txt.slice(0, 400)}`);
  }
  return (await res.json()) as DigestRow[];
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  trace("http_request", { method: req.method, path: url.pathname });

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

  if (
    supabaseUrl.startsWith("https://") || supabaseUrl.includes("be.exled.app") ||
    supabaseUrl.includes("tauworks.org")
  ) {
    supabaseUrl = (Deno.env.get("SUPABASE_INTERNAL_URL") ?? "http://kong:8000")
      .replace(/\/$/, "");
  }

  if (url.searchParams.get("health") === "1") {
    return jsonResponse({
      ok: Boolean(supabaseUrl && serviceKey),
      supabase_url: supabaseUrl,
      smtp_host: smtp.host,
    });
  }

  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: "SUPABASE_URL / SERVICE_ROLE_KEY missing" }, 500);
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "POST required with { \"run\": true }" }, 405);
  }

  let body: Record<string, unknown> = {};
  try {
    const raw = await req.text();
    if (raw.trim()) body = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const dryRun = body.dry_run === true || url.searchParams.get("dry_run") === "1";
  if (body.run !== true && body.run !== "true" && !dryRun) {
    return jsonResponse({
      error: 'Send { "run": true } or { "dry_run": true }',
    }, 400);
  }

  try {
    const rows = await fetchDigestRows(supabaseUrl, serviceKey);
    const groups = groupRows(rows);
    trace("digest_grouped", {
      rowCount: rows.length,
      recipientCount: groups.length,
      dryRun,
    });

    if (dryRun) {
      return jsonResponse({
        dry_run: true,
        row_count: rows.length,
        recipient_count: groups.length,
        recipients: groups.map((g) => ({
          email: g.email,
          name: g.name,
          expectation_count: g.items.length,
        })),
      });
    }

    const results: Array<{ email: string; ok: boolean; error?: string }> = [];
    for (const g of groups) {
      const mail = buildDigestEmail(g, appUrl);
      try {
        await sendSmtpMail(smtp, g.email, mail.subject, mail.text, mail.html);
        results.push({ email: g.email, ok: true });
        trace("digest_sent", { email: g.email, count: g.items.length });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        results.push({ email: g.email, ok: false, error: msg });
        trace("digest_send_error", { email: g.email, error: msg.slice(0, 300) });
      }
    }

    const failed = results.filter((r) => !r.ok);
    return jsonResponse({
      sent: results.length - failed.length,
      failed: failed.length,
      recipients: groups.length,
      results,
    }, failed.length > 0 ? 207 : 200);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("handler_error", { error: msg.slice(0, 500) });
    return jsonResponse({ error: msg }, 500);
  }
});
