// SeevPlus online wallet top-ups, set up like Paystack.
//
// POST {action: "create", amount}  (signed-in customer)
//   Creates a SeevPlus hosted checkout on the server for deposit / (1 - fee),
//   sent to SeevPlus in pesewas (GHS 5.10 is sent as 510),
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
// Guests (no account) buying a bundle, when the guest picks SeevPlus:
// POST {action: "guest_create", reference}
//   reference is a GST-... checkout made by guest_start(..., 'seevplus'). Makes
//   the SeevPlus checkout for its total and returns checkout_url. The customer
//   comes back to /?gseev=<reference>.
// POST {action: "guest_verify", reference}
//   Asks SeevPlus; when it is paid in full, guest_complete() makes the order
//   (once per reference) and the receipt is returned, like guest-checkout:
//   { paid: true, order_ref, ... } or { paid: false, status }.
// POST {action: "guest_sync"}  (admin)
//   Re-checks every SeevPlus guest payment still open from the last 3 days.
//
// Webhook: SeevPlus posts payment.succeeded / payment.failed to this same URL
//   with X-Seev-Timestamp and X-Seev-Signature = "v1=" + hex(HMAC_SHA256(
//   signing secret, timestamp + "." + raw body)). A valid event only triggers
//   the same check as "verify" (SeevPlus is asked again), so a replayed or old
//   event can never credit twice or credit anything that is not paid.
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
// SeevPlus amounts are in pesewas (minor units): GHS 5.00 is 500.
const toPesewas = (ghs: number) => Math.round(ghs * 100);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function webhookSecret(): Promise<string | null> {
  const { data } = await admin.rpc("get_seevplus_webhook_secret");
  return (data as string) || Deno.env.get("SEEVPLUS_WEBHOOK_SECRET") || null;
}

async function hmacHex(secret: string, text: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(text)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}
function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

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
  if (!s.enabled) return json({ error: "This payment option is switched off. Please use another way to pay." }, 503);
  const key = await secretKey();
  if (!key) return json({ error: "Online payment is not set up yet" }, 503);

  // At most 5 unfinished checkouts per customer per hour.
  const { count } = await admin.from("seev_payments").select("id", { count: "exact", head: true })
    .eq("user_id", user.id).in("status", ["creating", "pending"])
    .gte("created_at", new Date(Date.now() - 3600e3).toISOString());
  if ((count ?? 0) >= 5) {
    return json({ error: "You have several unfinished online payments. Finish one or wait a little, then try again." }, 429);
  }

  const { data: profile } = await admin.from("profiles").select("full_name,email").eq("id", user.id).maybeSingle();
  const email = profile?.email || user.email;
  if (!email) return json({ error: "Your account has no email address" }, 400);
  const name = (profile?.full_name || "").trim() || email.split("@")[0];

  const charge = round2(deposit / (1 - s.fee / 100));
  const chargeMinor = toPesewas(charge);
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
        amount: chargeMinor,
        currency: "GHS",
        recipient: { name, email },
        redirect_url: `${SITE}?seev=${id}`,
        meta: { session_id: id, user_id: user.id, deposit, fee: round2(charge - deposit) },
      }),
    });
    out = await res.json().catch(() => ({}));
  } catch (e) {
    await admin.from("seev_payments").update({ status: "failed", error: "SeevPlus could not be reached", updated_at: new Date().toISOString() }).eq("id", id);
    return json({ error: "The payment page could not be reached. Please try again." }, 502);
  }
  const p = payload(out);
  const url = typeof p.checkout_url === "string" ? p.checkout_url : "";
  let urlOk = false;
  try { const h = new URL(url).hostname; urlOk = h === "seevplus.com" || h.endsWith(".seevplus.com"); } catch { /* bad URL */ }
  // SeevPlus must be charging exactly what we asked for (in pesewas).
  const amountOk = p.amount === undefined || Number(p.amount) === chargeMinor;
  if (!res.ok || out?.success === false || !urlOk || !p.reference || !amountOk) {
    const why = !res.ok || out?.success === false ? errorText(out, res.status)
      : !amountOk ? `SeevPlus amount ${p.amount} does not match ${chargeMinor} pesewas` : "SeevPlus sent no checkout link";
    console.error("seevplus create failed", res.status, JSON.stringify(out).slice(0, 800));
    await admin.from("seev_payments").update({ status: "failed", error: why, updated_at: new Date().toISOString() }).eq("id", id);
    return json({ error: "The payment could not be started: " + why }, 502);
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
    return { status: row.status, credited: false, amount: Number(row.deposit), error: "Could not check the payment right now" };
  }
  const p = payload(out);
  const st = String(p.status ?? p.payment_status ?? "").toLowerCase();
  // In pesewas, like every SeevPlus amount.
  const paidAmount = Number(p.amount_paid ?? p.paid_amount ?? p.amount);
  const sameRef = !p.reference || String(p.reference) === row.reference;
  const currencyOk = !p.currency || String(p.currency).toUpperCase() === "GHS";
  const amountOk = Number.isFinite(paidAmount) ? paidAmount >= toPesewas(Number(row.charge)) : true;

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
    const why = !amountOk ? `SeevPlus says GHS ${(paidAmount / 100).toFixed(2)} was paid, GHS ${Number(row.charge).toFixed(2)} was due` : "Reference or currency does not match";
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
  if (!key) return json({ error: "Online payment is not set up yet" }, 503);
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

