// push-notify: called by the database (trigger on app.sales via pg_net) when a sale is recorded.
//
// POST { "sale_id": "<uuid>" } with header x-push-secret
//   -> reads the sale + the store admins' subscriptions (public.sr_push_prepare, service role)
//   -> sends a Web Push (VAPID) to each admin device; removes subscriptions the push service reports gone.
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

const money = (n: number) => (Math.round(n * 100) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method_not_allowed", { status: 405 });
  if (!PUSH_SECRET || !VAPID_PUBLIC || !VAPID_PRIVATE) return new Response("not_configured", { status: 503 });
  if (!same(req.headers.get("x-push-secret") ?? "", PUSH_SECRET)) return new Response("forbidden", { status: 403 });

  let saleId = "";
  try { saleId = String((await req.json()).sale_id ?? ""); } catch { /* falls through */ }
  if (!/^[0-9a-f-]{36}$/i.test(saleId)) return new Response("bad_request", { status: 400 });

  const r = await rpc("sr_push_prepare", { p_sale: saleId });
  if (!r.ok) { console.error("sr_push_prepare", r.status, await r.text()); return new Response("server_error", { status: 500 }); }
  const d = await r.json();
  if (!d || !d.subs?.length) return new Response("nothing_to_send", { status: 200 });

  const s = d.sale, total = Number(s.total) || 0, isRet = s.ret != null || total < 0;
  const payload = JSON.stringify({
    title: `${isRet ? "დაბრუნება" : "გაყიდვა"} · ${s.branch || s.store}`,
    body: `${money(Math.abs(total))} ₾${isRet ? " (დაბრუნება)" : ""} · ${s.method || ""}${s.user ? " · " + s.user : ""}`,
    tag: `sale-${s.id}`,
    url: "./",
  });

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
