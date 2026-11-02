-- Text messages for online (Paystack) top-ups.
-- Customer: "Your online payment of GHS 103.63 was received. GHS 100.00 has
-- been added to your wallet (GHS 3.63 payment fee). New balance ..."
-- Admin: a new alert "Online payment received" (switch in Admin -> SMS).
-- Mobile Money texts are unchanged.
--
-- Run AFTER 20261102150000_deposit_fee_momo_network_deletions.sql.

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
  if new.type = 'deposit' and new.status = 'completed' then
    select balance, coalesce(nullif(full_name, ''), email) || ' (' || coalesce(deposit_code, '?') || ')'
      into v_balance, v_who from public.profiles where id = new.user_id;
    v_paid := new.amount + coalesce(new.fee, 0);
    if new.reference like 'MOMO-%' then
      -- Mobile Money (approved by the admin)
      perform public.sms_enqueue('deposit_credited', public.sms_customer_phone(new.user_id, null),
        'TRU Data: ' || public.sms_money(new.amount) || ' has been added to your wallet' ||
        case when coalesce(new.fee, 0) > 0
             then ' (' || public.sms_money(v_paid) || ' received, less ' || public.sms_money(new.fee) || ' fee)'
             else '' end ||
        '. New balance ' || public.sms_money(v_balance) || '.');
    else
      -- Online payment (Paystack): the payment fee is not credited
      perform public.sms_enqueue('deposit_credited', public.sms_customer_phone(new.user_id, null),
        'TRU Data: Your online payment of ' || public.sms_money(v_paid) || ' was received. ' ||
        public.sms_money(new.amount) || ' has been added to your wallet' ||
        case when coalesce(new.fee, 0) > 0 then ' (' || public.sms_money(new.fee) || ' payment fee)' else '' end ||
        '. New balance ' || public.sms_money(v_balance) || '.');
      perform public.sms_enqueue('admin_online_deposit', null,
        'TRU Data admin: Online payment of ' || public.sms_money(v_paid) || ' from ' || coalesce(v_who, 'a customer') ||
        '. ' || public.sms_money(new.amount) || ' credited. Ref ' || new.reference || '.');
    end if;
  end if;
  return null;
end;
$$;

revoke execute on function public.sms_on_transaction() from public, anon, authenticated;