// ===== Guests =====
const GST = /^GST-[A-Z0-9]{12}$/;

async function guestInfo(reference?: string, providerRef?: string) {
  const { data } = await admin.rpc("guest_checkout_info", {
    p_reference: reference ?? null, p_provider_reference: providerRef ?? null,
  });
  return (data as any) || null;
}

async function guestCreate(body: any) {
  const reference = String(body?.reference ?? "");
  if (!GST.test(reference)) return json({ error: "Invalid payment reference" }, 400);
  const g = await guestInfo(reference);
  if (!g || g.provider !== "seevplus") return json({ error: "Payment not found" }, 404);
  if (g.status !== "pending") return json({ error: "This payment is already finished" }, 409);
  // The same checkout again (double tap, page reloaded): send the same link.
  if (g.checkout_url) return json({ reference, checkout_url: g.checkout_url, total: Number(g.total) });
  if (Date.now() - new Date(g.created_at).getTime() > 3600e3) return json({ error: "This payment has expired. Please start again." }, 410);
  const s = await settings();
  if (!s.enabled) return json({ error: "This payment option is switched off. Please choose another way to pay." }, 503);
  const key = await secretKey();
  if (!key) return json({ error: "Online payment is not set up yet" }, 503);

  const total = round2(Number(g.total));
  const totalMinor = toPesewas(total);
  const email = `guest-${String(g.contact_phone).replace(/\D/g, "")}@trudata.rvhssystems.com`;
  let res: Response, out: any;
  try {
    res = await fetch(API, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Idempotency-Key": `tru_${reference}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        type: "checkout",
        amount: totalMinor,
        currency: "GHS",
        recipient: { name: "TRU Data customer", email },
        redirect_url: `${SITE}?gseev=${reference}`,
        meta: { guest_reference: reference, bundle: `${g.bundle_name} ${String(g.network).toUpperCase()}`, phone: g.phone },
      }),
    });
    out = await res.json().catch(() => ({}));
  } catch {
    return json({ error: "The payment page could not be reached. Please try again." }, 502);
  }
  const p = payload(out);
  const url = typeof p.checkout_url === "string" ? p.checkout_url : "";
  let urlOk = false;
  try { const h = new URL(url).hostname; urlOk = h === "seevplus.com" || h.endsWith(".seevplus.com"); } catch { /* bad URL */ }
  const amountOk = p.amount === undefined || Number(p.amount) === totalMinor;
  if (!res.ok || out?.success === false || !urlOk || !p.reference || !amountOk) {
    const why = !res.ok || out?.success === false ? errorText(out, res.status)
      : !amountOk ? `SeevPlus amount ${p.amount} does not match ${totalMinor} pesewas` : "SeevPlus sent no checkout link";
    console.error("seevplus guest create failed", reference, res.status, JSON.stringify(out).slice(0, 800));
    return json({ error: "The payment could not be started: " + why }, 502);
  }
  const { data: attached } = await admin.rpc("guest_seev_attach", {
    p_reference: reference, p_provider_reference: String(p.reference), p_checkout_url: url,
  });
  if (!attached) return json({ error: "Could not start the payment. Please try again." }, 500);
  return json({ reference, checkout_url: url, total });
}

// Ask SeevPlus about one guest checkout and make its order once if paid in full.
async function guestCheck(g: any, key: string): Promise<{ body: Record<string, unknown>; status: number }> {
  if (g.status === "paid" && g.order_ref) {
    const { data } = await admin.rpc("guest_complete", { p_reference: g.reference, p_paid_pesewas: 0, p_paystack_id: null });
    return { body: { ...(data ?? {}), paid: true }, status: 200 };
  }
  if (g.status !== "pending") return { body: { paid: false, status: g.status }, status: 200 };
  if (!g.provider_reference) return { body: { paid: false, status: "not_started" }, status: 200 };

  const res = await fetch(`${API}/${encodeURIComponent(g.provider_reference)}`, { headers: { Authorization: `Bearer ${key}` } });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.error("seevplus guest verify failed", g.reference, res.status, JSON.stringify(out).slice(0, 800));
    return { body: { error: "Could not check the payment right now. Try again in a moment." }, status: 502 };
  }
  const p = payload(out);
  const st = String(p.status ?? p.payment_status ?? "").toLowerCase();
  const paidAmount = Number(p.amount_paid ?? p.paid_amount ?? p.amount);
  const sameRef = !p.reference || String(p.reference) === g.provider_reference;
  const currencyOk = !p.currency || String(p.currency).toUpperCase() === "GHS";
  if (PAID.has(st) && sameRef && currencyOk) {
    // guest_complete checks the amount: less than the total makes no order.
    const paid = Number.isFinite(paidAmount) ? Math.round(paidAmount) : toPesewas(Number(g.total));
    const { data, error } = await admin.rpc("guest_complete", {
      p_reference: g.reference, p_paid_pesewas: paid, p_paystack_id: String(g.provider_reference),
    });
    if (error) {
      console.error("seevplus guest complete failed", g.reference, error.message);
      return { body: { error: "Your payment was received but the order could not be created. Contact support with reference " + g.reference }, status: 500 };
    }
    if ((data as any)?.error === "underpaid") {
      return { body: { error: "The amount paid is less than the price, so no order was made. Contact support with reference " + g.reference }, status: 400 };
    }
    return { body: { ...(data ?? {}), paid: true }, status: 200 };
  }
  if (PAID.has(st)) {
    console.error("seevplus guest mismatch", g.reference, JSON.stringify(out).slice(0, 800));
    return { body: { error: "Payment needs checking by the admin. Reference " + g.reference }, status: 409 };
  }
  const next = FAILED.has(st) ? "failed" : EXPIRED.has(st) ? "abandoned" : "pending";
  if (next !== "pending") await admin.rpc("guest_mark_unpaid", { p_reference: g.reference, p_status: next });
  return { body: { paid: false, status: next === "abandoned" ? "abandoned" : next === "failed" ? "failed" : (st || "pending") }, status: 200 };
}

