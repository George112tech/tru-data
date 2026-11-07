-- SMS from the admin to customers, and a text when an order is being processed.
--
-- 1. admin_sms_customers(message): one text to every registered customer
--    (not the admin) with a valid Ghana phone number, each number once.
--    admin_sms_audience() says how many that is. Texts to numbers typed by
--    the admin still go through admin_send_sms(numbers, message).
-- 2. Pressing "Process" on an order (status Processing) now texts the
--    customer that it is being processed (SMS switch "order_processing").

begin;

create or replace function public.admin_sms_audience()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case when public.is_admin() then
    (select count(distinct public.sms_normalize_phone(phone))::int from public.profiles
      where coalesce(role, 'user') <> 'admin' and not coalesce(is_admin, false)
        and public.sms_normalize_phone(phone) is not null)
  else 0 end;
$$;

create or replace function public.admin_sms_customers(p_message text)
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_msg text := trim(coalesce(p_message, ''));
  v_n   integer;
begin
  if not public.is_admin() then raise exception 'Admin access only'; end if;
  if char_length(v_msg) < 1 then raise exception 'Type a message first'; end if;
  if char_length(v_msg) > 480 then raise exception 'The message is too long (480 characters at most)'; end if;
  if not exists (select 1 from private.sms_settings where id and api_key is not null and from_number is not null) then
    raise exception 'Set up SMS first (Admin → SMS: API key and sending phone)';
  end if;
  insert into public.sms_outbox (event, to_phone, content)
  select distinct 'admin_broadcast', public.sms_normalize_phone(phone), v_msg
    from public.profiles
   where coalesce(role, 'user') <> 'admin' and not coalesce(is_admin, false)
     and public.sms_normalize_phone(phone) is not null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'No customer has a valid phone number yet'; end if;
  perform private.audit_add('messages', 'sms.broadcast',
    'SMS sent to all customers (' || v_n || ' numbers): ' || left(v_msg, 160),
    'sms_outbox', null, null, null, jsonb_build_object('count', v_n, 'message', v_msg));
  return v_n;
end;
$$;

revoke execute on function public.admin_sms_audience() from public, anon;
grant execute on function public.admin_sms_audience() to authenticated;
revoke execute on function public.admin_sms_customers(text) from public, anon;
grant execute on function public.admin_sms_customers(text) to authenticated;

-- Order texts, now also when the admin starts processing the order.
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
      ', ' || public.sms_money(new."Amount") || '.');
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
