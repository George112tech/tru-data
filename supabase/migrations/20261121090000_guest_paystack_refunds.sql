-- Automatic Paystack refunds for guests' cancelled orders.
--
-- Guests have no wallet, so cancelling their order used to mean refunding by
-- hand in the Paystack dashboard. Now the admin dashboard asks "Refund this
-- guest's payment through Paystack?" and the guest-refund Edge Function asks
-- Paystack to refund the whole payment to the MoMo or card it came from.
--
-- orders gets the refund's state (guest orders paid with Paystack only):
--   guest_refund_status  requesting | pending | processing | processed | failed
--   guest_refund_amount  what Paystack is refunding (GHS)
--   guest_refund_id      Paystack's refund id
--   guest_refund_at      when it was asked for
--   guest_refund_error   why it failed (shown to the admin)
-- Paystack's webhook (paystack-webhook) moves it to processed / failed.
--
-- Texts: a guest whose order is cancelled with a refund is told the money is
-- being refunded to the MoMo or card they paid with. When the refund is made
-- after the order was already cancelled (the Refund button), they get that
-- text then.
--
-- Service-role helpers for the Edge Functions (one refund per order: a second
-- request while one is pending or done is refused):
--   guest_refund_claim(order ref)            -> the Paystack reference to refund
--   guest_refund_set(order ref, status, amount, refund id, error)
--   guest_refund_webhook(GST reference, status)

alter table public.orders
  add column if not exists guest_refund_status text,
  add column if not exists guest_refund_amount numeric(10, 2),
  add column if not exists guest_refund_id text,
  add column if not exists guest_refund_at timestamptz,
  add column if not exists guest_refund_error text;
alter table public.orders drop constraint if exists orders_guest_refund_status_check;
alter table public.orders add constraint orders_guest_refund_status_check
  check (guest_refund_status is null or guest_refund_status in ('requesting', 'pending', 'processing', 'processed', 'failed'));

create or replace function public.guest_refund_claim(p_ref text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_o public.orders%rowtype;
  v_paid numeric;
begin
  select * into v_o from public.orders where ref = p_ref for update;
  if not found then
    raise exception 'Order not found';
  end if;
  if v_o.user_id is not null or coalesce(v_o.paystack_reference, '') !~ '^GST-' then
    raise exception 'Only orders bought without an account can be refunded through Paystack. Use the wallet refund for customers with an account.';
  end if;
  if coalesce(v_o.guest_paid_with, 'paystack') <> 'paystack' then
    raise exception 'This guest paid with SeevPlus. Refund it in your SeevPlus dashboard.';
  end if;
  if v_o.guest_refund_status in ('pending', 'processing', 'processed') then
    raise exception 'This payment is already being refunded (%).', v_o.guest_refund_status;
  end if;
  if v_o.guest_refund_status = 'requesting' and v_o.guest_refund_at > now() - interval '2 minutes' then
    raise exception 'A refund for this order was just asked for. Wait a moment and check again.';
  end if;
  update public.orders
     set guest_refund_status = 'requesting', guest_refund_at = now(), guest_refund_error = null
   where ref = p_ref;
  select paid_amount into v_paid from private.guest_checkouts where reference = v_o.paystack_reference;
  return jsonb_build_object('reference', v_o.paystack_reference, 'paid', v_paid, 'status', v_o."Status");
end;
$$;

create or replace function public.guest_refund_set(p_ref text, p_status text, p_amount numeric default null,
                                                   p_refund_id text default null, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if p_status not in ('pending', 'processing', 'processed', 'failed') then
    raise exception 'Unexpected refund status';
  end if;
  update public.orders
     set guest_refund_status = p_status,
         guest_refund_amount = coalesce(p_amount, guest_refund_amount),
         guest_refund_id = coalesce(p_refund_id, guest_refund_id),
         guest_refund_error = case when p_status = 'failed' then left(p_error, 300) else null end
   where ref = p_ref;
  perform private.audit_add('money', 'guest.refund_' || p_status,
    'Guest refund for ' || p_ref || ': ' || p_status ||
      coalesce(' ' || private.ghs(p_amount), '') || coalesce(' (' || left(p_error, 120) || ')', ''),
    'orders', p_ref, null, null,
    jsonb_build_object('status', p_status, 'amount', p_amount, 'refund_id', p_refund_id, 'error', p_error));
end;
$$;

-- From Paystack's webhook: never moves a finished refund backwards.
create or replace function public.guest_refund_webhook(p_reference text, p_status text)
returns boolean
language plpgsql
security definer
set search_path = public, private
as $$
declare v_ref text;
begin
  if p_status not in ('pending', 'processing', 'processed', 'failed') then
    return false;
  end if;
  select ref into v_ref from public.orders
   where paystack_reference = p_reference and user_id is null
     and coalesce(guest_refund_status, '') <> 'processed';
  if v_ref is null then
    return false;
  end if;
  perform public.guest_refund_set(v_ref, p_status, null, null,
    case when p_status = 'failed' then 'Paystack says the refund failed' end);
  return true;
end;
$$;

revoke execute on function public.guest_refund_claim(text) from public, anon, authenticated;
revoke execute on function public.guest_refund_set(text, text, numeric, text, text) from public, anon, authenticated;
revoke execute on function public.guest_refund_webhook(text, text) from public, anon, authenticated;
grant execute on function public.guest_refund_claim(text) to service_role;
grant execute on function public.guest_refund_set(text, text, numeric, text, text) to service_role;
grant execute on function public.guest_refund_webhook(text, text) to service_role;

-- The cancellation text says the money is coming back when it is.
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
             when v_guest and new.guest_refund_status in ('pending', 'processing', 'processed')
               then ' Your payment' || coalesce(' of ' || public.sms_money(new.guest_refund_amount), '') ||
                    ' is being refunded to the MoMo or card you paid with.'
             when v_guest then ' Your payment will be refunded.' else '' end);
    end if;
  end if;
  return null;
end;
$$;

-- A refund made after the order was already cancelled (the Refund button).
create or replace function private.sms_on_guest_refund()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if new."Status" = 'Deleted' and new.user_id is null and new.guest_phone is not null
     and new.guest_refund_status in ('pending', 'processing', 'processed')
     and coalesce(old.guest_refund_status, '') not in ('pending', 'processing', 'processed') then
    perform public.sms_enqueue('order_cancelled', public.sms_normalize_phone(new.guest_phone),
      'TRU Data: Your payment' || coalesce(' of ' || public.sms_money(new.guest_refund_amount), '') ||
      ' for order ' || new.ref || ' is being refunded to the MoMo or card you paid with.');
  end if;
  return null;
end;
$$;
revoke execute on function private.sms_on_guest_refund() from public, anon, authenticated;

drop trigger if exists sms_guest_refund on public.orders;
create trigger sms_guest_refund
  after update of guest_refund_status on public.orders
  for each row execute function private.sms_on_guest_refund();