async function guestVerify(body: any) {
  const reference = String(body?.reference ?? "");
  if (!GST.test(reference)) return json({ error: "Invalid payment reference" }, 400);
  const g = await guestInfo(reference);
  if (!g || g.provider !== "seevplus") return json({ error: "Payment not found" }, 404);
  const key = await secretKey();
  if (!key) return json({ error: "Online payment is not set up yet" }, 503);
  const r = await guestCheck(g, key);
  return json(r.body, r.status);
}

async function guestSync(req: Request) {
  const user = await getUser(req);
  if (!user) return json({ error: "Please sign in first" }, 401);
  const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (me?.role !== "admin") return json({ error: "Admins only" }, 403);
  const key = await secretKey();
  if (!key) return json({ checked: 0, created: [] });
  const { data: refs } = await admin.rpc("guest_pending_references", { p_days: 3, p_provider: "seevplus" });
  const created: string[] = [];
  for (const reference of (refs ?? []) as string[]) {
    const g = await guestInfo(reference);
    if (!g) continue;
    const r = await guestCheck(g, key);
    if (r.body.paid === true && !r.body.already && typeof r.body.order_ref === "string") created.push(r.body.order_ref);
  }
  return json({ checked: (refs ?? []).length, created });
}

async function webhook(req: Request, raw: string) {
  const secret = await webhookSecret();
  if (!secret) return json({ error: "Webhook secret not set" }, 503);
  const ts = req.headers.get("X-Seev-Timestamp") ?? "";
  const sig = req.headers.get("X-Seev-Signature") ?? "";
  const age = Math.abs(Date.now() / 1000 - Number(ts));
  if (!ts || !Number.isFinite(Number(ts)) || age > 300) return json({ error: "Invalid signature" }, 401);
  if (!sameText("v1=" + await hmacHex(secret, `${ts}.${raw}`), sig)) return json({ error: "Invalid signature" }, 401);

  let event: any;
  try { event = JSON.parse(raw); } catch { return json({ error: "Bad body" }, 400); }
  const tx = event?.data?.transaction ?? {};
  const ref = String(tx.reference ?? tx.gatewaySessionRef ?? "");
  if (!ref || !/^payment\./.test(String(event?.event ?? ""))) return json({ received: true, ignored: "not a payment event" });
  const { data: row } = await admin.from("seev_payments").select("*").eq("reference", ref).maybeSingle();
  if (!row) {
    // Not a wallet top-up: maybe a guest's bundle payment.
    const g = await guestInfo(undefined, ref);
    if (!g || g.provider !== "seevplus") return json({ received: true, ignored: "unknown reference" });
    const gkey = await secretKey();
    if (!gkey) return json({ error: "Online payment is not set up yet" }, 503);
    const r = await guestCheck(g, gkey);
    // A 5xx makes SeevPlus send the event again later.
    return json({ received: true, guest: true, paid: r.body.paid === true }, r.status >= 500 ? r.status : 200);
  }
  const key = await secretKey();
  if (!key) return json({ error: "Online payment is not set up yet" }, 503);
  const r = await check(row, key);
  return json({ received: true, status: r.status, credited: r.credited });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const raw = await req.text();
  if (req.headers.has("X-Seev-Signature")) {
    try { return await webhook(req, raw); } catch (e) {
      console.error("seevplus webhook error", e);
      return json({ error: "Webhook failed" }, 500);
    }
  }
  let body: any = {};
  try { body = JSON.parse(raw || "{}"); } catch { body = {}; }
  try {
    if (body?.action === "create") return await create(req, body);
    if (body?.action === "verify") return await verify(body);
    if (body?.action === "sync") return await sync(req);
    if (body?.action === "guest_create") return await guestCreate(body);
    if (body?.action === "guest_verify") return await guestVerify(body);
    if (body?.action === "guest_sync") return await guestSync(req);
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    console.error("seevplus error", e);
    return json({ error: "Something went wrong. Please try again." }, 500);
  }
});
