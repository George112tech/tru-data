// SeevPlus online wallet top-ups, set up like Paystack.
//
// POST {action: "create", amount}  (signed-in customer)
//   Creates a SeevPlus hosted checkout on the server for deposit / (1 - fee),
//   so the customer receives exactly `amount` after SeevPlus takes its fee, and
//   returns the SeevPlus checkout_url. The secret key never reaches the browser.
//
// POST {action: "verify", session}  (anyone with the session id)
//   Looks the payment up at SeevPlus. When SeevPlus says it is paid, for at
//   least the amount we asked for, the wallet of the customer who created the
//   session is credited once (credit_deposit, reference SEEV-<reference>).
//   It needs no sign-in, so it also works when the customer comes back in a
//   browser where they are not signed in: it can only ever credit the owner.
//
// POST {action: "sync"}  (signed-in customer; admin: every customer)
//   Re-checks open sessions from the last 2 days, for customers who closed the
//   page before coming back.
//
// The secret key is the one the admin saved on the dashboard (Deposits tab);
// the SEEVPLUS_SECRET_KEY function secret is the fallback. SUPABASE_URL,
// SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const API = "https://api.seevplus.com/api/v1/developer/payments";
const SITE = "https://trudata.rvhssystems.com/";
const MIN_DEPOSIT = 5;
const MAX_DEPOSIT = 5000;
const PAID = new Set(["paid", "success", "successful", "succeeded", "completed", "complete", "approved", "settled"]);
const FAILED = new Set(["failed", "failure", "declined", "cancelled", "canceled", "reversed", "rejected", "error"]);
const EXPIRED = new Set(["expired", "abandoned", "timeout", "timed_out"]);

const round2 = (n: number) => Math.round(n * 100) / 100;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function secretKey(): Promise<string | null> {
  const { data } = await admin.rpc("get_seevplus_secret_key");
  return (data as string) || Deno.env.get("SEEVPLUS_SECRET_KEY") || null;
}

async function settings() {
  const { data } = await admin.from("app_settings").select("key,value")
    .in("key", ["seevplus_enabled", "seevplus_fee_percent"]);
  const m = Object.fromEntries((data || []).map((r: { key: string; value: unknown }) => [r.key, r.value]));
  const fee = typeof m.seevplus_fee_percent === "number" && m.seevplus_fee_percent >= 0 && m.seevplus_fee_percent <= 10
    ? m.seevplus_fee_percent : 0;
  return { enabled: m.seevplus_enabled === true, fee };
}

// The useful part of a SeevPlus reply, wherever they put it.
function payload(body: any) {
  const d = body?.data ?? body ?? {};
  return d.payment ?? d.session ?? d;
}
function errorText(body: any, status: number) {
  const e = body?.error ?? body?.errors ?? body?.message ?? body?.data?.message;
  const t = typeof e === "string" ? e : (e?.message || e?.detail || (e ? JSON.stringify(e) : ""));
  return (t || `SeevPlus answered ${status}`).slice(0, 300);
}

async function getUser(req: Request) {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth) return null;
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await client.auth.getUser();
  return user;
}

