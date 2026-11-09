// Confirms a guest's Paystack payment and creates their order.
//
// The guest page opens Paystack with a reference made by guest_start()
// (GST-XXXXXXXXXXXX), then sends that reference here. This function asks
// Paystack, with the secret key, whether it was paid: the browser is never
// trusted. If it was, guest_complete() creates the order (once per reference,
// whatever the number of calls) and the receipt is returned.
//
// Answers:
//   { paid: true, order_ref, status, bundle_name, network, phone, paid, ... }
//   { paid: false, status: "ongoing" | "pending" | "abandoned" | "failed" | ... }
//   { error }   (with HTTP 400/5xx)
//
// The Paystack secret key is the one the admin saved on the dashboard; the
// PAYSTACK_SECRET_KEY function secret is the fallback. SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are provided automatically. Guests have no
// account, so any caller with the site's public key may call it; it can only
// turn a real, fully paid Paystack payment into its one order.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const { reference } = await req.json().catch(() => ({}));
  if (typeof reference !== "string" || !/^GST-[A-Z0-9]{12}$/.test(reference)) {
    return json({ error: "Invalid payment reference" }, 400);
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
  const { data: savedKey } = await admin.rpc("get_paystack_secret_key");
  const secretKey = savedKey || Deno.env.get("PAYSTACK_SECRET_KEY");
  if (!secretKey) return json({ error: "Online payments are not set up" }, 503);

  let tx: Record<string, unknown> | null = null;
  try {
    const res = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${secretKey}` } },
    );
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      // Paystack does not know the reference yet (payment not started or not finished).
      if (res.status === 400 || res.status === 404) return json({ paid: false, status: "not_found" });
      return json({ error: "Could not reach Paystack. Try again in a moment." }, 502);
    }
    tx = body?.data ?? null;
  } catch {
    return json({ error: "Could not reach Paystack. Try again in a moment." }, 502);
  }

  if (!tx || tx.reference !== reference) return json({ error: "Payment not found" }, 400);
  if (tx.status !== "success") return json({ paid: false, status: String(tx.status ?? "unknown") });
  if (tx.currency !== "GHS") return json({ error: "Unexpected currency" }, 400);

  const { data, error } = await admin.rpc("guest_complete", {
    p_reference: reference,
    p_paid_pesewas: Number(tx.amount),
    p_paystack_id: String(tx.id ?? ""),
  });
  if (error) return json({ error: "Your payment was received but the order could not be created. Contact support with reference " + reference }, 500);
  if (data?.error === "underpaid") {
    return json({ error: "The amount paid is less than the price, so no order was made. Contact support with reference " + reference }, 400);
  }
  return json({ ...data, paid: true });
});
