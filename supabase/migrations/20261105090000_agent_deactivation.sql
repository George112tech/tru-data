-- Deactivating agent accounts, with a 7-day notice.
--
-- The admin presses one button (Admin -> Agents). That:
--   1. texts every active agent that agent accounts close in 7 days and that
--      they should withdraw their profit before then;
--   2. opens withdrawals every day, at any hour, for any amount (no GHS 10
--      minimum) until the closing time. The 1% fee still applies.
-- When the 7 days are up, agent accounts are off everywhere:
--   - no agent dashboard and no "become an agent" page on the site;
--   - agent links stop working; customers who open one pay normal prices and
--     no agent profit is recorded;
--   - agents can no longer request withdrawals or change prices, and nobody
--     can apply to become an agent.
-- Withdrawal requests made before the closing time stay in Admin ->
-- Withdrawals for the admin to pay. Nothing is deleted: the admin can cancel
-- during the 7 days, or turn agent accounts back on later.
--
-- The state is one row in app_settings, key 'agent_shutdown':
--   {"notice_at": "...", "closes_at": "...", "sent": 3}
-- No row means agent accounts are on. The time decides the rest, so the
-- switch-off needs no scheduled job.

begin;

-- 'active' | 'closing' (notice sent, closing time not reached) | 'closed'
create or replace function public.agents_phase()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when v is null or jsonb_typeof(v) <> 'object' or v ->> 'closes_at' is null then 'active'
    when (v ->> 'closes_at')::timestamptz > now() then 'closing'
    else 'closed'
  end
  from (select (select value from public.app_settings where key = 'agent_shutdown') as v) s;
$$;
grant execute on function public.agents_phase() to anon, authenticated;

-- The setting can only hold a valid closing time.
create or replace function public.check_app_setting()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
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
  if new.key = 'agent_shutdown' then
    if jsonb_typeof(new.value) <> 'object' or new.value ->> 'closes_at' is null then
      raise exception 'agent_shutdown needs a closing time';
    end if;
    perform (new.value ->> 'closes_at')::timestamptz;
  end if;
  return new;
end;
$function$;

