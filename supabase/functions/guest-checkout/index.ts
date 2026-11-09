// Confirms guest Paystack payments and creates their orders.
//
// The guest page opens Paystack with a reference made by guest_start()
// (GST-XXXXXXXXXXXX), then sends that reference here. This function asks
// Paystack, with the secret key, whether it was paid: the browser is never
// trusted. If it was, guest_complete() creates the order (once per reference,
// whatever the number of calls) and the receipt is returned.
//
// Two ways to call it:
//   { reference }        one payment (the guest's page). Answers:
//       { paid: true, order_ref, status, bundle_name, network, phone, amount_paid, ... }
//       { paid: false, status: "ongoing" | "pending" | "abandoned" | "failed" | "not_found" | ... }
//       { error }   (with HTTP 400/5xx)
//   { reconcile: true }  admins only (the dashboard calls it when it opens):
//       checks every guest payment still pending from the last 3 days, so a
//       payment whose page was closed before it was confirmed still becomes
//       its order. Answers { checked, created: [order refs], still_pending }.
//
// The paystack-webhook function is the third route (Paystack calls it).
//
// The Paystack secret key is the one the admin saved on the dashboard; the
// PAYSTACK_SECRET_KEY function secret is the fallback. SUPABASE_URL,
// SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
// Guests have no account, so any caller with the site's public key may check
// one reference; it can only turn a real, fully paid Paystack payment into its
// one order.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2.45.4";

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

const REF = /^GST-[A-Z0-9]{12}$/;
const UNPAID = ["failed", "abandoned", "reversed"];

type Check =
  | { kind: "paid"; data: Record<string, unknown> }
  | { kind: "unpaid"; status: string }
  | { kind: "error"; status: number; error: string };

// Asks Paystack about one reference and, if it was paid in full, makes the order.
async function check(admin: SupabaseClient, secretKey: string, reference: string): Promise<Check> {
  let tx: Record<string, unknown> | null = null;
  try {
    const res = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${secretKey}` } },
    );
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      // Paystack does not know the reference yet (payment not started or not finished).
      if (res.status === 400 || res.status === 404) return { kind: "unpaid", status: "not_found" };
      return { kind: "error", status: 502, error: "Could not reach Paystack. Try again in a moment." };
    }
    tx = body?.data ?? null;
  } catch {
    return { kind: "error", status: 502, error: "Could not reach Paystack. Try again in a moment." };
  }

  if (!tx || tx.reference !== reference) return { kind: "error", status: 400, error: "Payment not found" };
  if (tx.status !== "success") return { kind: "unpaid", status: String(tx.status ?? "unknown") };
  if (tx.currency !== "GHS") return { kind: "error", status: 400, error: "Unexpected currency" };

  const { data, error } = await admin.rpc("guest_complete", {
    p_reference: reference,
    p_paid_pesewas: Number(tx.amount),
    p_paystack_id: String(tx.id ?? ""),
  });
  if (error) {
    return { kind: "error", status: 500, error: "Your payment was received but the order could not be created. Contact support with reference " + reference };
  }
  if (data?.error === "underpaid") {
    return { kind: "error", status: 400, error: "The amount paid is less than the price, so no order was made. Contact support with reference " + reference };
  }
  return { kind: "paid", data: data ?? {} };
}

async function reconcile(req: Request, admin: SupabaseClient, secretKey: string) {
  // Only a signed-in admin may run it.
  const auth = req.headers.get("Authorization") ?? "";
  const asCaller = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
    global: { headers: { Authorization: auth } },
  });
  const { data: isAdmin } = await asCaller.rpc("is_admin");
  if (isAdmin !== true) return json({ error: "Admins only" }, 403);

  const { data: refs, error } = await admin.rpc("guest_pending_references", { p_days: 3 });
  if (error) return json({ error: "Could not list pending payments" }, 500);

  const created: string[] = [];
  const problems: string[] = [];
  let stillPending = 0;
  for (const reference of (refs ?? []) as string[]) {
    const r = await check(admin, secretKey, reference);
    if (r.kind === "paid") {
      if (!r.data.already && typeof r.data.order_ref === "string") created.push(r.data.order_ref);
    } else if (r.kind === "unpaid") {
      // Paystack says it was not paid: stop checking it once it is a day old.
      if (UNPAID.includes(r.status)) {
        const { data: marked } = await admin.rpc("guest_mark_unpaid", { p_reference: reference, p_status: r.status });
        if (!marked) stillPending++;
      } else stillPending++;
    } else {
      problems.push(`${reference}: ${r.error}`);
      stillPending++;
    }
  }
  return json({ checked: (refs ?? []).length, created, still_pending: stillPending, problems });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const body = await req.json().catch(() => ({}));
  const reference = body?.reference;
  const wantsReconcile = body?.reconcile === true;
  if (!wantsReconcile && (typeof reference !== "string" || !REF.test(reference))) {
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

  if (wantsReconcile) return reconcile(req, admin, secretKey);

  const r = await check(admin, secretKey, reference);
  if (r.kind === "paid") return json({ ...r.data, paid: true });
  if (r.kind === "unpaid") return json({ paid: false, status: r.status });
  return json({ error: r.error }, r.status);
});
