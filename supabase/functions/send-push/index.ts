// Sends queued push notifications (push_outbox) to the TRU Data app through
// Firebase Cloud Messaging (HTTP v1).
//
// Woken by the database (pg_net, header x-dispatch-secret) when a
// notification is queued, and every minute by pg_cron while any are waiting.
// Deployed with verify_jwt off: the dispatch secret is the check.
//
// Needs the FCM_SERVICE_ACCOUNT secret on the Edge Functions: the whole JSON
// key of a Firebase service account (Firebase console -> Project settings ->
// Service accounts -> Generate new private key). Until it is set, nothing is
// sent and notifications wait (and expire after an hour).
//
// Each notification goes to every phone of its customer. A phone whose token
// Firebase no longer knows (app removed, data cleared) is forgotten.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type ServiceAccount = { project_id: string; client_email: string; private_key: string; token_uri?: string };

function b64url(data: ArrayBuffer | Uint8Array | string) {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

let cached: { token: string; until: number } | null = null;

// An OAuth access token for FCM, from the service account (signed JWT, RS256).
async function accessToken(sa: ServiceAccount): Promise<string> {
  if (cached && cached.until > Date.now() + 60_000) return cached.token;
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";
  const unsigned = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" })) + "." + b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUri,
    iat: now,
    exp: now + 3600,
  }));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: unsigned + "." + b64url(sig),
    }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || !out.access_token) throw new Error("Google sign-in failed: " + (out.error_description || out.error || res.status));
  cached = { token: out.access_token, until: Date.now() + (Number(out.expires_in) || 3600) * 1000 };
  return cached.token;
}

// Firebase's data values must be strings.
function strings(o: Record<string, unknown>) {
  const r: Record<string, string> = {};
  for (const [k, v] of Object.entries(o || {})) if (v != null) r[k] = String(v);
  return r;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: ok } = await admin.rpc("push_dispatch_secret_ok", { p_secret: req.headers.get("x-dispatch-secret") ?? "" });
  if (ok !== true) return json({ error: "Not allowed" }, 401);

  let sa: ServiceAccount;
  try {
    sa = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT") || "");
    if (!sa.project_id || !sa.client_email || !sa.private_key) throw new Error("incomplete");
  } catch {
    return json({ error: "FCM_SERVICE_ACCOUNT is not set (or is not the service account's JSON key)" }, 503);
  }

  let bearer: string;
  try {
    bearer = await accessToken(sa);
  } catch (e) {
    console.error("fcm auth", String(e));
    return json({ error: String(e) }, 502);
  }

  const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  let sent = 0, failed = 0, rounds = 0, wait = false;
  // A notification put back after a temporary Firebase error waits for the next run (every minute).
  while (rounds++ < 5 && !wait) {
    const { data: batch, error } = await admin.rpc("push_claim", { p_limit: 50 });
    if (error) return json({ error: error.message }, 500);
    const items = (batch ?? []) as { id: string; title: string; body: string; data: Record<string, unknown>; tokens: string[] }[];
    if (!items.length) break;

    for (const n of items) {
      if (!n.tokens?.length) {
        await admin.rpc("push_mark", { p_id: n.id, p_status: "no_device" });
        continue;
      }
      const data = strings(n.data);
      let delivered = 0, lastError = "", retry = false;
      for (const token of n.tokens) {
        const res = await fetch(endpoint, {
          method: "POST",
          headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: n.title, body: n.body },
              data: { ...data, title: n.title, body: n.body },
              android: {
                priority: "HIGH",
                ttl: "3600s",
                notification: {
                  channel_id: "orders",
                  icon: "ic_notification",
                  color: "#DC2626",
                  sound: "default",
                  tag: data.ref ? `order-${data.ref}` : undefined,
                  default_vibrate_timings: true,
                },
              },
            },
          }),
        }).catch(() => null);
        if (res && res.ok) { delivered++; continue; }
        const out = res ? await res.json().catch(() => ({})) : {};
        const code = String(out?.error?.status ?? "");
        const detail = JSON.stringify(out?.error?.details ?? "");
        lastError = res ? `${res.status} ${out?.error?.message ?? code}`.slice(0, 280) : "Could not reach Firebase";
        // The app was removed or its data cleared: forget this phone.
        if (res && (res.status === 404 || code === "NOT_FOUND" || /UNREGISTERED/.test(detail) ||
            (res.status === 400 && /registration token|INVALID_ARGUMENT/i.test(lastError + detail)))) {
          await admin.rpc("push_drop_token", { p_token: token });
        } else if (!res || res.status === 429 || res.status >= 500) {
          retry = true;
        }
      }
      if (delivered > 0) { sent++; await admin.rpc("push_mark", { p_id: n.id, p_status: "sent" }); }
      else { failed++; if (retry) wait = true; await admin.rpc("push_mark", { p_id: n.id, p_status: retry ? "pending" : "failed", p_error: lastError }); }
    }
    if (items.length < 50) break;
  }
  return json({ sent, failed });
});
