// Verifies an online (Paystack) wallet deposit server-to-server and credits the wallet.
//
// The online fee covers Paystack's charge, which Paystack takes from the WHOLE
// amount paid. So the page asks for total = deposit / (1 - rate), and here the
// deposit is total * (1 - rate): to get GHS 100.00 at 3.5% the customer pays
// GHS 103.63, Paystack keeps 3.5% of that, and GHS 100.00 is credited.
// (Adding 3.5% of the deposit on top, GHS 103.50, left the business short.)
// The rate is the admin's "online_fee_percent" setting (default 3.5).
//
// The browser only sends the Paystack reference. The amount credited is what
// Paystack says was actually paid, never what the browser claims.
//
// The Paystack secret key is the one the admin saved on the dashboard
// (Deposits tab); the PAYSTACK_SECRET_KEY function secret is the fallback.
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided
// automatically.
//
// Payments are still credited when the admin has switched Paystack off, so a
// customer who paid just before the switch is not left out.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const DEFAULT_FEE_PERCENT = 3.5;
const OLD_FEE_RATE = 0.035; // payments started on the page before this change
const MIN_DEPOSIT = 5;

function round2(n: number) {
  return Math.round(n * 100) / 100;
}

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

  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Not authenticated" }, 401);

  const { reference } = await req.json().catch(() => ({}));
  if (typeof reference !== "string" || !/^[A-Za-z0-9_.=-]{1,100}$/.test(reference)) {
    return json({ error: "Invalid reference" }, 400);
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: savedKey } = await admin.rpc("get_paystack_secret_key");
  const secretKey = savedKey || Deno.env.get("PAYSTACK_SECRET_KEY");
  if (!secretKey) return json({ error: "Paystack is not configured" }, 503);

  const res = await fetch(
    `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
    { headers: { Authorization: `Bearer ${secretKey}` } },
  );
  if (!res.ok) return json({ error: "Could not verify payment" }, 502);
  const { data: tx } = await res.json();

  if (tx?.status !== "success") return json({ error: "Payment not successful" }, 400);
  if (tx.currency !== "GHS") return json({ error: "Unexpected currency" }, 400);
  if (tx.metadata?.user_id !== user.id) {
    return json({ error: "Payment does not belong to this account" }, 403);
  }

  const paid = tx.amount / 100;
  let net: number;
  if (tx.metadata?.fee_method === "gross_up") {
    // The current rate from the database, never one sent by the browser.
    const { data: setting } = await admin.from("app_settings")
      .select("value").eq("key", "online_fee_percent").maybeSingle();
    const pct = typeof setting?.value === "number" && setting.value >= 0 && setting.value <= 10
      ? setting.value
      : DEFAULT_FEE_PERCENT;
    // The page charges round2(deposit / (1 - rate)); rounding the reverse
    // recovers the deposit exactly (the rounding error is under half a pesewa).
    net = round2(paid * (1 - pct / 100));
  } else {
    // Started on the old page, which charged round2(deposit * 1.035).
    net = round2(paid / (1 + OLD_FEE_RATE));
  }
  const fee = round2(paid - net);
  if (net < MIN_DEPOSIT) return json({ error: "Below minimum deposit" }, 400);

  const { data: credited, error } = await admin.rpc("credit_deposit", {
    p_user: user.id,
    p_reference: reference,
    p_net: net,
    p_fee: fee,
  });
  if (error) return json({ error: "Could not credit wallet" }, 500);

  return json({ credited, amount: net });
});
