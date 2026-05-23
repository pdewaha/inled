// Sends invite email after app creates a row in `invites`.
// POST { "invite_id": "<uuid>" } with inviter's JWT (or service role).
// Deploy: volumes/functions/send-invite-email/index.ts

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

type InviteRow = {
  id: string;
  company_id: string;
  email: string;
  token_hash: string;
  invited_by_user_id: string;
  expires_at: string;
};

type PendingItem = {
  item_kind: string;
  expectation_id: string;
  summary: string;
  sender_handle: string;
  status_note: string;
};

const SMTP_TOTAL_MS = 90000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function trace(event: string, data?: Record<string, unknown>) {
  console.log(
    JSON.stringify({
      svc: "send-invite-email-trace",
      event,
      ts: new Date().toISOString(),
      ...(data ?? {}),
    }),
  );
}

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
    pool: false,
    connectionTimeout: 15000,
    greetingTimeout: 45000,
    socketTimeout: 90000,
    requireTLS: !cfg.secure && cfg.port !== 465,
    tls: { minVersion: "TLSv1.2" as const },
  });
  try {
    await withTimeout(
      transporter.sendMail({ from: cfg.from, to, subject, text, html }),
      SMTP_TOTAL_MS,
      "SMTP sendMail",
    );
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
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function parsePersonIdFromToken(tokenHash: string): string | null {
  const prefix = "personalized:";
  if (!tokenHash.startsWith(prefix)) return null;
  const rest = tokenHash.slice(prefix.length);
  const uuid = rest.split(":")[0]?.trim();
  if (!uuid || !/^[0-9a-f-]{36}$/i.test(uuid)) return null;
  return uuid;
}

function decodeJwtSub(authHeader: string | null): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice(7).trim();
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const payload = JSON.parse(
      atob(parts[1].replaceAll("-", "+").replaceAll("_", "/")),
    );
    const sub = payload?.sub;
    return typeof sub === "string" ? sub : null;
  } catch {
    return null;
  }
}

async function supabaseRest<T>(
  path: string,
  init: RequestInit & { serviceRole?: boolean } = {},
): Promise<T> {
  const base = Deno.env.get("SUPABASE_URL")?.replace(/\/$/, "");
  const key = init.serviceRole
    ? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    : Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !key) throw new Error("SUPABASE_URL or API key missing");
  const headers = new Headers(init.headers);
  headers.set("apikey", key);
  headers.set("Authorization", `Bearer ${key}`);
  headers.set("Content-Type", "application/json");
  const res = await fetch(`${base}/rest/v1/${path}`, { ...init, headers });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`REST ${path}: ${res.status} ${body.slice(0, 400)}`);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

