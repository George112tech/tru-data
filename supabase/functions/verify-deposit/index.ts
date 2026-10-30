// Verifies a Paystack wallet deposit server-to-server and credits the wallet.
//
// The browser only sends the Paystack reference. The amount credited is what
// Paystack says was actually paid, never what the browser claims.
//
// Deploy:  supabase functions deploy verify-deposit
// Secrets: supabase secrets set PAYSTACK_SECRET_KEY=sk_live_...
//          (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are
//          provided automatically.)

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const FEE_RATE = 0.035;
const MIN_DEPOSIT = 5;

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

  const res = await fetch(
    `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
    { headers: { Authorization: `Bearer ${Deno.env.get("PAYSTACK_SECRET_KEY")}` } },
  );
  if (!res.ok) return json({ error: "Could not verify payment" }, 502);
  const { data: tx } = await res.json();

  if (tx?.status !== "success") return json({ error: "Payment not successful" }, 400);
  if (tx.currency !== "GHS") return json({ error: "Unexpected currency" }, 400);
  if (tx.metadata?.user_id !== user.id) {
    return json({ error: "Payment does not belong to this account" }, 403);
  }

  // The page charges round(net * 1.035) pesewas, so dividing back and rounding
  // recovers the net amount (floor would turn 10.35 / 1.035 into 9.99).
  const paid = tx.amount / 100;
  const net = Math.round((paid / (1 + FEE_RATE)) * 100) / 100;
  const fee = Math.round((paid - net) * 100) / 100;
  if (net < MIN_DEPOSIT) return json({ error: "Below minimum deposit" }, 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: credited, error } = await admin.rpc("credit_deposit", {
    p_user: user.id,
    p_reference: reference,
    p_net: net,
    p_fee: fee,
  });
  if (error) return json({ error: "Could not credit wallet" }, 500);

  return json({ credited, amount: net });
});
