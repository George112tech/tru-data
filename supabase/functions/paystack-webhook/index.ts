// Paystack's webhook: Paystack itself tells TRU Data when a payment succeeds.
//
// Set it once in the Paystack dashboard: Settings → API Keys & Webhooks →
// Live Webhook URL:
//   https://kefcmjfvrqbgtivssdwn.supabase.co/functions/v1/paystack-webhook
//
// It makes a guest's order as soon as Paystack confirms the payment, even if
// the customer closed the page before it was confirmed there.
//
// Every call is checked: the x-paystack-signature header must be the
// HMAC-SHA512 of the body with the Paystack secret key, so only Paystack can
// use it. The payment is then looked up again with Paystack before the order
// is made (guest_complete makes it once per reference). Events that are not
// guest payments (GST-...) are acknowledged and ignored.
//
// Deployed with verify_jwt off: Paystack sends no Supabase token; the
// signature is the check.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const REF = /^GST-[A-Z0-9]{12}$/;

function hex(buf: ArrayBuffer) {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const raw = await req.text();
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
  const { data: savedKey } = await admin.rpc("get_paystack_secret_key");
  const secretKey = savedKey || Deno.env.get("PAYSTACK_SECRET_KEY");
  if (!secretKey) return new Response("Not set up", { status: 503 });

  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secretKey), { name: "HMAC", hash: "SHA-512" }, false, ["sign"],
  );
  const expected = hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const given = (req.headers.get("x-paystack-signature") ?? "").toLowerCase();
  if (!sameText(expected, given)) return new Response("Bad signature", { status: 401 });

  let event: { event?: string; data?: { reference?: string } } = {};
  try { event = JSON.parse(raw); } catch { return new Response("ok"); }
  const reference = event?.data?.reference;
  if (event.event !== "charge.success" || typeof reference !== "string" || !REF.test(reference)) {
    return new Response("ok");
  }

  // Ask Paystack again rather than trusting the event's amount.
  let tx: Record<string, unknown> | null = null;
  try {
    const res = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${secretKey}` } },
    );
    tx = res.ok ? ((await res.json())?.data ?? null) : null;
  } catch { /* answered below */ }
  // A non-2xx answer makes Paystack send the event again later.
  if (!tx) return new Response("Could not verify", { status: 502 });
  if (tx.reference !== reference || tx.status !== "success" || tx.currency !== "GHS") return new Response("ok");

  const { data, error } = await admin.rpc("guest_complete", {
    p_reference: reference,
    p_paid_pesewas: Number(tx.amount),
    p_paystack_id: String(tx.id ?? ""),
  });
  if (error) {
    // Unknown reference (not one of ours): nothing to retry.
    if (/Unknown payment reference/.test(error.message ?? "")) return new Response("ok");
    return new Response("Could not create the order", { status: 500 });
  }
  return new Response(JSON.stringify({ ok: true, order_ref: data?.order_ref ?? null }), {
    headers: { "Content-Type": "application/json" },
  });
});
