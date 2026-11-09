-- Guest checkout: buy one bundle without an account, paying with Paystack.
--
-- 1. guest_quote(bundle, number): the price before paying. Bundle price, the
--    unverified-number extra (same rules as customers) and the online payment
--    fee (app_settings.online_fee_percent, 3%): total = (price + extra) x 1.03,
--    rounded up to the pesewa.
-- 2. guest_start(bundle, number, contact phone): keeps the quote in
--    private.guest_checkouts under a Paystack reference (GST-XXXXXXXXXXXX)
--    and returns it with the amount to charge. The page opens Paystack with it.
-- 3. The guest-checkout Edge Function asks Paystack whether that reference was
--    paid (with the secret key, never trusting the browser) and calls
--    guest_complete(), which creates the order once: orders.paystack_reference
--    is unique and the checkout is marked paid.
-- 4. guest_track(order number, phone): the order's status for the guest.
--
-- Guest orders have no user_id; orders.guest_phone is where their texts go.
-- Orders.Amount is the bundle price plus any unverified extra, like customer
-- orders; the online fee stays in guest_checkouts (Paystack keeps it).
-- Cancelling a guest order does not refund a wallet (there is none): refund it
-- from the Paystack dashboard.

begin;

alter table public.orders add column if not exists guest_phone text;
alter table public.orders add column if not exists paystack_reference text;
create unique index if not exists orders_paystack_reference_key on public.orders (paystack_reference) where paystack_reference is not null;

create table if not exists private.guest_checkouts (
  reference        text primary key check (reference ~ '^GST-[A-Z0-9]{12}$'),
  bundle_id        text not null,
  network          text not null,
  bundle_name      text not null,
  phone            text not null,
  contact_phone    text not null,
  bundle_price     numeric(10, 2) not null,
  unverified_fee   numeric(10, 2) not null default 0,
  unverified_combo text,
  online_fee       numeric(10, 2) not null,
  total            numeric(10, 2) not null,
  status           text not null default 'pending' check (status in ('pending', 'paid', 'underpaid')),
  order_ref        text,
  paid_amount      numeric(10, 2),
  paystack_id      text,
  created_at       timestamptz not null default now(),
  paid_at          timestamptz
);
create index if not exists guest_checkouts_contact_idx on private.guest_checkouts (contact_phone, created_at);
revoke all on private.guest_checkouts from public, anon, authenticated;

-- The price for a guest (no record is kept).
create or replace function private.guest_price(p_bundle_id text, p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_b    public.bundles%rowtype;
  v_q    jsonb;
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
  v_pct := coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'online_fee_percent'), 3);
  if v_pct < 0 or v_pct > 10 then v_pct := 3; end if;
  v_sub := v_b.price + v_fee;
  v_tot := round(ceil(v_sub * (1 + v_pct / 100) * 100) / 100, 2);
  return jsonb_build_object(
    'bundle_id', v_b.id, 'network', v_b.network, 'bundle_name', v_b.size,
    'bundle_price', v_b.price, 'unverified_fee', v_fee, 'unverified_combo', v_q ->> 'combo',
    'fee_percent', v_pct, 'online_fee', round(v_tot - v_sub, 2), 'total', v_tot);
end;
$$;

-- What the guest sees before paying (the two-bundle detail stays for the admin).
create or replace function public.guest_quote(p_bundle_id text, p_phone text)
returns jsonb
language sql
stable
security definer
set search_path = public, private
as $$
  select private.guest_price(p_bundle_id, p_phone) - 'unverified_combo';
$$;

