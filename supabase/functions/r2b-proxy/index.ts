// Disabled. TRU Data no longer uses the Refer2Bundle API: orders stay
// "Pending" and the admin fulfils them manually. This stub replaces the old
// function, which let any signed-in user order data on the business account.
// Delete it from the Supabase dashboard (Edge Functions) when convenient.

Deno.serve(() =>
  new Response(JSON.stringify({ success: false, error: "This service has been disabled" }), {
    status: 410,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  })
);
