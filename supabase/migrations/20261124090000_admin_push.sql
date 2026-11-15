-- App notifications for the admin, and the right page when one is tapped.
--
-- The admin's three alerts (new order, a customer says they sent MoMo, an
-- online payment was credited) now also go as app notifications to every
-- admin account that has the app on a phone, as well as the texts to the
-- admin phone; they are sent even when SMS is switched off. Tapping one opens
-- the admin dashboard on the Orders or Deposits tab (#/admin/orders,
-- #/admin/deposits). Customers never get them.
--
-- Customer notifications now open the site's real addresses: #/orders (My
-- Orders), #/wallet, #/buy. (The site also accepts the older #/my-orders and
-- #/home, sent before this change.)

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
  if p_event = 'test' then
    return;
  end if;
  v_body := regexp_replace(coalesce(p_content, ''), '^TRU Data( admin)?:\s*', '');
  if v_body = '' then
    return;
  end if;
  v_ref := substring(p_content from 'ORD-[A-Z0-9]+');
  -- Admin alerts: to every admin who has the app on a phone (never to customers).
  if p_event in ('admin_new_order', 'admin_new_deposit', 'admin_online_deposit') then
    for r in select distinct p.id from public.profiles p join public.push_devices d on d.user_id = p.id
              where coalesce(p.role, '') = 'admin' or coalesce(p.is_admin, false) loop
      perform private.push_enqueue(r.id,
        case p_event when 'admin_new_order' then 'New order'
                     when 'admin_new_deposit' then 'Deposit to check'
                     else 'Online payment received' end,
        regexp_replace(v_body, '^New order ', ''),
        jsonb_strip_nulls(jsonb_build_object('kind', p_event, 'ref', v_ref,
          'open', case p_event when 'admin_new_order' then '#/admin/orders' else '#/admin/deposits' end)));
    end loop;
    return;
  end if;
  -- Other admin alerts are not for anyone's app.
  if p_event like 'admin%' and p_event not in ('admin_message', 'admin_broadcast') then
    return;
  end if;
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
  v_open := case when p_event like 'order%' then '#/orders'
                 when p_event like 'deposit%' then '#/wallet'
                 else '#/buy' end;
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
