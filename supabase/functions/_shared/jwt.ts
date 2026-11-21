// HS256 JSON Web Token signing with Web Crypto (no dependencies).
// The secret must be the project's JWT secret so that PostgREST, Storage and Realtime accept the token.

const enc = new TextEncoder();

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function signJwt(payload: Record<string, unknown>, secret: string): Promise<string> {
  if (!secret || secret.length < 32) throw new Error("APP_JWT_SECRET is missing or shorter than 32 characters");
  const header = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${header}.${body}`)));
  return `${header}.${body}.${b64url(sig)}`;
}
