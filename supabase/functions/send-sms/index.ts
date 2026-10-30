// Sends queued SMS notifications (public.sms_outbox) through httpSMS.
//
// The database calls this function (via pg_net) right after it queues a
// message, with the x-dispatch-secret header it keeps in private.sms_settings.
// Anyone else calling it is refused. The function takes pending messages and
// posts each one to https://api.httpsms.com/v1/messages/send; httpSMS then
// has the Android phone running the httpSMS app send it.
//
// The httpSMS API key and the sending phone are the ones the admin saved on
// the dashboard. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided
// automatically. Deploy with verify_jwt = false (the secret header is the
// authentication).

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const HTTPSMS_URL = "https://api.httpsms.com/v1/messages/send";
const BATCH = 20;
const MAX_BATCHES = 5;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function sameSecret(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

type Outbox = { id: string; to_phone: string; content: string };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data: config, error: configError } = await admin.rpc("sms_dispatch_config");
  if (configError || !config) return json({ error: "SMS settings unavailable" }, 500);
  if (!sameSecret(req.headers.get("x-dispatch-secret") ?? "", config.dispatch_secret ?? "")) {
    return json({ error: "Forbidden" }, 403);
  }
  // Switched off or not set up: leave messages queued (test messages included)
  // so nothing is lost; they go out once SMS is set up and the next one is queued.
  if (!config.api_key || !config.from_number) return json({ sent: 0, reason: "not configured" });

  let sent = 0, failed = 0;
  for (let batch = 0; batch < MAX_BATCHES; batch++) {
    const { data: rows, error } = await admin.rpc("sms_claim_batch", { p_limit: BATCH });
    if (error) return json({ error: "Could not read the SMS queue", sent, failed }, 500);
    if (!rows?.length) break;

    for (const row of rows as Outbox[]) {
      let ok = false, providerId: string | null = null, errorText: string | null = null;
      try {
        const res = await fetch(HTTPSMS_URL, {
          method: "POST",
          headers: {
            "x-api-key": config.api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
          },
          body: JSON.stringify({
            from: config.from_number,
            to: row.to_phone,
            content: row.content,
            request_id: row.id,
          }),
          signal: AbortSignal.timeout(15000),
        });
        const body = await res.json().catch(() => null);
        ok = res.ok;
        providerId = body?.data?.id ?? null;
        if (!ok) errorText = `HTTP ${res.status}: ${body?.message ?? "httpSMS refused the message"}`;
      } catch (e) {
        errorText = e instanceof Error ? e.message : String(e);
      }
      await admin.rpc("sms_mark", { p_id: row.id, p_ok: ok, p_provider_id: providerId, p_error: errorText });
      ok ? sent++ : failed++;
    }
    if (rows.length < BATCH) break;
  }
  return json({ sent, failed });
});