-- Start the 7 days and text every active agent. With p_resend, text them
-- again with the same closing time.
create or replace function public.admin_start_agent_shutdown(p_resend boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, private
as $$
declare
  v_phase  text := public.agents_phase();
  v_closes timestamptz;
  v_msg    text;
  v_to     text;
  v_seen   text[] := '{}';
  v_n      integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if v_phase = 'closed' then
    raise exception 'Agent accounts are already deactivated';
  end if;
  if v_phase = 'closing' and not coalesce(p_resend, false) then
    raise exception 'The reminder was already sent. Agent accounts close on %',
      to_char((select (value ->> 'closes_at')::timestamptz from public.app_settings where key = 'agent_shutdown')
              at time zone 'Africa/Accra', 'FMDD Mon YYYY, FMHH12:MI AM');
  end if;
  if v_phase = 'active' and coalesce(p_resend, false) then
    raise exception 'Send the first reminder before sending it again';
  end if;
  if not exists (select 1 from private.sms_settings where id and api_key is not null and from_number is not null) then
    raise exception 'Set up SMS first (Admin → SMS: API key and sending phone)';
  end if;

  if v_phase = 'active' then
    v_closes := date_trunc('minute', now()) + interval '7 days';
  else
    select (value ->> 'closes_at')::timestamptz into v_closes from public.app_settings where key = 'agent_shutdown';
  end if;

  v_msg := 'TRU Data: Agent accounts close on '
        || to_char(v_closes at time zone 'Africa/Accra', 'FMDD Mon YYYY "at" FMHH12:MI AM')
        || '. Please withdraw all your agent profit before then. Withdrawals are open daily, any amount.';

  for v_to in
    select coalesce(public.sms_normalize_phone(a.phone), public.sms_normalize_phone(p.phone))
      from public.agent_profiles a
      left join public.profiles p on p.id = a.user_id
     where a.status = 'active'
  loop
    if v_to is not null and not (v_to = any (v_seen)) then
      insert into public.sms_outbox (event, to_phone, content) values ('agent_deactivation', v_to, v_msg);
      v_seen := v_seen || v_to;
      v_n := v_n + 1;
    end if;
  end loop;

  if v_phase = 'active' then
    insert into public.app_settings (key, value, updated_at)
    values ('agent_shutdown', jsonb_build_object('notice_at', now(), 'closes_at', v_closes, 'sent', v_n), now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  else
    update public.app_settings
       set value = value || jsonb_build_object('resent_at', now(), 'sent', v_n), updated_at = now()
     where key = 'agent_shutdown';
  end if;

  return jsonb_build_object('closes_at', v_closes, 'sent', v_n, 'message', v_msg);
end;
$$;

-- Cancel during the 7 days, or turn agent accounts back on afterwards.
create or replace function public.admin_cancel_agent_shutdown()
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  delete from public.app_settings where key = 'agent_shutdown';
end;
$$;

revoke execute on function public.admin_start_agent_shutdown(boolean) from public, anon;
grant execute on function public.admin_start_agent_shutdown(boolean) to authenticated;
revoke execute on function public.admin_cancel_agent_shutdown() from public, anon;
grant execute on function public.admin_cancel_agent_shutdown() to authenticated;

-- Withdrawals: open every day for any amount during the 7 days; closed after.
create or replace function public.request_agent_withdrawal(p_amount numeric, p_phone text, p_network text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_agent     public.agent_profiles%rowtype;
  v_available numeric;
  v_fee       numeric;
  v_net       numeric;
  v_phase     text := public.agents_phase();
begin
  if v_phase = 'closed' then
    raise exception 'Agent accounts have been deactivated, so withdrawals are closed';
  end if;
  select * into v_agent from public.agent_profiles
  where user_id = auth.uid() and status = 'active'
  for update;
  if not found then
    raise exception 'Only approved agents can request withdrawals';
  end if;
  if v_phase = 'closing' then
    if p_amount is null or p_amount <= 0 then
      raise exception 'Enter the amount to withdraw';
    end if;
  else
    if not (
      coalesce((select value = 'true'::jsonb from public.app_settings where key = 'withdrawal_override'), false)
      or (extract(isodow from now() at time zone 'Africa/Accra') between 1 and 4
          and extract(hour from now() at time zone 'Africa/Accra') between 8 and 11)
    ) then
      raise exception 'Withdrawal window is closed. Available Monday to Thursday, 8AM-12PM.';
    end if;
    if p_amount is null or p_amount < 10 then
      raise exception 'Minimum withdrawal is GHS 10';
    end if;
  end if;
  if coalesce(p_phone, '') !~ '^0[0-9]{9}$' then
    raise exception 'Enter a valid 10-digit MoMo number';
  end if;
  if coalesce(p_network, '') = '' or length(p_network) > 30 then
    raise exception 'Choose a MoMo network';
  end if;
  v_available := public.agent_available_profit(v_agent.id);
  if p_amount > v_available then
    raise exception 'Insufficient balance. Available profit is GHS %', to_char(greatest(v_available, 0), 'FM999990.00');
  end if;
  v_fee := round(p_amount * 0.01, 2);
  v_net := p_amount - v_fee;
  insert into public.agent_withdrawals
    (agent_id, user_id, requested_amount, amount, fee, net_amount, phone, network, status, created_at)
  values
    (coalesce(v_agent.agent_id, v_agent.id::text), auth.uid(), p_amount, v_net, v_fee, v_net,
     p_phone, p_network, 'pending', now());
  return jsonb_build_object('amount', p_amount, 'fee', v_fee, 'net', v_net,
                            'available', v_available - p_amount);
end;
$function$;

-- After closing, agent links show normal prices and earn no profit.
create or replace function public.get_agent_link_prices(p_agent_code text)
returns table(bundle_id text, price numeric)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select b.id, abp.base_price + coalesce(ap.profit, 0)
  from public.agent_profiles a
  join public.bundles b on b.active
  join lateral (
    select x.* from public.agent_base_prices x
    where x.status = 'active' and x.network = b.network
      and (x.bundle_id = b.id or x.bundle_name = b.size)
    order by (x.bundle_id = b.id) desc
    limit 1
  ) abp on true
  left join public.agent_prices ap
    on ap.agent_id = a.id and ap.bundle_id = abp.id and ap.status = 'approved'
  where a.agent_id = p_agent_code and a.status = 'active'
    and a.user_id is distinct from auth.uid()
    and public.agents_phase() <> 'closed';
$function$;

create or replace function public.place_order(p_bundle_id text, p_phone text, p_agent_code text default null::text, p_request_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_bundle    public.bundles%rowtype;
  v_agent     public.agent_profiles%rowtype;
  v_base      public.agent_base_prices%rowtype;
  v_price     numeric;
  v_profit    numeric := 0;
  v_mode      text := 'system';
  v_agent_id  uuid;
  v_balance   numeric;
  v_existing  public.orders%rowtype;
  v_ref       text;
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
                                'new_balance', v_balance, 'duplicate', true);
    end if;
  end if;
  if coalesce(p_phone, '') !~ '^0(24|54|55|59|25|53|63|77|57|20|50|26|56|27|76|23|28|58)[0-9]{7}$' then
    raise exception 'Enter a valid 10-digit Ghana phone number';
  end if;
  select * into v_bundle from public.bundles where id = p_bundle_id and active;
  if not found then
    raise exception 'Bundle not found';
  end if;
  v_price := v_bundle.price;
  if nullif(p_agent_code, '') is not null and public.agents_phase() <> 'closed' then
    select * into v_agent from public.agent_profiles
    where agent_id = p_agent_code and status = 'active' and user_id is distinct from v_uid;
    if found then
      select * into v_base from public.agent_base_prices
      where status = 'active' and network = v_bundle.network
        and (bundle_id = v_bundle.id or bundle_name = v_bundle.size)
      order by (bundle_id = v_bundle.id) desc
      limit 1;
      if found then
        select coalesce(profit, 0) into v_profit from public.agent_prices
        where agent_id = v_agent.id and bundle_id = v_base.id and status = 'approved';
        v_profit   := coalesce(v_profit, 0);
        v_price    := v_base.base_price + v_profit;
        v_mode     := 'agent';
        v_agent_id := v_agent.id;
      end if;
    end if;
  end if;
  if v_balance < v_price then
    raise exception 'Insufficient balance. Please deposit funds.';
  end if;
  v_ref := 'ORD-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));
  update public.profiles set balance = balance - v_price, updated_at = now() where id = v_uid;
  insert into public.transactions (user_id, type, amount, reference, status, created_at)
  values (v_uid, 'purchase', v_price, v_ref, 'completed', now());
  insert into public.orders (
    ref, "Phone", "Network", bundle_name, "Amount", "Status", provider, user_id,
    pricing_mode, agent_id, agent_code, agent_profit, base_price_used,
    api_status, retry_count, processed_by_api, client_request_id, created_at, updated_at
  ) values (
    v_ref, p_phone, v_bundle.network, v_bundle.size, v_price, 'Pending', 'patupaa', v_uid,
    v_mode, v_agent_id, case when v_agent_id is null then null else p_agent_code end,
    v_profit, v_bundle.price, 'pending', 0, false, p_request_id, now(), now()
  );
  return jsonb_build_object('ref', v_ref, 'amount', v_price,
                            'new_balance', v_balance - v_price, 'duplicate', false);
end;
$function$;

-- No new applications once the notice is out; no price changes once closed.
create or replace function public.guard_agents_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phase text;
begin
  if public.is_admin() then
    return new;
  end if;
  v_phase := public.agents_phase();
  if tg_table_name = 'agent_profiles' then
    if v_phase <> 'active' and new.status = 'pending'
       and (tg_op = 'INSERT' or old.status is distinct from 'pending') then
      raise exception 'We are no longer accepting agent applications';
    end if;
  elsif v_phase = 'closed' then
    raise exception 'Agent accounts have been deactivated';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_agents_open on public.agent_profiles;
create trigger guard_agents_open
  before insert or update on public.agent_profiles
  for each row execute function public.guard_agents_open();
drop trigger if exists guard_agents_open on public.agent_prices;
create trigger guard_agents_open
  before insert or update on public.agent_prices
  for each row execute function public.guard_agents_open();

commit;
