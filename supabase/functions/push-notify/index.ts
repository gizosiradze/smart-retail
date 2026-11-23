// push-notify: called by the database (triggers via pg_net) when something worth a notification happens.
//
// POST { store_id, kinds, title, body, tag, branch, amount, prev } with header x-push-secret
//   -> asks which admin devices want this event (public.sr_push_targets, service role)
//   -> sends a Web Push (VAPID) to each of them; removes subscriptions the push service reports gone.
// Secrets: PUSH_SECRET (same value as app.push_config.secret), VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT.

import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SR_SERVICE_KEY") ?? "";
const PUSH_SECRET = Deno.env.get("PUSH_SECRET") ?? "";
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@smartretail.ge";

const hdr: Record<string, string> = { "Content-Type": "application/json", apikey: SERVICE_KEY };
if (SERVICE_KEY.startsWith("eyJ")) hdr.Authorization = `Bearer ${SERVICE_KEY}`;
const rpc = (fn: string, args: unknown) =>
  fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers: hdr, body: JSON.stringify(args) });

function same(a: string, b: string) {   // constant-time-ish compare
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method_not_allowed", { status: 405 });
  if (!PUSH_SECRET || !VAPID_PUBLIC || !VAPID_PRIVATE) return new Response("not_configured", { status: 503 });
  if (!same(req.headers.get("x-push-secret") ?? "", PUSH_SECRET)) return new Response("forbidden", { status: 403 });

  // { store_id, kinds: ["sale","big"], title, body, tag, branch, amount, prev } built by the database triggers
  // (see supabase/migrations/20261123000013_push_preferences.sql); the devices' own preferences decide who gets it.
  let e: Record<string, unknown> = {};
  try { e = await req.json(); } catch { /* falls through */ }
  const kinds = Array.isArray(e.kinds) ? e.kinds.map(String).filter((k) => /^[a-z]{2,5}$/.test(k)) : [];
  if (!/^[0-9a-f-]{36}$/i.test(String(e.store_id ?? "")) || !kinds.length || !e.title) return new Response("bad_request", { status: 400 });

  const r = await rpc("sr_push_targets", {
    p_store: e.store_id, p_kinds: kinds, p_branch: e.branch ?? null,
    p_amount: e.amount ?? null, p_prev: e.prev ?? null,
  });
  if (!r.ok) { console.error("sr_push_targets", r.status, await r.text()); return new Response("server_error", { status: 500 }); }
  const subs = await r.json();
  if (!Array.isArray(subs) || !subs.length) return new Response("nothing_to_send", { status: 200 });

  const payload = JSON.stringify({
    title: String(e.title).slice(0, 120),
    body: String(e.body ?? "").slice(0, 240),
    tag: String(e.tag ?? "").slice(0, 100) || undefined,
    url: "./",
  });
  const d = { subs };

  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
  const gone: string[] = [];
  await Promise.all(d.subs.map(async (sub: { id: string; endpoint: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, payload, { TTL: 3600, urgency: "high" });
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) gone.push(sub.id); else console.error("push failed", code);
    }
  }));
  if (gone.length) await rpc("sr_push_prune", { p_ids: gone });
  return new Response("ok", { status: 200 });
});
