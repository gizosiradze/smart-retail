// store-login: shop + username + password  ->  short-lived Supabase JWT with the store's claims.
//
// POST { "shop": "batumipets", "username": "kasa1", "password": "..." }
//   200 { "token": "...", "exp": 1767000000 }
//   401 { "error": "invalid_credentials" | "too_many_attempts" | "account_disabled" | "store_suspended" }
//
// The password is checked inside the database (public.sr_login, bcrypt, rate limits, lockout).
// This function only adds the signature, because the signing secret must never reach the browser.

import { corsHeaders, json } from "../_shared/http.ts";
import { signJwt } from "../_shared/jwt.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SR_SERVICE_KEY") ?? "";
const JWT_SECRET = Deno.env.get("APP_JWT_SECRET") ?? "";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);

  let body: { shop?: unknown; username?: unknown; password?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(req, { error: "bad_request" }, 400);
  }
  const shop = String(body.shop ?? "").trim().slice(0, 60);
  const username = String(body.username ?? "").trim().slice(0, 40);
  const password = String(body.password ?? "").slice(0, 200);
  if (!shop || !username || !password) return json(req, { error: "invalid_credentials" }, 401);

  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || null;
  const headers: Record<string, string> = { "Content-Type": "application/json", apikey: SERVICE_KEY };
  if (SERVICE_KEY.startsWith("eyJ")) headers.Authorization = `Bearer ${SERVICE_KEY}`; // legacy JWT-style key

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/sr_login`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      p_shop: shop, p_username: username, p_password: password,
      p_ip: ip, p_user_agent: req.headers.get("user-agent"),
    }),
  });
  if (!r.ok) {
    console.error("sr_login failed", r.status, await r.text());
    return json(req, { error: "server_error" }, 500);
  }
  const res = await r.json();
  if (!res.ok) return json(req, { error: res.error ?? "invalid_credentials" }, 401);

  const now = Math.floor(Date.now() / 1000);
  const token = await signJwt({
    iss: "smart-retail",
    aud: "authenticated",
    role: "authenticated",
    sub: res.user_id,
    app_uid: res.user_id,
    store_id: res.store_id,
    app_role: res.role,
    jti: res.jti,
    iat: now,
    exp: res.exp,
  }, JWT_SECRET);
  return json(req, { token, exp: res.exp });
});