function buildInviteBodies(opts: {
  companyName: string;
  inviterLabel: string;
  inviteeEmail: string;
  appUrl: string;
  inviteId: string;
  personHandle: string | null;
  pending: PendingItem[];
}): { subject: string; text: string; html: string } {
  const signInUrl = `${opts.appUrl.replace(/\/$/, "")}/?invite=${opts.inviteId}`;
  const who = opts.personHandle ? `@${opts.personHandle}` : opts.inviteeEmail;
  const subject = opts.personHandle
    ? `${opts.inviterLabel} invited you to Exled (${who})`
    : `${opts.inviterLabel} invited you to join ${opts.companyName} on Exled`;

  const intro = opts.personHandle
    ? `${opts.inviterLabel} invited you to join ${opts.companyName} on Exled as ${who}.`
    : `${opts.inviterLabel} invited you to join ${opts.companyName} on Exled.`;

  const lines: string[] = [
    intro,
    "",
    `Sign in with ${opts.inviteeEmail}:`,
    signInUrl,
    "",
  ];

  if (opts.pending.length > 0) {
    lines.push("Already waiting for you:");
    for (const item of opts.pending) {
      const kind = item.item_kind === "talking_point"
        ? "Talking point"
        : "Expectation";
      lines.push(
        `- ${kind}: ${item.summary} (from @${item.sender_handle}) — ${item.status_note}`,
      );
    }
    lines.push("");
  }

  lines.push(
    "After you sign in, your account will be linked to the items above.",
    "",
    "This invite expires in 14 days.",
  );

  const text = lines.join("\n");

  let itemsHtml = "";
  if (opts.pending.length > 0) {
    const lis = opts.pending.map((item) => {
      const kind = item.item_kind === "talking_point"
        ? "Talking point"
        : "Expectation";
      return `<li><strong>${escapeHtml(kind)}</strong>: ${escapeHtml(item.summary)}<br><span style="color:#666">From @${escapeHtml(item.sender_handle)} — ${escapeHtml(item.status_note)}</span></li>`;
    }).join("");
    itemsHtml = `<p><strong>Already waiting for you:</strong></p><ul>${lis}</ul>`;
  }

  const html = `<!DOCTYPE html><html><body style="font-family:system-ui,sans-serif;line-height:1.5;color:#111">
<p>${escapeHtml(intro)}</p>
<p><a href="${escapeHtml(signInUrl)}">Sign in with ${escapeHtml(opts.inviteeEmail)}</a></p>
${itemsHtml}
<p style="color:#666;font-size:14px">After you sign in, your account will be linked to any items listed above. This invite expires in 14 days.</p>
</body></html>`;

  return { subject, text, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "POST required" }, 405);
  }

  let body: { invite_id?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const inviteId = body.invite_id?.trim();
  if (!inviteId) {
    return jsonResponse({ error: "invite_id required" }, 400);
  }

  const authHeader = req.headers.get("authorization");
  const callerSub = decodeJwtSub(authHeader);
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  const bearer = authHeader?.startsWith("Bearer ")
    ? authHeader.slice(7).trim()
    : "";
  const isServiceRole = !!(serviceKey && bearer === serviceKey);

  if (!isServiceRole && !callerSub) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  trace("invite_send_begin", { inviteId, isServiceRole });

  try {
    const invites = await supabaseRest<InviteRow[]>(
      `invites?id=eq.${inviteId}&select=id,company_id,email,token_hash,invited_by_user_id,expires_at&limit=1`,
      { serviceRole: true },
    );
    const invite = invites[0];
    if (!invite) {
      return jsonResponse({ error: "Invite not found" }, 404);
    }

    if (!isServiceRole && callerSub !== invite.invited_by_user_id) {
      return jsonResponse({ error: "Not allowed to send this invite" }, 403);
    }

    const expires = new Date(invite.expires_at);
    if (expires.getTime() < Date.now()) {
      return jsonResponse({ error: "Invite expired" }, 410);
    }

    const companies = await supabaseRest<{ name: string }[]>(
      `companies?id=eq.${invite.company_id}&select=name&limit=1`,
      { serviceRole: true },
    );
    const companyName = companies[0]?.name?.trim() || "your organisation";

    const inviters = await supabaseRest<
      { display_name: string | null; handle: string | null }[]
    >(
      `people?auth_user_id=eq.${invite.invited_by_user_id}&company_id=eq.${invite.company_id}&select=display_name,handle&limit=1`,
      { serviceRole: true },
    );
    const inv = inviters[0];
    const inviterLabel = inv?.display_name?.trim() ||
      (inv?.handle?.trim() ? `@${inv.handle.trim()}` : "Someone");

    const personId = parsePersonIdFromToken(invite.token_hash);
    let personHandle: string | null = null;
    let pending: PendingItem[] = [];

    if (personId) {
      const people = await supabaseRest<
        { handle: string | null; email: string | null }[]
      >(
        `people?id=eq.${personId}&company_id=eq.${invite.company_id}&select=handle,email&limit=1`,
        { serviceRole: true },
      );
      const person = people[0];
      if (person) {
        personHandle = person.handle?.trim() || null;
        pending = await supabaseRest<PendingItem[]>(
          `rpc/inled_invite_pending_items_for_person`,
          {
            method: "POST",
            serviceRole: true,
            body: JSON.stringify({
              p_company_id: invite.company_id,
              p_person_id: personId,
            }),
          },
        );
      }
    }

    const smtp = readSmtpConfig();
    if ("error" in smtp) {
      return jsonResponse({ error: smtp.error }, 503);
    }

    const appUrl = Deno.env.get("EXLED_APP_URL") ?? "https://be.exled.app";
    const mail = buildInviteBodies({
      companyName,
      inviterLabel,
      inviteeEmail: invite.email.trim(),
      appUrl,
      inviteId: invite.id,
      personHandle,
      pending: pending ?? [],
    });

    await sendSmtpMail(
      smtp,
      invite.email.trim(),
      mail.subject,
      mail.text,
      mail.html,
    );

    trace("invite_send_ok", {
      inviteId,
      to: invite.email,
      pendingCount: pending.length,
    });

    return jsonResponse({
      sent: true,
      invite_id: invite.id,
      pending_count: pending.length,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace("invite_send_error", { inviteId, error: msg.slice(0, 500) });
    return jsonResponse({ error: msg }, 500);
  }
});
