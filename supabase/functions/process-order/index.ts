// Sends a paid order to Refer2Bundle.
//
// The browser only sends the order reference. Network, bundle and phone are
// read from the order that place_order() created, so nobody can order data
// that was not paid for. Only the order's owner or an admin may submit it, and
// claim_order_for_api() makes sure each order is submitted at most once.
//
// Secrets: REFER2BUNDLE_API_KEY (already set). SUPABASE_URL, SUPABASE_ANON_KEY
// and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const R2B_API_KEY = Deno.env.get("REFER2BUNDLE_API_KEY");
const R2B_BASE_URL = "https://refer2bundle.com/api/v1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const networkMap: Record<string, string> = {
  mtn: "MTN",
  airteltigo: "AT",
  telecel: "Telecel",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ success: false, error: "Method not allowed" }, 405);

  try {
    if (!R2B_API_KEY) throw new Error("REFER2BUNDLE_API_KEY not set in Edge Function secrets");

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ success: false, error: "Not authenticated" }, 401);

    const { orderRef } = await req.json().catch(() => ({}));
    if (typeof orderRef !== "string" || !/^ORD-[A-Z0-9]{4,20}$/.test(orderRef)) {
      return json({ success: false, error: "Invalid order reference" }, 400);
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: order } = await admin.from("orders")
      .select("ref, user_id, retry_count").eq("ref", orderRef).maybeSingle();
    if (!order) return json({ success: false, error: "Order not found" }, 404);

    if (order.user_id !== user.id) {
      const { data: profile } = await admin.from("profiles")
        .select("role").eq("id", user.id).maybeSingle();
      if (profile?.role !== "admin") return json({ success: false, error: "Not your order" }, 403);
    }

    const { data: claimed, error: claimError } = await admin.rpc("claim_order_for_api", { p_ref: orderRef });
    if (claimError) throw new Error("Could not claim order");
    const o = claimed?.[0];
    if (!o) return json({ success: false, error: "Order is already submitted or no longer pending" });

    const phone = String(o.Phone);
    const r2bNetwork = networkMap[String(o.Network).toLowerCase()];
    if (!r2bNetwork) throw new Error(`Unknown network ${o.Network}`);

    console.log("Submitting order", { ref: o.ref, r2bNetwork, dataPlan: o.bundle_name, phone });

    let result: any;
    let ok = false;
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 30000);
      const response = await fetch(`${R2B_BASE_URL}/order`, {
        method: "POST",
        headers: { "X-API-KEY": R2B_API_KEY, "Content-Type": "application/json" },
        body: JSON.stringify({ network: r2bNetwork, data_plan: o.bundle_name, beneficiary: phone }),
        signal: controller.signal,
      });
      clearTimeout(timeoutId);
      const contentType = response.headers.get("content-type") || "";
      result = contentType.includes("application/json")
        ? await response.json()
        : { status: "error", message: `Non-JSON response: ${(await response.text()).substring(0, 200)}` };
      ok = response.ok && result?.status === "success";
    } catch (e) {
      result = { status: "error", message: e instanceof Error ? e.message : String(e) };
    }

    console.log("R2B result:", JSON.stringify(result));

    const apiReference = result?.data?.reference || result?.reference || null;
    const errorMessage = ok ? null : (result?.data?.message || result?.message || "Refer2Bundle error");

    await admin.from("orders").update(ok
      ? {
        Status: "Processing",
        api_status: "submitted",
        api_reference: apiReference,
        processed_by_api: true,
        api_response: result,
        failure_reason: null,
      }
      : {
        api_status: "failed",
        retry_count: (o.retry_count || 0) + 1,
        failure_reason: errorMessage,
        api_response: result,
      }).eq("ref", o.ref);

    return json({ success: ok, data: { reference: apiReference }, error: errorMessage });
  } catch (error) {
    console.error("process-order error:", error instanceof Error ? error.message : error);
    return json({ success: false, error: error instanceof Error ? error.message : "Unexpected error" }, 500);
  }
});
