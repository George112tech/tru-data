-- Unverified MTN numbers: an extra per bundle, and two-bundle combos.
--
-- Before: every unverified MTN number paid one fixed extra (GHS 1.80).
-- Now each MTN bundle has its own extra (bundles.unverified_extra), set to
-- what Patupaa adds for unverified numbers; a bundle without one uses the
-- old fixed extra (app_settings.unverified_surcharge).
--
-- Some sizes are not sold to unverified numbers on Patupaa (8GB, 9GB,
-- 12GB). Those are marked bundles.unverified_combo: an unverified number
-- gets them as the cheapest two bundles that add up to the size, at our
-- unverified prices (8GB = 6GB + 2GB). The order keeps the pair in
-- orders.unverified_combo, and the admin's new-order SMS says which two
-- bundles to send (the customer just sees an unverified order).

begin;

alter table public.bundles add column if not exists unverified_extra numeric(10, 2)
  check (unverified_extra is null or unverified_extra between 0 and 100);
alter table public.bundles add column if not exists unverified_combo boolean not null default false;
alter table public.orders add column if not exists unverified_combo text;

-- Patupaa's extras for unverified MTN numbers (6GB: GHS 1.50).
update public.bundles b set unverified_extra = v.extra, unverified_combo = false
  from (values ('1GB', 0.20), ('2GB', 0.60), ('3GB', 0.70), ('4GB', 1.00), ('5GB', 1.00),
               ('6GB', 1.50), ('10GB', 2.50), ('15GB', 3.00), ('20GB', 5.50), ('25GB', 3.00),
               ('30GB', 4.50), ('40GB', 5.50), ('50GB', 16.50)) as v(size, extra)
 where lower(b.network) = 'mtn' and upper(replace(b.size, ' ', '')) = v.size;
-- Not sold to unverified numbers on their own: two bundles instead.
update public.bundles set unverified_combo = true, unverified_extra = null
 where lower(network) = 'mtn' and upper(replace(size, ' ', '')) in ('7GB', '8GB', '9GB', '12GB', '100GB');

-- "8GB" -> 8000, "500MB" -> 500 (null when the size is not like that).
create or replace function private.bundle_mb(p_size text)
returns numeric
language sql
immutable
as $$
  select case when m is null then null
              when upper(m[3]) = 'GB' then m[1]::numeric * 1000
              else m[1]::numeric end
    from (select regexp_match(trim(coalesce(p_size, '')), '^([0-9]+(\.[0-9]+)?)\s*(GB|MB)$', 'i') as m) x;
$$;

-- What an order of this bundle to this number costs on top of the price,
-- and the two bundles to send when it is a combo.
create or replace function private.unverified_quote(p_phone text, p_bundle_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_b       public.bundles%rowtype;
  v_default numeric;
  v_label   text;
  v_total   numeric;
begin
  select * into v_b from public.bundles where id = p_bundle_id;
  if not found or lower(coalesce(v_b.network, '')) <> 'mtn'
     or coalesce((select value = 'true'::jsonb from public.app_settings where key = 'unverified_enabled'), false) = false
     or exists (select 1 from public.verified_numbers where phone = p_phone) then
    return jsonb_build_object('fee', 0, 'combo', null);
  end if;
  v_default := coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'unverified_surcharge'), 1.8);
  if v_b.unverified_combo then
    select a.size || ' + ' || c.size,
           (a.price + coalesce(a.unverified_extra, v_default)) + (c.price + coalesce(c.unverified_extra, v_default))
      into v_label, v_total
      from public.bundles a, public.bundles c
     where a.active and c.active and lower(a.network) = 'mtn' and lower(c.network) = 'mtn'
       and not a.unverified_combo and not c.unverified_combo
       and private.bundle_mb(a.size) >= private.bundle_mb(c.size)
       and private.bundle_mb(a.size) + private.bundle_mb(c.size) = private.bundle_mb(v_b.size)
     order by 2, private.bundle_mb(a.size) desc
     limit 1;
    if v_label is not null then
      return jsonb_build_object('fee', greatest(round(v_total - v_b.price, 2), 0), 'combo', v_label);
    end if;
  end if;
  return jsonb_build_object('fee', coalesce(v_b.unverified_extra, v_default), 'combo', null);
end;
$$;
revoke execute on function private.unverified_quote(text, text) from public, anon, authenticated;

