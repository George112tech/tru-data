-- "Complete" and "Delivered" are different steps.
--
-- Complete means the order has been processed with the supplier; the data is
-- on its way. Delivered means it has arrived. The customer used to get the
-- "has been delivered" text when the admin pressed Complete, and nothing when
-- the order was later marked Delivered. Now:
--   Completed -> "processed successfully, your data will be delivered shortly"
--                (SMS event order_processed, its own switch in Admin → SMS)
--   Delivered -> "has been delivered" (order_delivered), also after Completed
--
-- Run AFTER 20261102090000_account_deletion_deposit_details_agent_sms.sql.

create or replace function public.sms_on_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
    if new."Status" = 'Completed' and coalesce(old."Status", '') <> 'Delivered' then
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
$$;

revoke execute on function public.sms_on_order() from public, anon, authenticated;
