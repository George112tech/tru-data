-- Orders start as "Initiating" and move to "Processing" by themselves.
--
-- New order flow:
--   Initiating  the order was just placed (the customer sees a small spinner)
--   Processing  about 30 seconds later, automatically; the customer gets the
--               "being processed" text then (once: pressing Process later
--               does not change the status, so no second text)
--   Delivered   the admin presses Delivered; the customer gets the delivery
--               text
-- "Completed" is no longer used by the dashboard (old orders keep it).
--
-- How:
--   - orders.Status allows 'Initiating'.
--   - A BEFORE INSERT trigger turns a new order's 'Pending' (what
--     place_order and guest_complete write) into 'Initiating', so every way
--     of placing an order is covered.
--   - pg_cron runs private.advance_initiating_orders() every 10 seconds: it
--     moves orders that have been Initiating for 30 seconds to Processing.
--     The existing sms_on_order trigger sends the "being processed" text on
--     that change.
--   - sms_on_order: a guest's "being processed" text now carries the track
--     link too (it was only in the "received" text, which can be switched off
--     in Admin -> SMS).
--
-- Also (sign-up protection): a second scanner account
-- (aud3764e403932f@ghostmail.dev) came straight through the Supabase sign-up
-- API, like the first. ghostmail.dev joins the blocked domains, and a new
-- account must carry the terms acceptance that the site's sign-up form always
-- sends, so direct API sign-ups by scanners are refused whatever email they
-- use. (Accounts made by hand in the Supabase dashboard are refused too: make
-- them through the site.)

-- ===== Orders =====
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check ("Status" = any (array['Initiating', 'Pending', 'Processing', 'Completed', 'Delivered', 'Deleted']));

create or replace function private.order_starts_initiating()
returns trigger
language plpgsql
set search_path = public, private
as $$
begin
  if new."Status" is null or new."Status" = 'Pending' then
    new."Status" := 'Initiating';
  end if;
  return new;
end;
$$;

drop trigger if exists order_starts_initiating on public.orders;
create trigger order_starts_initiating
  before insert on public.orders
  for each row execute function private.order_starts_initiating();

create index if not exists orders_initiating_idx on public.orders (created_at) where "Status" = 'Initiating';

create or replace function private.advance_initiating_orders()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare v_n integer;
begin
  update public.orders
     set "Status" = 'Processing', updated_at = now()
   where "Status" = 'Initiating'
     and created_at <= now() - interval '30 seconds';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function private.advance_initiating_orders() from public, anon, authenticated;
revoke execute on function private.order_starts_initiating() from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'advance-initiating-orders';
select cron.schedule('advance-initiating-orders', '10 seconds', 'select private.advance_initiating_orders()');

-- The texts: same as before, plus the track link on a guest's "being processed" text.
create or replace function public.sms_on_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
        ' (Ref ' || new.ref || ') is being processed now. We will text you when it is delivered.' ||
        case when v_guest then ' Track it: trudata.rvhssystems.com/#/track' else '' end);
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
$$;

-- ===== Sign-up protection =====
insert into private.blocked_email_domains (domain) values ('ghostmail.dev') on conflict (domain) do nothing;

create or replace function private.refuse_disposable_email()
returns trigger
language plpgsql
security definer
set search_path = private, public
as $$
declare
  v_domain text := lower(split_part(coalesce(new.email, ''), '@', 2));
begin
  if v_domain <> '' and exists (
       select 1 from private.blocked_email_domains d
        where v_domain = d.domain or v_domain like '%.' || d.domain) then
    raise exception 'Please use your real email address. Temporary email addresses are not accepted.'
      using errcode = 'check_violation';
  end if;
  -- The site's sign-up form always sends the terms acceptance; scanners
  -- calling the sign-up API directly do not.
  if tg_op = 'INSERT' and coalesce(new.raw_user_meta_data ->> 'terms_accepted_at', '') = '' then
    raise exception 'Please sign up on the TRU Data website or app.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