-- The order form: now per bundle (p_bundle_id), with the combo if any.
drop function if exists public.number_status(text, text);
create or replace function public.number_status(p_phone text, p_network text, p_bundle_id text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare v_q jsonb;
begin
  if auth.uid() is null then
    raise exception 'Please log in first';
  end if;
  if coalesce(p_phone, '') !~ '^0[0-9]{9}$' then
    raise exception 'Enter a valid 10-digit Ghana phone number';
  end if;
  if p_bundle_id is not null then
    v_q := private.unverified_quote(p_phone, p_bundle_id);
  else
    v_q := jsonb_build_object('fee', private.unverified_fee(p_phone, p_network), 'combo', null);
  end if;
  return jsonb_build_object(
    'applies', lower(coalesce(p_network, '')) = 'mtn'
               and coalesce((select value = 'true'::jsonb from public.app_settings where key = 'unverified_enabled'), false),
    'verified', exists (select 1 from public.verified_numbers where phone = p_phone),
    'fee', v_q -> 'fee',
    'combo', v_q -> 'combo');
end;
$$;
revoke execute on function public.number_status(text, text, text) from public, anon;
grant execute on function public.number_status(text, text, text) to authenticated;

create or replace function public.place_order(p_bundle_id text, p_phone text, p_agent_code text default null::text, p_request_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_bundle    public.bundles%rowtype;
  v_price     numeric;
  v_balance   numeric;
  v_existing  public.orders%rowtype;
  v_ref       text;
  v_quote     jsonb;
  v_fee       numeric := 0;
  v_combo     text;
begin
  if v_uid is null then
    raise exception 'Please log in first';
  end if;
  select balance into v_balance from public.profiles where id = v_uid for update;
  if not found then
    raise exception 'Profile not found';
  end if;
  if p_request_id is not null then
    select * into v_existing from public.orders
    where client_request_id = p_request_id and user_id = v_uid;
    if found then
      return jsonb_build_object('ref', v_existing.ref, 'amount', v_existing."Amount",
                                'new_balance', v_balance, 'duplicate', true,
                                'unverified_fee', v_existing.unverified_fee,
                                'unverified_combo', v_existing.unverified_combo);
    end if;
  end if;
  if coalesce(p_phone, '') !~ '^0(24|54|55|59|25|53|63|77|57|20|50|26|56|27|76|23|28|58)[0-9]{7}$' then
    raise exception 'Enter a valid 10-digit Ghana phone number';
  end if;
  select * into v_bundle from public.bundles where id = p_bundle_id and active;
  if not found then
    raise exception 'Bundle not found';
  end if;
  -- Unverified MTN number: this bundle's extra, or two bundles for a combo.
  v_quote := private.unverified_quote(p_phone, v_bundle.id);
  v_fee   := coalesce((v_quote ->> 'fee')::numeric, 0);
  v_combo := v_quote ->> 'combo';
  v_price := v_bundle.price + v_fee;
  if v_balance < v_price then
    raise exception 'Insufficient balance. Please deposit funds.';
  end if;
  v_ref := 'ORD-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));
  update public.profiles set balance = balance - v_price, updated_at = now() where id = v_uid;
  insert into public.transactions (user_id, type, amount, reference, status, created_at)
  values (v_uid, 'purchase', v_price, v_ref, 'completed', now());
  insert into public.orders (
    ref, "Phone", "Network", bundle_name, "Amount", "Status", provider, user_id,
    pricing_mode, base_price_used, api_status, retry_count, processed_by_api,
    client_request_id, unverified_fee, unverified_combo, created_at, updated_at
  ) values (
    v_ref, p_phone, v_bundle.network, v_bundle.size, v_price, 'Pending', 'patupaa', v_uid,
    'system', v_bundle.price, 'pending', 0, false, p_request_id, v_fee, v_combo, now(), now()
  );
  return jsonb_build_object('ref', v_ref, 'amount', v_price,
                            'new_balance', v_balance - v_price, 'duplicate', false,
                            'unverified_fee', v_fee, 'unverified_combo', v_combo);
end;
$function$;

-- Order texts: the admin's new-order text says which two bundles to send.
create or replace function public.sms_on_order()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_to       text := public.sms_customer_phone(new.user_id, new."Phone");
  v_bundle   text := coalesce(new.bundle_name, '') || ' ' || upper(coalesce(new."Network", ''));
  v_refunded boolean;
begin
  if tg_op = 'INSERT' then
    perform public.sms_enqueue('order_placed', v_to,
      'TRU Data: Order ' || new.ref || ' received. ' || v_bundle || ' to ' || coalesce(new."Phone", '') ||
      ', ' || public.sms_money(new."Amount") || '. We will text you when it is delivered.');
    perform public.sms_enqueue('admin_new_order', null,
      'TRU Data admin: New order ' || new.ref || ' - ' || v_bundle || ' to ' || coalesce(new."Phone", '') ||
      ', ' || public.sms_money(new."Amount") || '.' ||
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
        case when v_refunded then ' ' || public.sms_money(new."Amount") || ' has been refunded to your wallet.' else '' end);
    end if;
  end if;
  return null;
end;
$function$;

commit;
