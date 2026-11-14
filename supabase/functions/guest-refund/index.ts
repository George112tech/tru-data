// Refunds a guest's Paystack payment (admins only).
//
// POST { ref: "ORD-XXXXXXXX" }  with the admin's sign-in token.
// The order must be a guest order paid with Paystack that has not been
// refunded yet (guest_refund_claim checks this and marks it "requesting", so
// two clicks cannot refund twice). Paystack is asked to refund the whole
// payment to the MoMo or card it came from; Paystack's webhook later reports
// when it is done (paystack-webhook -> guest_refund_webhook).
//
// Answers { ok: true, status, amount } or { error } (HTTP 4xx/5xx). The
// dashboard cancels the order itself after a successful refund.
//
// The Paystack secret key is the one the admin saved on the dashboard; the
// PAYSTACK_SECRET_KEY function secret is the fallback. SUPABASE_URL,
// SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const STATUSES = new Set(["pending", "processing", "processed", "failed"]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const body = await req.json().catch(() => ({}));
  const ref = String(body?.ref ?? "").trim().toUpperCase();
  if (!/^ORD-[A-Z0-9]{4,12}$/.test(ref)) return json({ error: "Invalid order number" }, 400);

  // Only a signed-in admin.
  const asCaller = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: isAdmin } = await asCaller.rpc("is_admin");
  if (isAdmin !== true) return json({ error: "Admins only" }, 403);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: savedKey } = await admin.rpc("get_paystack_secret_key");
  const secretKey = savedKey || Deno.env.get("PAYSTACK_SECRET_KEY");
  if (!secretKey) return json({ error: "The Paystack secret key is not saved (Admin > Deposits > Paystack)." }, 503);

  const { data: claim, error: claimErr } = await admin.rpc("guest_refund_claim", { p_ref: ref });
  if (claimErr) return json({ error: claimErr.message }, 409);
  const reference = String(claim?.reference ?? "");

  const fail = async (why: string, status = 400) => {
    await admin.rpc("guest_refund_set", { p_ref: ref, p_status: "failed", p_error: why });
    return json({ error: why }, status);
  };

  let res: Response, out: any;
  try {
    res = await fetch("https://api.paystack.co/refund", {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        transaction: reference,
        merchant_note: `TRU Data order ${ref} cancelled`,
        customer_note: "Your TRU Data order was cancelled. This is your refund.",
      }),
    });
    out = await res.json().catch(() => ({}));
  } catch {
    return fail("Could not reach Paystack. Try again in a moment.", 502);
  }

  if (!res.ok || out?.status !== true) {
    const msg = String(out?.message ?? `Paystack answered ${res.status}`);
    // Already refunded in the Paystack dashboard: record it as done.
    if (/fully reversed|already been refunded|already refunded/i.test(msg)) {
      await admin.rpc("guest_refund_set", { p_ref: ref, p_status: "processed", p_amount: claim?.paid ?? null });
      return json({ ok: true, status: "processed", amount: claim?.paid ?? null, note: "Paystack says this payment was already refunded." });
    }
    console.error("paystack refund failed", ref, reference, res.status, JSON.stringify(out).slice(0, 600));
    return fail("Paystack refused the refund: " + msg.slice(0, 200));
  }

  const d = out.data ?? {};
  const st = String(d.status ?? "pending").toLowerCase();
  const status = STATUSES.has(st) ? st : "pending";
  const amount = Number.isFinite(Number(d.amount)) ? Math.round(Number(d.amount)) / 100 : (claim?.paid ?? null);
  await admin.rpc("guest_refund_set", {
    p_ref: ref, p_status: status, p_amount: amount, p_refund_id: d.id != null ? String(d.id) : null,
  });
  return json({ ok: true, status, amount });
});
