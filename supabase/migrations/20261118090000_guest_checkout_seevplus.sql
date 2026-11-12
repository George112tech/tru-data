-- Guest checkout: pay with SeevPlus as well as Paystack.
--
-- Until now a guest could only pay with Paystack, so with Paystack switched
-- off the guest sheet only said "Sign in to buy this bundle" (and the
-- unverified-number check, which lives in that sheet, never showed).
--
-- Now the guest picks Paystack or SeevPlus, whichever is on:
--   guest_quote(bundle, phone, provider)  the price with that provider's fee
--                                         (online_fee_percent for Paystack,
--                                         seevplus_fee_percent for SeevPlus)
--   guest_start(bundle, phone, contact, provider)
--                                         records the checkout with its provider
-- The seevplus Edge Function then makes the SeevPlus checkout (guest_create),
-- and confirms it (guest_verify, the SeevPlus webhook, the admin's check)
-- through the same guest_complete() as Paystack: once per reference, only for
-- the full amount.
--
-- orders.guest_paid_with says which one a guest paid with (for the admin).
--
-- New service_role-only helpers for the Edge Function:
--   guest_checkout_info(reference | provider reference)
--   guest_seev_attach(reference, SeevPlus reference, checkout url)
--   guest_pending_references(days, provider)   (now per provider)

alter table private.guest_checkouts
  add column if not exists provider text not null default 'paystack',
  add column if not exists provider_reference text,
  add column if not exists checkout_url text;
alter table private.guest_checkouts drop constraint if exists guest_checkouts_provider_check;
alter table private.guest_checkouts
  add constraint guest_checkouts_provider_check check (provider in ('paystack', 'seevplus'));
create unique index if not exists guest_checkouts_provider_reference_key
  on private.guest_checkouts (provider_reference) where provider_reference is not null;

-- Is this way of paying available to guests right now?
create or replace function private.guest_provider_on(p_provider text)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select case p_provider
    when 'paystack' then
      coalesce((select value = 'true'::jsonb from public.app_settings where key = 'paystack_enabled'), false)
      and coalesce((select value #>> '{}' from public.app_settings where key = 'paystack_public_key'), '') ~ '^pk_(live|test)_'
    when 'seevplus' then
      coalesce((select value = 'true'::jsonb from public.app_settings where key = 'seevplus_enabled'), false)
      and exists (select 1 from private.secrets where key = 'seevplus_secret_key' and length(value) > 0)
    else false
  end;
$$;

-- The provider to use: the one asked for, else Paystack if on, else SeevPlus.
create or replace function private.guest_pick_provider(p_provider text)
returns text
language sql
stable
security definer
set search_path = public, private
as $$
  select case
    when p_provider in ('paystack', 'seevplus') then p_provider
    when private.guest_provider_on('paystack') then 'paystack'
    when private.guest_provider_on('seevplus') then 'seevplus'
    else 'paystack'
  end;
$$;

-- The 2-argument versions are replaced (a default 3rd argument would make
-- calls with 2 arguments ambiguous).
drop function if exists public.guest_quote(text, text);
drop function if exists public.guest_start(text, text, text);
drop function if exists private.guest_price(text, text);

create or replace function private.guest_price(p_bundle_id text, p_phone text, p_provider text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_b    public.bundles%rowtype;
  v_q    jsonb;
  v_prov text := private.guest_pick_provider(p_provider);
  v_pct  numeric;
  v_fee  numeric;
  v_sub  numeric;
  v_tot  numeric;
begin
  if coalesce(p_phone, '') !~ '^0(24|54|55|59|25|53|63|77|57|20|50|26|56|27|76|23|28|58)[0-9]{7}$' then
    raise exception 'Enter a valid 10-digit Ghana phone number';
  end if;
  select * into v_b from public.bundles where id = p_bundle_id and active;
  if not found then
    raise exception 'Bundle not found';
  end if;
  v_q   := private.unverified_quote(p_phone, v_b.id);
  v_fee := coalesce((v_q ->> 'fee')::numeric, 0);
  v_pct := coalesce((select (value #>> '{}')::numeric from public.app_settings
                      where key = case v_prov when 'seevplus' then 'seevplus_fee_percent' else 'online_fee_percent' end), 3);
  if v_pct < 0 or v_pct > 10 then v_pct := 3; end if;
  v_sub := v_b.price + v_fee;
  v_tot := round(ceil(v_sub * (1 + v_pct / 100) * 100) / 100, 2);
  return jsonb_build_object(
    'bundle_id', v_b.id, 'network', v_b.network, 'bundle_name', v_b.size,
    'bundle_price', v_b.price, 'unverified_fee', v_fee, 'unverified_combo', v_q ->> 'combo',
    'provider', v_prov, 'fee_percent', v_pct, 'online_fee', round(v_tot - v_sub, 2), 'total', v_tot);
end;
$$;

-- What the guest sees before paying (the two-bundle detail stays for the admin).
create or replace function public.guest_quote(p_bundle_id text, p_phone text, p_provider text default null)
returns jsonb
language sql
stable
security definer
set search_path = public, private
as $$
  select private.guest_price(p_bundle_id, p_phone, p_provider) - 'unverified_combo';
$$;

create or replace function public.guest_start(p_bundle_id text, p_phone text, p_contact_phone text default null,
                                              p_provider text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_p       jsonb;
  v_prov    text := private.guest_pick_provider(p_provider);
  v_contact text := coalesce(nullif(trim(coalesce(p_contact_phone, '')), ''), p_phone);
  v_ref     text;
begin
  if not private.guest_provider_on(v_prov) then
    raise exception '%', case
      when private.guest_provider_on('paystack') or private.guest_provider_on('seevplus')
        then 'That way of paying is not available right now. Please choose the other one.'
      else 'Paying without an account is not available right now. Create an account to pay with Mobile Money.' end;
  end if;
  if public.sms_normalize_phone(v_contact) is null then
    raise exception 'Enter a valid phone number for updates';
  end if;
  v_p := private.guest_price(p_bundle_id, p_phone, v_prov);
  -- A few tries are normal (a payment closed and opened again); many are not.
  if (select count(*) from private.guest_checkouts
       where (contact_phone = v_contact or phone = p_phone) and created_at > now() - interval '1 hour') >= 15 then
    raise exception 'Too many tries. Please wait a little and try again.';
  end if;
  v_ref := 'GST-' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
  insert into private.guest_checkouts (reference, bundle_id, network, bundle_name, phone, contact_phone,
                                       bundle_price, unverified_fee, unverified_combo, online_fee, total, provider)
  values (v_ref, v_p ->> 'bundle_id', v_p ->> 'network', v_p ->> 'bundle_name', p_phone, v_contact,
          (v_p ->> 'bundle_price')::numeric, (v_p ->> 'unverified_fee')::numeric, v_p ->> 'unverified_combo',
          (v_p ->> 'online_fee')::numeric, (v_p ->> 'total')::numeric, v_prov);
  return (v_p - 'unverified_combo') || jsonb_build_object(
    'reference', v_ref,
    'amount_pesewas', round((v_p ->> 'total')::numeric * 100)::bigint,
    -- Paystack and SeevPlus need an e-mail; guests do not give one.
    'email', 'guest-' || regexp_replace(v_contact, '\D', '', 'g') || '@trudata.rvhssystems.com');
end;
$$;

-- For the seevplus Edge Function: one guest checkout, by our reference or SeevPlus's.
create or replace function public.guest_checkout_info(p_reference text default null, p_provider_reference text default null)
returns jsonb
language sql
stable
security definer
set search_path = public, private
as $$
  select to_jsonb(c) - 'unverified_combo'
    from private.guest_checkouts c
   where (p_reference is not null and c.reference = p_reference)
      or (p_provider_reference is not null and c.provider_reference = p_provider_reference)
   limit 1;
$$;

create or replace function public.guest_seev_attach(p_reference text, p_provider_reference text, p_checkout_url text)
returns boolean
language plpgsql
security definer
set search_path = public, private
as $$
begin
  update private.guest_checkouts
     set provider_reference = p_provider_reference, checkout_url = p_checkout_url
   where reference = p_reference and provider = 'seevplus' and status = 'pending';
  return found;
end;
$$;

drop function if exists public.guest_pending_references(int);
create or replace function public.guest_pending_references(p_days int default 3, p_provider text default 'paystack')
returns setof text
language sql
stable
security definer
set search_path = public, private
as $$
  select reference
    from private.guest_checkouts
   where status = 'pending'
     and provider = coalesce(p_provider, 'paystack')
     and (provider = 'paystack' or provider_reference is not null)
     and created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 3), 14)))
   order by created_at desc
   limit 100;
$$;

-- Which way a guest paid, shown to the admin (refunds are made there).
alter table public.orders add column if not exists guest_paid_with text;
update public.orders set guest_paid_with = 'paystack'
 where user_id is null and paystack_reference like 'GST-%' and guest_paid_with is null;

-- Same as before, and it records guest_paid_with on the order.
create or replace function public.guest_complete(p_reference text, p_paid_pesewas bigint, p_paystack_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_c   private.guest_checkouts%rowtype;
  v_ref text;
  v_paid numeric := round(coalesce(p_paid_pesewas, 0)::numeric / 100, 2);
begin
  select * into v_c from private.guest_checkouts where reference = p_reference for update;
  if not found then
    raise exception 'Unknown payment reference';
  end if;
  if v_c.status = 'paid' then
    return jsonb_build_object('order_ref', v_c.order_ref, 'already', true) || private.guest_receipt(v_c.order_ref);
  end if;
  if v_paid + 0.009 < v_c.total then
    update private.guest_checkouts set status = 'underpaid', paid_amount = v_paid, paystack_id = p_paystack_id where reference = p_reference;
    perform private.audit_add('money', 'guest.underpaid',
      'Guest payment ' || p_reference || ' paid ' || private.ghs(v_paid) || ' instead of ' || private.ghs(v_c.total) || ': no order made',
      'guest_checkouts', p_reference, null, null, jsonb_build_object('paid', v_paid, 'total', v_c.total));
    -- Returned, not raised: raising would undo the 'underpaid' mark above.
    return jsonb_build_object('error', 'underpaid', 'paid', v_paid, 'total', v_c.total);
  end if;
  if v_c.status = 'underpaid' then
    return jsonb_build_object('error', 'underpaid', 'paid', v_c.paid_amount, 'total', v_c.total);
  end if;
  v_ref := 'ORD-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));
  insert into public.orders (
    ref, "Phone", "Network", bundle_name, "Amount", "Status", provider, user_id, full_name,
    base_price_used, api_status, retry_count, processed_by_api,
    unverified_fee, unverified_combo, guest_phone, paystack_reference, guest_paid_with, created_at, updated_at
  ) values (
    v_ref, v_c.phone, v_c.network, v_c.bundle_name, v_c.bundle_price + v_c.unverified_fee, 'Pending', 'patupaa', null, 'Guest',
    v_c.bundle_price, 'pending', 0, false,
    v_c.unverified_fee, v_c.unverified_combo, v_c.contact_phone, p_reference, v_c.provider, now(), now()
  );
  update private.guest_checkouts
     set status = 'paid', order_ref = v_ref, paid_amount = v_paid, paystack_id = p_paystack_id, paid_at = now()
   where reference = p_reference;
  return jsonb_build_object('order_ref', v_ref, 'already', false) || private.guest_receipt(v_ref);
end;
$$;

revoke execute on function private.guest_provider_on(text) from public, anon, authenticated;
revoke execute on function private.guest_pick_provider(text) from public, anon, authenticated;
revoke execute on function private.guest_price(text, text, text) from public, anon, authenticated;
revoke execute on function public.guest_quote(text, text, text) from public;
revoke execute on function public.guest_start(text, text, text, text) from public;
revoke execute on function public.guest_checkout_info(text, text) from public, anon, authenticated;
revoke execute on function public.guest_seev_attach(text, text, text) from public, anon, authenticated;
revoke execute on function public.guest_pending_references(int, text) from public, anon, authenticated;
grant execute on function public.guest_quote(text, text, text) to anon, authenticated;
grant execute on function public.guest_start(text, text, text, text) to anon, authenticated;
grant execute on function public.guest_checkout_info(text, text) to service_role;
grant execute on function public.guest_seev_attach(text, text, text) to service_role;
grant execute on function public.guest_pending_references(int, text) to service_role;