async function create(req: Request, body: any) {
  const user = await getUser(req);
  if (!user) return json({ error: "Please sign in first" }, 401);

  const deposit = round2(Number(body?.amount));
  if (!(deposit >= MIN_DEPOSIT && deposit <= MAX_DEPOSIT)) {
    return json({ error: `Enter an amount between GHS ${MIN_DEPOSIT} and GHS ${MAX_DEPOSIT}` }, 400);
  }
  const s = await settings();
  if (!s.enabled) return json({ error: "SeevPlus payments are switched off. Please use another way to pay." }, 503);
  const key = await secretKey();
  if (!key) return json({ error: "SeevPlus is not set up yet" }, 503);

  // At most 5 unfinished checkouts per customer per hour.
  const { count } = await admin.from("seev_payments").select("id", { count: "exact", head: true })
    .eq("user_id", user.id).in("status", ["creating", "pending"])
    .gte("created_at", new Date(Date.now() - 3600e3).toISOString());
  if ((count ?? 0) >= 5) {
    return json({ error: "You have several unfinished SeevPlus payments. Finish one or wait a little, then try again." }, 429);
  }

  const { data: profile } = await admin.from("profiles").select("full_name,email").eq("id", user.id).maybeSingle();
  const email = profile?.email || user.email;
  if (!email) return json({ error: "Your account has no email address" }, 400);
  const name = (profile?.full_name || "").trim() || email.split("@")[0];

  const charge = round2(deposit / (1 - s.fee / 100));
  const id = crypto.randomUUID();
  const { error: insErr } = await admin.from("seev_payments")
    .insert({ id, user_id: user.id, deposit, charge, fee_percent: s.fee, status: "creating" });
  if (insErr) return json({ error: "Could not start the payment" }, 500);

  let res: Response, out: any;
  try {
    res = await fetch(API, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Idempotency-Key": `tru_${id}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        type: "checkout",
        amount: charge,
        currency: "GHS",
        recipient: { name, email },
        redirect_url: `${SITE}?seev=${id}`,
        meta: { session_id: id, user_id: user.id, deposit, fee: round2(charge - deposit) },
      }),
    });
    out = await res.json().catch(() => ({}));
  } catch (e) {
    await admin.from("seev_payments").update({ status: "failed", error: "SeevPlus could not be reached", updated_at: new Date().toISOString() }).eq("id", id);
    return json({ error: "SeevPlus could not be reached. Please try again." }, 502);
  }
  const p = payload(out);
  const url = typeof p.checkout_url === "string" ? p.checkout_url : "";
  let urlOk = false;
  try { const h = new URL(url).hostname; urlOk = h === "seevplus.com" || h.endsWith(".seevplus.com"); } catch { /* bad URL */ }
  // SeevPlus must be charging exactly what we asked for (guards against a units mix-up).
  const amountOk = p.amount === undefined || Math.abs(Number(p.amount) - charge) < 0.005;
  if (!res.ok || out?.success === false || !urlOk || !p.reference || !amountOk) {
    const why = !res.ok || out?.success === false ? errorText(out, res.status)
      : !amountOk ? `SeevPlus amount ${p.amount} does not match ${charge}` : "SeevPlus sent no checkout link";
    console.error("seevplus create failed", res.status, JSON.stringify(out).slice(0, 800));
    await admin.from("seev_payments").update({ status: "failed", error: why, updated_at: new Date().toISOString() }).eq("id", id);
    return json({ error: "SeevPlus could not start the payment: " + why }, 502);
  }
  await admin.from("seev_payments").update({
    reference: String(p.reference), checkout_url: url, status: "pending", env: p.env ?? null,
    provider_status: p.status ?? null, updated_at: new Date().toISOString(),
  }).eq("id", id);
  return json({ session: id, checkout_url: url, charge, deposit, fee: round2(charge - deposit) });
}

