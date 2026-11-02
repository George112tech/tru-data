-- 1. A fee (3% to start) is taken off Mobile Money deposits when they are
--    credited: send GHS 41.00, receive GHS 39.77. The admin can change the
--    percentage in Admin → Deposits. Each request keeps the percentage that was
--    shown when it was sent, so requests made before this change get no fee.
-- 2. The network of the MoMo number customers pay to (MTN, Telecel or
--    AirtelTigo) is saved and shown on every wallet page.
-- 3. The admin can delete messages from the SMS log.
-- 4. Agents can delete their own price-change requests once answered.
--
-- Run AFTER 20261102120000_order_processed_message.sql.

begin;

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('momo_network', '"Telecel"'),        -- 050... numbers are Telecel
  ('deposit_fee_percent', '3')
on conflict (key) do nothing;

create or replace function public.check_app_setting()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.key = 'momo_number' and (jsonb_typeof(new.value) <> 'string' or new.value #>> '{}' !~ '^0[2-5][0-9]{8}$') then
    raise exception 'The MoMo number must be 10 digits, like 0505175472';
  end if;
  if new.key = 'momo_name' and (jsonb_typeof(new.value) <> 'string' or char_length(trim(new.value #>> '{}')) not between 3 and 60) then
    raise exception 'Enter the account name as it shows on MoMo (3 to 60 letters)';
  end if;
  if new.key = 'momo_network' and (jsonb_typeof(new.value) <> 'string' or new.value #>> '{}' not in ('MTN', 'Telecel', 'AirtelTigo')) then
    raise exception 'Choose the network of the MoMo number: MTN, Telecel or AirtelTigo';
  end if;
  if new.key = 'deposit_fee_percent' and (jsonb_typeof(new.value) <> 'number' or (new.value #>> '{}')::numeric not between 0 and 10) then
    raise exception 'The deposit fee must be between 0 and 10 percent';
  end if;
  return new;
end;
$$;

create or replace function public.deposit_fee_percent()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value #>> '{}')::numeric from public.app_settings
                   where key = 'deposit_fee_percent' and jsonb_typeof(value) = 'number'), 0);
$$;

-- ---------------------------------------------------------------------------
-- Deposit fee
-- ---------------------------------------------------------------------------
alter table public.deposit_requests
  add column if not exists fee_percent numeric(5, 2),
  add column if not exists fee_amount  numeric(10, 2);

-- New requests remember the fee shown to the customer at that moment.
create or replace function public.deposit_request_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.fee_percent := public.deposit_fee_percent();
  return new;
end;
$$;
drop trigger if exists deposit_request_fee on public.deposit_requests;
create trigger deposit_request_fee
  before insert on public.deposit_requests
  for each row execute function public.deposit_request_fee();

-- Credits the amount received less the fee; the fee is kept on the wallet transaction.
create or replace function public.credit_momo_deposit_net(
  p_user uuid, p_received numeric, p_fee_percent numeric, p_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fee     numeric := round(p_received * coalesce(p_fee_percent, 0) / 100, 2);
  v_net     numeric := round(p_received, 2) - round(p_received * coalesce(p_fee_percent, 0) / 100, 2);
  v_balance numeric;
begin
  if v_net <= 0 then
    raise exception 'Nothing left to credit after the fee';
  end if;
  insert into public.transactions (user_id, type, amount, fee, reference, status, created_at)
  values (p_user, 'deposit', v_net, v_fee, p_reference, 'completed', now())
  on conflict (reference) do nothing;
  if not found then
    raise exception 'This MoMo transaction has already been credited (%)', p_reference;
  end if;
  update public.profiles set balance = coalesce(balance, 0) + v_net, updated_at = now()
  where id = p_user
  returning balance into v_balance;
  return jsonb_build_object('received', round(p_received, 2), 'fee', v_fee, 'credited', v_net, 'new_balance', v_balance);
end;
$$;
revoke execute on function public.credit_momo_deposit_net(uuid, numeric, numeric, text) from public, anon, authenticated;

create or replace function public.approve_deposit_request(p_id uuid, p_amount numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.deposit_requests%rowtype;
  v_amount numeric;
  v_res jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_req from public.deposit_requests where id = p_id for update;
  if not found then
    raise exception 'Deposit request not found';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request was already %', v_req.status;
  end if;
  v_amount := round(coalesce(p_amount, v_req.amount), 2);
  if v_amount <= 0 or v_amount > 10000 then
    raise exception 'Amount must be between GHS 0.01 and GHS 10,000';
  end if;
  v_res := public.credit_momo_deposit_net(
    v_req.user_id, v_amount, coalesce(v_req.fee_percent, 0),
    coalesce('MOMO-' || v_req.momo_txn_id, 'MOMO-REQ-' || v_req.id::text));
  update public.deposit_requests
  set status = 'approved', credited_amount = (v_res ->> 'credited')::numeric, fee_amount = (v_res ->> 'fee')::numeric,
      reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id;
  return v_res;
end;
$$;

-- Payments that came in without a request: the current fee applies.
create or replace function public.admin_credit_wallet(
  p_deposit_code text, p_amount numeric, p_momo_txn_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_txn     text := nullif(upper(trim(coalesce(p_momo_txn_id, ''))), '');
  v_pct     numeric;
  v_res     jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_profile from public.profiles where deposit_code = upper(trim(p_deposit_code));
  if not found then
    raise exception 'No customer has the reference %', upper(trim(p_deposit_code));
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 10000 then
    raise exception 'Amount must be between GHS 0.01 and GHS 10,000';
  end if;
  -- A matching pending request keeps the fee it was sent with.
  select fee_percent into v_pct from public.deposit_requests
  where v_txn is not null and momo_txn_id = v_txn and status = 'pending' limit 1;
  v_pct := coalesce(v_pct, public.deposit_fee_percent());
  v_res := public.credit_momo_deposit_net(
    v_profile.id, p_amount, v_pct,
    coalesce('MOMO-' || v_txn, 'MOMO-ADMIN-' || gen_random_uuid()::text));
  if v_txn is not null then
    update public.deposit_requests
    set status = 'approved', credited_amount = (v_res ->> 'credited')::numeric, fee_amount = (v_res ->> 'fee')::numeric,
        reviewed_at = now(), reviewed_by = auth.uid()
    where momo_txn_id = v_txn and status = 'pending';
  end if;
  return v_res || jsonb_build_object('name', v_profile.full_name, 'email', v_profile.email);
end;
$$;

-- The "added to your wallet" text shows the fee.
create or replace function public.sms_on_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_balance numeric;
begin
  if new.type = 'deposit' and new.status = 'completed' then
    select balance into v_balance from public.profiles where id = new.user_id;
    perform public.sms_enqueue('deposit_credited', public.sms_customer_phone(new.user_id, null),
      'TRU Data: ' || public.sms_money(new.amount) || ' has been added to your wallet' ||
      case when coalesce(new.fee, 0) > 0
           then ' (' || public.sms_money(new.amount + new.fee) || ' received, less ' || public.sms_money(new.fee) || ' fee)'
           else '' end ||
      '. New balance ' || public.sms_money(v_balance) || '.');
  end if;
  return null;
end;
$$;

revoke execute on function public.deposit_request_fee() from public, anon, authenticated;
revoke execute on function public.sms_on_transaction() from public, anon, authenticated;
revoke execute on function public.approve_deposit_request(uuid, numeric) from public, anon;
grant execute on function public.approve_deposit_request(uuid, numeric) to authenticated;
revoke execute on function public.admin_credit_wallet(text, numeric, text) from public, anon;
grant execute on function public.admin_credit_wallet(text, numeric, text) to authenticated;
grant execute on function public.deposit_fee_percent() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Admin deletes messages from the SMS log
-- ---------------------------------------------------------------------------
-- A message still waiting to go out is cancelled by deleting it.
create or replace function public.admin_delete_sms(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  delete from public.sms_outbox where id = any (coalesce(p_ids, '{}'));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- p_which: 'sent' (sent and skipped), 'failed' or 'all'.
create or replace function public.admin_clear_sms(p_which text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if p_which not in ('sent', 'failed', 'all') then
    raise exception 'Choose sent, failed or all';
  end if;
  delete from public.sms_outbox
  where p_which = 'all'
     or (p_which = 'sent' and status in ('sent', 'skipped'))
     or (p_which = 'failed' and status = 'failed');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.admin_delete_sms(uuid[]) from public, anon;
grant execute on function public.admin_delete_sms(uuid[]) to authenticated;
revoke execute on function public.admin_clear_sms(text) from public, anon;
grant execute on function public.admin_clear_sms(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Agents delete their answered price-change requests
-- ---------------------------------------------------------------------------
-- Only approved or rejected ones; an approved price window stays open.
create or replace function public.delete_price_unlock_request(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.price_unlock_requests r
  where r.id = p_id
    and r.status in ('approved', 'rejected')
    and r.agent_profile_id in (select id from public.agent_profiles where user_id = auth.uid());
  if not found then
    raise exception 'Only your own approved or rejected requests can be deleted';
  end if;
end;
$$;
revoke execute on function public.delete_price_unlock_request(uuid) from public, anon;
grant execute on function public.delete_price_unlock_request(uuid) to authenticated;

commit;
