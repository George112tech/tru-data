-- App notifications go to the account an order or payment belongs to.
--
-- push_from_sms found the customer by the phone number a text was sent to.
-- For orders and wallet events that is not always the right account: a
-- customer without a phone number on their profile gets texts at the number
-- they bought for, which can belong to someone else's account. Now the
-- triggers that send these texts (sms_on_order, sms_on_transaction,
-- sms_on_deposit_request) say whose event it is (transaction setting
-- tru.push_user) and the notification goes to that account. The phone number
-- is still used for guests, the admin's messages and account-locked texts.
-- The texts themselves are unchanged.

create or replace function private.push_from_sms(p_event text, p_to text, p_content text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_to    text := public.sms_normalize_phone(p_to);
  v_owner text := nullif(current_setting('tru.push_user', true), '');
  v_body  text;
  v_title text;
  v_open  text;
  v_ref   text;
  r       record;
begin
  -- Alerts for the admin and test texts are not for customers.
  if p_event = 'test' or (p_event like 'admin%' and p_event not in ('admin_message', 'admin_broadcast')) then
    return;
  end if;
  v_body := regexp_replace(coalesce(p_content, ''), '^TRU Data( admin)?:\s*', '');
  if v_body = '' then
    return;
  end if;
  v_ref := substring(p_content from 'ORD-[A-Z0-9]+');
  v_title := case p_event
    when 'order_placed'     then 'Order received'
    when 'order_processing' then 'Your order is being processed'
    when 'order_processed'  then 'Order processed'
    when 'order_delivered'  then 'Data delivered'
    when 'order_cancelled'  then 'Order cancelled'
    when 'deposit_credited' then 'Wallet credited'
    when 'deposit_rejected' then 'Deposit not confirmed'
    when 'account_locked'   then 'Account locked'
    else 'TRU Data' end;
  v_open := case when p_event like 'order%' then '#/my-orders'
                 when p_event like 'deposit%' then '#/wallet'
                 else '#/home' end;
  -- Orders and wallet: the account the order or payment belongs to (set by the
  -- text's trigger), whatever number the text goes to.
  if v_owner is not null then
    perform private.push_enqueue(v_owner::uuid, v_title, v_body,
      jsonb_strip_nulls(jsonb_build_object('kind', p_event, 'ref', v_ref, 'open', v_open)));
    return;
  end if;
  -- Otherwise (guests, the admin's messages, account locked): the account with that phone.
  if v_to is null then
    return;
  end if;
  for r in select distinct p.id from public.profiles p join public.push_devices d on d.user_id = p.id
            where public.sms_normalize_phone(p.phone) = v_to loop
    perform private.push_enqueue(r.id, v_title, v_body,
      jsonb_strip_nulls(jsonb_build_object('kind', p_event, 'ref', v_ref, 'open', v_open)));
  end loop;
exception when others then
  raise warning 'push_from_sms(%) failed: %', p_event, sqlerrm;
end;
$$;

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
  -- The notification for this text goes to the account that owns the order.
  perform set_config('tru.push_user', coalesce(new.user_id::text, ''), true);
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
  perform set_config('tru.push_user', '', true);
  return null;
end;
$$;

create or replace function public.sms_on_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric;
  v_who     text;
  v_paid    numeric;
begin
  -- The notification for this text goes to the account that was credited.
  perform set_config('tru.push_user', coalesce(new.user_id::text, ''), true);
  if new.type = 'deposit' and new.status = 'completed' then
    select balance, coalesce(nullif(full_name, ''), email) || ' (' || coalesce(deposit_code, '?') || ')'
      into v_balance, v_who from public.profiles where id = new.user_id;
    v_paid := new.amount + coalesce(new.fee, 0);
    if new.reference like 'MOMO-%' then
      perform public.sms_enqueue('deposit_credited', public.sms_customer_phone(new.user_id, null),
        'TRU Data: ' || public.sms_money(new.amount) || ' has been added to your wallet' ||
        case when coalesce(new.fee, 0) > 0
             then ' (' || public.sms_money(v_paid) || ' received, less ' || public.sms_money(new.fee) || ' fee)'
             else '' end ||
        '. New balance ' || public.sms_money(v_balance) || '.');
    else
      perform public.sms_enqueue('deposit_credited', public.sms_customer_phone(new.user_id, null),
        'TRU Data: Your online payment of ' || public.sms_money(v_paid) || ' was received. ' ||
        public.sms_money(new.amount) || ' has been added to your wallet' ||
        case when coalesce(new.fee, 0) > 0 then ' (' || public.sms_money(new.fee) || ' payment fee)' else '' end ||
        '. New balance ' || public.sms_money(v_balance) || '.');
      perform set_config('tru.push_user', '', true);
      perform public.sms_enqueue('admin_online_deposit', null,
        'TRU Data admin: Online payment of ' || public.sms_money(v_paid) || ' from ' || coalesce(v_who, 'a customer') ||
        '. ' || public.sms_money(new.amount) || ' credited. Ref ' || new.reference || '.');
    end if;
  end if;
  perform set_config('tru.push_user', '', true);
  return null;
end;
$$;

create or replace function public.sms_on_deposit_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_who text;
begin
  if tg_op = 'INSERT' then
    select coalesce(nullif(full_name, ''), email) || ' (' || coalesce(deposit_code, '?') || ')'
      into v_who from public.profiles where id = new.user_id;
    perform public.sms_enqueue('admin_new_deposit', null,
      'TRU Data admin: ' || coalesce(v_who, 'A customer') || ' says they sent ' || public.sms_money(new.amount) ||
      coalesce(' (MoMo ID ' || new.momo_txn_id || ')', '') || '. Check and approve in Deposits.');
  elsif new.status = 'rejected' and old.status = 'pending' then
    -- The notification for this text goes to the account that asked.
    perform set_config('tru.push_user', coalesce(new.user_id::text, ''), true);
    perform public.sms_enqueue('deposit_rejected', public.sms_customer_phone(new.user_id, new.sender_phone),
      'TRU Data: We could not confirm your deposit of ' || public.sms_money(new.amount) || '.' ||
      coalesce(' ' || rtrim(nullif(left(trim(new.admin_note), 100), ''), '.') || '.', '') ||
      ' Call 0505175472 if you need help.');
    perform set_config('tru.push_user', '', true);
  end if;
  return null;
end;
$$;
