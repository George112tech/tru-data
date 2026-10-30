// Read-only Refer2Bundle lookups for the admin dashboard (balance, bundles,
// order status, order history). Admin only: these expose your Refer2Bundle
// balance and every customer's order.

import { createClient } from "jsr:@supabase/supabase-js@2.45.4";

const R2B_API_KEY = Deno.env.get("REFER2BUNDLE_API_KEY");
const R2B_BASE_URL = "https://refer2bundle.com/api/v1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ status: "error", message: "Not authenticated" }, 401);

    const { data: profile } = await userClient.from("profiles")
      .select("role").eq("id", user.id).maybeSingle();
    if (profile?.role !== "admin") return json({ status: "error", message: "Admin access only" }, 403);

    const { action, payload = {} } = await req.json();
    const limit = Math.min(Math.max(parseInt(payload.limit) || 50, 1), 200);
    const offset = Math.max(parseInt(payload.offset) || 0, 0);

    const endpoints: Record<string, string> = {
      "balance": "/balance",
      "bundles": "/bundles",
      "order-status": `/order-status?reference=${encodeURIComponent(String(payload.reference || ""))}`,
      "orders": `/orders?limit=${limit}&offset=${offset}`,
    };

    const endpoint = endpoints[action];
    if (!endpoint) return json({ status: "error", message: `Unknown action: ${action}` }, 400);

    const response = await fetch(`${R2B_BASE_URL}${endpoint}`, {
      method: "GET",
      headers: { "X-API-KEY": R2B_API_KEY || "", "Content-Type": "application/json" },
    });
    return json(await response.json());
  } catch (error) {
    return json({ status: "error", message: error instanceof Error ? error.message : "Unexpected error" }, 500);
  }
});