create or replace function public.guest_start(p_bundle_id text, p_phone text, p_contact_phone text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_p       jsonb;
  v_contact text := coalesce(nullif(trim(coalesce(p_contact_phone, '')), ''), p_phone);
  v_ref     text;
begin
  if coalesce((select value = 'true'::jsonb from public.app_settings where key = 'paystack_enabled'), false) = false
     or coalesce((select value #>> '{}' from public.app_settings where key = 'paystack_public_key'), '') !~ '^pk_(live|test)_' then
    raise exception 'Paying without an account is not available right now. Create an account to pay with Mobile Money.';
  end if;
  if public.sms_normalize_phone(v_contact) is null then
    raise exception 'Enter a valid phone number for updates';
  end if;
  v_p := private.guest_price(p_bundle_id, p_phone);
  -- A few tries are normal (a payment closed and opened again); many are not.
  if (select count(*) from private.guest_checkouts
       where (contact_phone = v_contact or phone = p_phone) and created_at > now() - interval '1 hour') >= 15 then
    raise exception 'Too many tries. Please wait a little and try again.';
  end if;
  v_ref := 'GST-' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
  insert into private.guest_checkouts (reference, bundle_id, network, bundle_name, phone, contact_phone,
                                       bundle_price, unverified_fee, unverified_combo, online_fee, total)
  values (v_ref, v_p ->> 'bundle_id', v_p ->> 'network', v_p ->> 'bundle_name', p_phone, v_contact,
          (v_p ->> 'bundle_price')::numeric, (v_p ->> 'unverified_fee')::numeric, v_p ->> 'unverified_combo',
          (v_p ->> 'online_fee')::numeric, (v_p ->> 'total')::numeric);
  return (v_p - 'unverified_combo') || jsonb_build_object(
    'reference', v_ref,
    'amount_pesewas', round((v_p ->> 'total')::numeric * 100)::bigint,
    -- Paystack needs an e-mail; guests do not give one.
    'email', 'guest-' || regexp_replace(v_contact, '\D', '', 'g') || '@trudata.rvhssystems.com');
end;
$$;

-- Called only by the guest-checkout Edge Function, after Paystack confirmed the payment.
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
    unverified_fee, unverified_combo, guest_phone, paystack_reference, created_at, updated_at
  ) values (
    v_ref, v_c.phone, v_c.network, v_c.bundle_name, v_c.bundle_price + v_c.unverified_fee, 'Pending', 'patupaa', null, 'Guest',
    v_c.bundle_price, 'pending', 0, false,
    v_c.unverified_fee, v_c.unverified_combo, v_c.contact_phone, p_reference, now(), now()
  );
  update private.guest_checkouts
     set status = 'paid', order_ref = v_ref, paid_amount = v_paid, paystack_id = p_paystack_id, paid_at = now()
   where reference = p_reference;
  return jsonb_build_object('order_ref', v_ref, 'already', false) || private.guest_receipt(v_ref);
end;
$$;

-- What the guest's receipt and the tracking page show about an order.
create or replace function private.guest_receipt(p_order_ref text)
returns jsonb
language sql
stable
security definer
set search_path = public, private
as $$
  select coalesce((
    select jsonb_build_object(
      'order_ref', o.ref, 'status', coalesce(o."Status", 'Pending'), 'network', o."Network", 'bundle_name', o.bundle_name,
      'phone', o."Phone", 'contact_phone', o.guest_phone, 'created_at', o.created_at, 'updated_at', o.updated_at,
      'amount_paid', coalesce(g.paid_amount, g.total, o."Amount"))
      from public.orders o left join private.guest_checkouts g on g.reference = o.paystack_reference
     where o.ref = p_order_ref), '{}'::jsonb);
$$;

-- A guest looks up an order with its number and their phone (or the number that gets the data).
create or replace function public.guest_track(p_order_ref text, p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_o   public.orders%rowtype;
  v_ph  text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  v_ph := case when v_ph ~ '^233[0-9]{9}$' then '0' || substr(v_ph, 4) else v_ph end;
  select * into v_o from public.orders where ref = upper(trim(coalesce(p_order_ref, '')));
  if not found or v_ph !~ '^0[0-9]{9}$'
     or not (v_o."Phone" = v_ph or public.sms_normalize_phone(v_o.guest_phone) = public.sms_normalize_phone(v_ph)) then
    raise exception 'No order matches that order number and phone number';
  end if;
  return private.guest_receipt(v_o.ref);
end;
$$;

revoke execute on function private.guest_price(text, text) from public, anon, authenticated;
revoke execute on function private.guest_receipt(text) from public, anon, authenticated;
revoke execute on function public.guest_quote(text, text) from public;
revoke execute on function public.guest_start(text, text, text) from public;
revoke execute on function public.guest_track(text, text) from public;
revoke execute on function public.guest_complete(text, bigint, text) from public, anon, authenticated;
grant execute on function public.guest_quote(text, text) to anon, authenticated;
grant execute on function public.guest_start(text, text, text) to anon, authenticated;
grant execute on function public.guest_track(text, text) to anon, authenticated;
grant execute on function public.guest_complete(text, bigint, text) to service_role;

-- Order texts: a guest's go to the phone they gave; they also get the tracking page.
create or replace function public.sms_on_order()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_guest    boolean := new.user_id is null and new.guest_phone is not null;
  v_to       text := case when new.user_id is null and new.guest_phone is not null
                          then public.sms_normalize_phone(new.guest_phone)
                          else public.sms_customer_phone(new.user_id, new."Phone") end;
  v_bundle   text := coalesce(new.bundle_name, '') || ' ' || upper(coalesce(new."Network", ''));
  v_refunded boolean;
begin
  if tg_op = 'INSERT' then
    perform public.sms_enqueue('order_placed', v_to,
      'TRU Data: Order ' || new.ref || ' received. ' || v_bundle || ' to ' || coalesce(new."Phone", '') ||
      ', ' || public.sms_money(new."Amount") || '. We will text you when it is delivered.' ||
      case when v_guest then ' Track it: trudata.rvhssystems.com/#/track' else '' end);
    perform public.sms_enqueue('admin_new_order', null,
      'TRU Data admin: New order ' || new.ref || ' - ' || v_bundle || ' to ' || coalesce(new."Phone", '') ||
      ', ' || public.sms_money(new."Amount") || '.' ||
      case when v_guest then ' GUEST (paid online).' else '' end ||
      case when new.unverified_combo is not null
             then ' UNVERIFIED number, ' || coalesce(new.bundle_name, '') || ' is not sold unverified: send 2 bundles, '
                  || new.unverified_combo || ' (unverified prices).'
           when coalesce(new.unverified_fee, 0) > 0 then ' Unverified number.'
           else '' end);
  elsif new."Status" is distinct from old."Status" then
    if new."Status" = 'Processing' and coalesce(old."Status", '') not in ('Completed', 'Delivered') then
      perform public.sms_enqueue('order_processing', v_to,
        'TRU Data: Your ' || v_bundle || ' order to ' || coalesce(new."Phone", '') ||
        ' (Ref ' || new.ref || ') is being processed now. We will text you when it is delivered.');
    elsif new."Status" = 'Completed' and coalesce(old."Status", '') <> 'Delivered' then
      perform public.sms_enqueue('order_processed', v_to,
        'TRU Data: Your ' || v_bundle || ' order to ' || coalesce(new."Phone", '') ||
        ' (Ref ' || new.ref || ') has been processed successfully. Your data will be delivered shortly.');
    elsif new."Status" = 'Delivered' then
      perform public.sms_enqueue('order_delivered', v_to,
        'TRU Data: Your ' || v_bundle || ' data to ' || coalesce(new."Phone", '') ||
        ' has been delivered. Ref ' || new.ref || '. Thank you!');
    elsif new."Status" = 'Deleted' then
      v_refunded := exists (select 1 from public.transactions where reference = 'RFD-' || new.ref);
      perform public.sms_enqueue('order_cancelled', v_to,
        'TRU Data: Order ' || new.ref || ' (' || v_bundle || ') was cancelled.' ||
        case when v_refunded then ' ' || public.sms_money(new."Amount") || ' has been refunded to your wallet.'
             when v_guest then ' Your payment will be refunded.' else '' end);
    end if;
  end if;
  return null;
end;
$function$;

commit;