// Look one session up at SeevPlus and credit it once if paid.
async function check(row: any, key: string) {
  if (row.status === "paid") return { status: "paid", credited: false, amount: Number(row.deposit) };
  if (!row.reference) return { status: row.status, credited: false, amount: Number(row.deposit) };

  const res = await fetch(`${API}/${encodeURIComponent(row.reference)}`, { headers: { Authorization: `Bearer ${key}` } });
  const out = await res.json().catch(() => ({}));
  const now = new Date().toISOString();
  if (!res.ok) {
    console.error("seevplus verify failed", row.reference, res.status, JSON.stringify(out).slice(0, 800));
    await admin.from("seev_payments").update({ checked_at: now, error: errorText(out, res.status) }).eq("id", row.id);
    return { status: row.status, credited: false, amount: Number(row.deposit), error: "Could not check with SeevPlus right now" };
  }
  const p = payload(out);
  const st = String(p.status ?? p.payment_status ?? "").toLowerCase();
  const paidAmount = Number(p.amount_paid ?? p.paid_amount ?? p.amount);
  const sameRef = !p.reference || String(p.reference) === row.reference;
  const currencyOk = !p.currency || String(p.currency).toUpperCase() === "GHS";
  const amountOk = Number.isFinite(paidAmount) ? paidAmount + 0.005 >= Number(row.charge) : true;

  if (PAID.has(st) && sameRef && currencyOk && amountOk) {
    const { data: credited, error } = await admin.rpc("credit_deposit", {
      p_user: row.user_id, p_reference: `SEEV-${row.reference}`,
      p_net: Number(row.deposit), p_fee: round2(Number(row.charge) - Number(row.deposit)),
    });
    if (error) {
      console.error("seevplus credit failed", row.reference, error.message);
      return { status: "pending", credited: false, amount: Number(row.deposit), error: "Paid, but the wallet could not be credited yet" };
    }
    await admin.from("seev_payments").update({ status: "paid", provider_status: st, paid_at: now, checked_at: now, updated_at: now, error: null }).eq("id", row.id);
    return { status: "paid", credited: !!credited, amount: Number(row.deposit) };
  }
  if (PAID.has(st)) {
    // Paid, but not what we asked for: leave it for the admin to look at.
    const why = !amountOk ? `SeevPlus says ${paidAmount} was paid, ${row.charge} was due` : "Reference or currency does not match";
    console.error("seevplus mismatch", row.reference, why, JSON.stringify(out).slice(0, 800));
    await admin.from("seev_payments").update({ provider_status: st, checked_at: now, updated_at: now, error: why }).eq("id", row.id);
    return { status: "pending", credited: false, amount: Number(row.deposit), error: "Payment needs checking by the admin" };
  }
  const next = FAILED.has(st) ? "failed" : EXPIRED.has(st) ? "expired" : "pending";
  await admin.from("seev_payments").update({ status: next, provider_status: st || null, checked_at: now, updated_at: now }).eq("id", row.id);
  return { status: next, credited: false, amount: Number(row.deposit) };
}

async function verify(body: any) {
  const id = String(body?.session ?? "");
  if (!UUID.test(id)) return json({ error: "Invalid payment session" }, 400);
  const { data: row } = await admin.from("seev_payments").select("*").eq("id", id).maybeSingle();
  if (!row) return json({ error: "Payment not found" }, 404);
  const key = await secretKey();
  if (!key) return json({ error: "SeevPlus is not set up yet" }, 503);
  // Payments are credited even if the admin switched SeevPlus off after the customer paid.
  return json(await check(row, key));
}

async function sync(req: Request) {
  const user = await getUser(req);
  if (!user) return json({ error: "Please sign in first" }, 401);
  const { data: isAdmin } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
  const all = isAdmin?.role === "admin";
  const key = await secretKey();
  if (!key) return json({ checked: 0, paid: 0 });
  let q = admin.from("seev_payments").select("*").eq("status", "pending")
    .gte("created_at", new Date(Date.now() - 2 * 86400e3).toISOString())
    .order("created_at", { ascending: false }).limit(all ? 50 : 5);
  if (!all) q = q.eq("user_id", user.id);
  const { data: rows } = await q;
  let paid = 0, credited = 0;
  for (const row of rows || []) {
    const r = await check(row, key);
    if (r.status === "paid") paid++;
    if (r.credited) credited += r.amount;
  }
  return json({ checked: (rows || []).length, paid, credited: round2(credited) });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const body = await req.json().catch(() => ({}));
  try {
    if (body?.action === "create") return await create(req, body);
    if (body?.action === "verify") return await verify(body);
    if (body?.action === "sync") return await sync(req);
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    console.error("seevplus error", e);
    return json({ error: "Something went wrong. Please try again." }, 500);
  }
});
