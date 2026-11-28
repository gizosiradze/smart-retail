// health: a public address for the uptime check (UptimeRobot, BetterStack, ...).
//   GET https://<project-ref>.supabase.co/functions/v1/health   ->  200 "ok" when the database answers,
//                                                                   503 "down" otherwise.
// It reveals nothing else. Supabase sets SUPABASE_URL and SUPABASE_ANON_KEY for every function itself.

const URL_ = Deno.env.get("SUPABASE_URL") ?? "";
const KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

Deno.serve(async () => {
  const h = { "Content-Type": "text/plain", "Cache-Control": "no-store" };
  try {
    const r = await fetch(`${URL_}/rest/v1/rpc/sr_health`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: KEY, Authorization: `Bearer ${KEY}` },
      body: "{}",
      signal: AbortSignal.timeout(8000),
    });
    const j = r.ok ? await r.json() : null;
    if (j && j.ok === true && j.db === true) return new Response("ok", { status: 200, headers: h });
  } catch (_) { /* falls through */ }
  return new Response("down", { status: 503, headers: h });
});
