-- TRU Data: run this whole file once in Supabase -> SQL Editor -> Run.
-- It contains the 3 migrations in order. If any step fails, nothing is changed.

begin;

-- ===== 20261030120000_emergency_lockdown.sql =====
-- EMERGENCY LOCKDOWN (applied to production 2026-10-30)
--
-- Closes actively exploited holes in the live database:
--   * profiles had RLS disabled: anyone with the public anon key could set any
--     wallet balance or make themselves admin.
--   * process_deposit / process_purchase / place_order were callable by anyone
--     (even logged out) and trusted caller-supplied user ids and amounts.
--   * users could insert their own transactions and orders, and update their
--     own orders.
--   * six agent tables had RLS disabled; any signed-in user could edit
--     announcements.
--
-- Side effect: the current live frontend can no longer deposit or purchase
-- (agent applications, markups and withdrawal requests keep working).
-- That stays paused until the server-side flow (place_order(text,text) +
-- verify-deposit Edge Function) and the fixed index.html are deployed.


-- ---- Admin helper: pin search_path, never callable logged-out -------------
alter function public.is_admin() set search_path = public;
alter function public.get_user_role(uuid) set search_path = public;
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.get_user_role(uuid) from public, anon;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.get_user_role(uuid) to authenticated;

-- ---- Money-moving functions: nobody but the service role -------------------
revoke execute on function public.process_deposit(uuid, numeric, numeric, text) from public, anon, authenticated;
revoke execute on function public.process_purchase(uuid, text, text, text, numeric, text) from public, anon, authenticated;
revoke execute on function public.place_order(text, text, text, text, numeric, uuid) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.process_deposit(uuid, numeric, numeric, text) to service_role;
grant execute on function public.process_purchase(uuid, text, text, text, numeric, text) to service_role;
grant execute on function public.place_order(text, text, text, text, numeric, uuid) to service_role;
alter function public.process_deposit(uuid, numeric, numeric, text) set search_path = public;
alter function public.process_purchase(uuid, text, text, text, numeric, text) set search_path = public;
alter function public.place_order(text, text, text, text, numeric, uuid) set search_path = public;
alter function public.handle_new_user() set search_path = public;
alter function public.get_admin_stats() set search_path = public;
alter function public.get_orders() set search_path = public;
revoke execute on function public.get_admin_stats() from public, anon;
revoke execute on function public.get_orders() from public, anon;
grant execute on function public.get_admin_stats() to authenticated;
grant execute on function public.get_orders() to authenticated;

-- ---- profiles ---------------------------------------------------------------
alter table public.profiles enable row level security;
drop policy if exists "Users can insert own profile" on public.profiles;  -- on_auth_user_created trigger creates profiles
create policy "Admins can view all profiles" on public.profiles
  for select to authenticated using (public.is_admin());
revoke all on public.profiles from anon;
revoke insert, update, delete on public.profiles from authenticated;
grant update (full_name, phone) on public.profiles to authenticated;

-- ---- transactions -----------------------------------------------------------
drop policy if exists "Users can insert own transactions" on public.transactions;
create policy "Admins can view all transactions" on public.transactions
  for select to authenticated using (public.is_admin());
revoke all on public.transactions from anon;
revoke insert, update, delete on public.transactions from authenticated;

-- ---- orders -----------------------------------------------------------------
drop policy if exists "Allow authenticated users to create orders" on public.orders;
drop policy if exists "Enable insert for authenticated users only" on public.orders;
drop policy if exists "Enable update for users and admins" on public.orders;
revoke all on public.orders from anon;
revoke insert on public.orders from authenticated;

-- ---- announcements: admins write, everyone reads ---------------------------
drop policy if exists "Authenticated users can delete announcements" on public.announcements;
drop policy if exists "Authenticated users can insert announcements" on public.announcements;
drop policy if exists "Authenticated users can update announcements" on public.announcements;
create policy "Admins manage announcements" on public.announcements
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---- agent tables: were fully open ------------------------------------------
alter table public.agent_profiles    enable row level security;
alter table public.agent_base_prices enable row level security;
alter table public.agent_prices      enable row level security;
alter table public.agent_withdrawals enable row level security;
alter table public.agent_earnings    enable row level security;
alter table public.failed_orders     enable row level security;

-- Agents: admins manage everything; agents can apply, edit their own
-- application, set markups and request withdrawals, nothing more.
create policy "Admins manage agent_profiles" on public.agent_profiles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Agents view own profile" on public.agent_profiles
  for select to authenticated using (user_id = auth.uid());
-- The customer-facing agent link (?agent=AGT-xxx) looks up active agents.
create policy "Active agents are visible" on public.agent_profiles
  for select to anon, authenticated using (status = 'active');
create policy "Users apply as agent" on public.agent_profiles
  for insert to authenticated
  with check (
    user_id = auth.uid() and status = 'pending'
    and coalesce(total_sales, 0) = 0 and coalesce(agent_profit, 0) = 0
    and coalesce(total_withdrawn, 0) = 0
    and coalesce(can_edit_prices, false) = false
    and coalesce(pricing_locked, false) = false
  );
create policy "Agents edit own application" on public.agent_profiles
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Non-admin clients may only change their contact details and re-submit
-- (status -> pending). Totals, approval and pricing flags are server-only.
-- SECURITY DEFINER callers (current_user = owner) and admins pass through.
create or replace function public.guard_agent_profile_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.is_admin() then
    return new;
  end if;
  if new.user_id         is distinct from old.user_id
  or new.agent_id        is distinct from old.agent_id
  or new.agent_code      is distinct from old.agent_code
  or new.total_sales     is distinct from old.total_sales
  or new.agent_profit    is distinct from old.agent_profit
  or new.total_withdrawn is distinct from old.total_withdrawn
  or new.can_edit_prices is distinct from old.can_edit_prices
  or new.pricing_locked  is distinct from old.pricing_locked
  or (new.status is distinct from old.status and new.status <> 'pending') then
    raise exception 'Only an admin can change these agent fields';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_agent_profile_update on public.agent_profiles;
create trigger guard_agent_profile_update
  before update on public.agent_profiles
  for each row execute function public.guard_agent_profile_update();

create policy "Admins manage agent_base_prices" on public.agent_base_prices
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Prices are readable" on public.agent_base_prices
  for select to anon, authenticated using (true);

create policy "Admins manage agent_prices" on public.agent_prices
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Prices are readable" on public.agent_prices
  for select to anon, authenticated using (true);
create policy "Active agents set own markup" on public.agent_prices
  for insert to authenticated
  with check (agent_id in (select id from public.agent_profiles where user_id = auth.uid() and status = 'active'));
create policy "Active agents update own markup" on public.agent_prices
  for update to authenticated
  using (agent_id in (select id from public.agent_profiles where user_id = auth.uid() and status = 'active'))
  with check (agent_id in (select id from public.agent_profiles where user_id = auth.uid() and status = 'active'));

create policy "Admins manage agent_withdrawals" on public.agent_withdrawals
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Agents view own withdrawals" on public.agent_withdrawals
  for select to authenticated using (user_id = auth.uid());
create policy "Active agents request withdrawals" on public.agent_withdrawals
  for insert to authenticated
  with check (
    user_id = auth.uid() and status = 'pending' and processed_at is null
    and exists (
      select 1 from public.agent_profiles a
      where a.user_id = auth.uid() and a.status = 'active'
        and agent_withdrawals.agent_id in (a.agent_id, a.id::text)
    )
  );

create policy "Admins manage agent_earnings" on public.agent_earnings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Agents view own earnings" on public.agent_earnings
  for select to authenticated
  using (agent_id in (select id from public.agent_profiles where user_id = auth.uid()));

create policy "Admins manage failed_orders" on public.failed_orders
  for all to authenticated using (public.is_admin()) with check (public.is_admin());


-- ===== 20261030130000_server_side_checkout.sql =====
-- Server-side checkout, deposits, agent pricing and withdrawals.
--
-- Run AFTER 20261030120000_emergency_lockdown.sql. Every money-moving step now
-- happens inside the database; the browser only asks.
--
-- Also fixes:
--   * agent_withdrawals trigger compared uuid = text and failed on every insert
--   * paid withdrawals were counted twice (trigger + browser)
--   * one agent saving a price locked that bundle for every agent
--   * MoMo / agent phone numbers stored as numbers lost their leading 0
--   * deleting an order never refunded the customer


-- ---------------------------------------------------------------------------
-- Price list the server trusts (mirrors NORMAL_BUNDLES in index.html)
-- ---------------------------------------------------------------------------

create table if not exists public.bundles (
  id      text primary key,
  network text not null check (network in ('mtn', 'airteltigo', 'telecel')),
  size    text not null,
  price   numeric(10, 2) not null check (price > 0),
  active  boolean not null default true
);

insert into public.bundles (id, network, size, price) values
  ('m-1','mtn','1GB',5.40),('m-2','mtn','2GB',10.00),('m-3','mtn','3GB',15.00),('m-4','mtn','4GB',19.50),
  ('m-5','mtn','5GB',24.50),('m-6','mtn','6GB',28.50),('m-7','mtn','7GB',33.00),('m-8','mtn','8GB',37.50),
  ('m-10','mtn','10GB',45.80),('m-12','mtn','12GB',56.80),('m-15','mtn','15GB',66.50),('m-20','mtn','20GB',83.00),
  ('m-25','mtn','25GB',102.90),('m-30','mtn','30GB',125.00),('m-40','mtn','40GB',165.50),('m-50','mtn','50GB',196.90),
  ('m-100','mtn','100GB',390.90),
  ('a-1','airteltigo','1GB',6.50),('a-2','airteltigo','2GB',11.00),('a-3','airteltigo','3GB',15.50),('a-4','airteltigo','4GB',20.50),
  ('a-5','airteltigo','5GB',23.50),('a-6','airteltigo','6GB',27.00),('a-7','airteltigo','7GB',32.00),('a-8','airteltigo','8GB',34.50),
  ('a-10','airteltigo','10GB',42.50),('a-15','airteltigo','15GB',64.00),('a-20','airteltigo','20GB',82.00),('a-25','airteltigo','25GB',99.90),
  ('a-30','airteltigo','30GB',119.70),('a-40','airteltigo','40GB',163.50),('a-50','airteltigo','50GB',199.90),
  ('t-10','telecel','10GB',42.00),('t-15','telecel','15GB',61.00),('t-20','telecel','20GB',79.00),('t-25','telecel','25GB',99.00),
  ('t-30','telecel','30GB',118.00),('t-40','telecel','40GB',151.00),('t-50','telecel','50GB',187.00),('t-100','telecel','100GB',380.00)
on conflict (id) do update
  set network = excluded.network, size = excluded.size, price = excluded.price;

alter table public.bundles enable row level security;
drop policy if exists "Bundles are readable" on public.bundles;
create policy "Bundles are readable" on public.bundles for select to anon, authenticated using (active);
drop policy if exists "Admins manage bundles" on public.bundles;
create policy "Admins manage bundles" on public.bundles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.bundles from anon, authenticated;
grant select on public.bundles to anon, authenticated;
grant insert, update, delete on public.bundles to authenticated;

-- One order per tap: the browser sends a fresh request id per purchase attempt.
alter table public.orders add column if not exists client_request_id uuid;
create unique index if not exists orders_client_request_id_key on public.orders (client_request_id);

-- Phone numbers are text, not numbers (0241234567 was being saved as 241234567).
alter table public.agent_withdrawals alter column phone type text
  using case when phone is null then null else lpad(phone::bigint::text, 10, '0') end;
alter table public.agent_profiles alter column phone type text
  using case when phone is null then null else lpad(phone::bigint::text, 10, '0') end;

-- Legacy functions that trusted caller-supplied user ids and amounts.
drop function if exists public.place_order(text, text, text, text, numeric, uuid);
drop function if exists public.process_purchase(uuid, text, text, text, numeric, text);
drop function if exists public.process_deposit(uuid, numeric, numeric, text);

-- Agents pick their own AGT- code when applying, and it ends up in referral
-- links and filters, so pin its format.
alter table public.agent_profiles drop constraint if exists agent_profiles_agent_id_format;
alter table public.agent_profiles add constraint agent_profiles_agent_id_format
  check (agent_id is null or agent_id ~ '^AGT-[A-Z0-9]{4,12}$');

-- ---------------------------------------------------------------------------
-- place_order: price, balance, debit, transaction and order in one step
-- ---------------------------------------------------------------------------

create or replace function public.place_order(
  p_bundle_id  text,
  p_phone      text,
  p_agent_code text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  -- Locking the wallet first serialises every purchase by this customer,
  -- so a double tap waits here and then finds the first order below.
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

  -- Agent link pricing: agent base cost + that agent's approved markup.
  if nullif(p_agent_code, '') is not null then
    select * into v_agent from public.agent_profiles
    where agent_id = p_agent_code and status = 'active';
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
$$;

revoke execute on function public.place_order(text, text, text, uuid) from public, anon;
grant execute on function public.place_order(text, text, text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- credit_deposit: only the verify-deposit Edge Function (service role) calls
-- this, after Paystack confirms the payment. A reference credits once.
-- ---------------------------------------------------------------------------

create or replace function public.credit_deposit(
  p_user uuid, p_reference text, p_net numeric, p_fee numeric
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.transactions (user_id, type, amount, fee, reference, status, created_at)
  values (p_user, 'deposit', p_net, p_fee, p_reference, 'completed', now())
  on conflict (reference) do nothing;

  if not found then
    return false;
  end if;

  update public.profiles set balance = coalesce(balance, 0) + p_net, updated_at = now()
  where id = p_user;
  return true;
end;
$$;

revoke execute on function public.credit_deposit(uuid, text, numeric, numeric) from public, anon, authenticated;
grant execute on function public.credit_deposit(uuid, text, numeric, numeric) to service_role;

-- ---------------------------------------------------------------------------
-- cancel_order: admin cancels an order; refunds the wallet unless delivered
-- ---------------------------------------------------------------------------

create or replace function public.cancel_order(p_ref text, p_refund boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order    public.orders%rowtype;
  v_refunded boolean := false;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;

  select * into v_order from public.orders where ref = p_ref for update;
  if not found then
    raise exception 'Order not found';
  end if;
  if v_order."Status" = 'Deleted' then
    return jsonb_build_object('refunded', false, 'already_cancelled', true);
  end if;

  if p_refund and v_order.user_id is not null and coalesce(v_order."Amount", 0) > 0 then
    insert into public.transactions (user_id, type, amount, reference, status, created_at)
    values (v_order.user_id, 'refund', v_order."Amount", 'RFD-' || v_order.ref, 'completed', now())
    on conflict (reference) do nothing;
    if found then
      update public.profiles set balance = coalesce(balance, 0) + v_order."Amount", updated_at = now()
      where id = v_order.user_id;
      v_refunded := true;
    end if;
  end if;

  update public.orders set "Status" = 'Deleted', updated_at = now() where ref = p_ref;
  return jsonb_build_object('refunded', v_refunded, 'amount', v_order."Amount");
end;
$$;

revoke execute on function public.cancel_order(text, boolean) from public, anon;
grant execute on function public.cancel_order(text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Agent withdrawals
-- ---------------------------------------------------------------------------

-- Was: WHERE id = NEW.agent_id (uuid = text) -> error on every insert/update.
-- agent_withdrawals.agent_id holds either the AGT- code or the profile uuid.
create or replace function public.update_agent_total_withdrawn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.agent_profiles ap
  set total_withdrawn = (
    select coalesce(sum(coalesce(w.requested_amount, w.amount)), 0)
    from public.agent_withdrawals w
    where w.status = 'paid' and w.agent_id in (ap.agent_id, ap.id::text)
  )
  where new.agent_id in (ap.agent_id, ap.id::text);
  return new;
end;
$$;

create or replace function public.agent_available_profit(p_agent_profile_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select sum(coalesce(o.agent_profit, 0)) from public.orders o
                   where o.agent_id = ap.id and coalesce(o."Status", 'Pending') <> 'Deleted'), 0)
       - coalesce((select sum(coalesce(w.requested_amount, w.amount)) from public.agent_withdrawals w
                   where w.agent_id in (ap.agent_id, ap.id::text)
                     and coalesce(w.status, 'pending') in ('pending', 'approved', 'paid')), 0)
  from public.agent_profiles ap
  where ap.id = p_agent_profile_id;
$$;

revoke execute on function public.agent_available_profit(uuid) from public, anon, authenticated;

create or replace function public.request_agent_withdrawal(p_amount numeric, p_phone text, p_network text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent     public.agent_profiles%rowtype;
  v_available numeric;
  v_fee       numeric;
  v_net       numeric;
begin
  select * into v_agent from public.agent_profiles
  where user_id = auth.uid() and status = 'active'
  for update;
  if not found then
    raise exception 'Only approved agents can request withdrawals';
  end if;

  -- Same window the page shows: Monday-Thursday 8AM-12PM Ghana time, unless
  -- the admin has opened it.
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
$$;

revoke execute on function public.request_agent_withdrawal(numeric, text, text) from public, anon;
grant execute on function public.request_agent_withdrawal(numeric, text, text) to authenticated;

-- Withdrawals now only go through request_agent_withdrawal.
drop policy if exists "Active agents request withdrawals" on public.agent_withdrawals;

-- ---------------------------------------------------------------------------
-- Agent price locks are per agent, not per bundle
-- ---------------------------------------------------------------------------
-- Before: an agent saving a markup set agent_base_prices.pricing_locked, which
-- locked that bundle for every agent. Now agent_prices.locked is the agent's
-- own lock, and agent_base_prices.pricing_locked means "admin froze this".

alter table public.agent_prices add column if not exists locked boolean not null default false;
update public.agent_prices ap set locked = true
from public.agent_base_prices b
where b.id = ap.bundle_id and b.pricing_locked;
update public.agent_base_prices set pricing_locked = false where pricing_locked;

create or replace function public.guard_agent_price()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_base public.agent_base_prices%rowtype;
begin
  select * into v_base from public.agent_base_prices where id = new.bundle_id and status = 'active';
  if not found then
    raise exception 'Unknown bundle';
  end if;

  if current_user in ('anon', 'authenticated') and not public.is_admin() then
    if tg_op = 'UPDATE' then
      if old.locked then
        raise exception 'This price is locked. Contact admin to change it.';
      end if;
      new.agent_id := old.agent_id;
      new.bundle_id := old.bundle_id;
    end if;
    if v_base.pricing_locked then
      raise exception 'Admin has locked this bundle. Contact admin to change it.';
    end if;
    if new.profit is null or new.profit < 0 or new.profit > v_base.base_price then
      raise exception 'Profit must be between 0 and the base price';
    end if;
    new.locked := true;
    new.status := 'approved';
  end if;

  new.network := v_base.network;
  new.bundle_name := v_base.bundle_name;
  new.final_price := v_base.base_price + coalesce(new.profit, 0);
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists guard_agent_price on public.agent_prices;
create trigger guard_agent_price
  before insert or update on public.agent_prices
  for each row execute function public.guard_agent_price();

-- Admin lock/unlock flows down to every agent's row. It fires whenever the
-- admin sets pricing_locked, even to its current value: after this migration
-- the bundle flag starts unlocked while agents' own rows may still be locked,
-- and clicking "unlock" must still release them.
create or replace function public.sync_agent_price_locks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.agent_prices set locked = coalesce(new.pricing_locked, false) where bundle_id = new.id;
  return new;
end;
$$;

drop trigger if exists sync_agent_price_locks on public.agent_base_prices;
create trigger sync_agent_price_locks
  after update of pricing_locked on public.agent_base_prices
  for each row execute function public.sync_agent_price_locks();

create or replace function public.sync_agent_final_prices()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.base_price is distinct from old.base_price then
    update public.agent_prices set final_price = new.base_price + coalesce(profit, 0) where bundle_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_agent_final_prices on public.agent_base_prices;
create trigger sync_agent_final_prices
  after update of base_price on public.agent_base_prices
  for each row execute function public.sync_agent_final_prices();

-- ---------------------------------------------------------------------------
-- Shared settings (the admin's withdrawal-window override used to live only
-- in the admin's own browser, so agents never saw it)
-- ---------------------------------------------------------------------------

create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
insert into public.app_settings (key, value) values ('withdrawal_override', 'false')
on conflict (key) do nothing;

alter table public.app_settings enable row level security;
drop policy if exists "Settings are readable" on public.app_settings;
create policy "Settings are readable" on public.app_settings for select to anon, authenticated using (true);
drop policy if exists "Admins manage settings" on public.app_settings;
create policy "Admins manage settings" on public.app_settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.app_settings from anon, authenticated;
grant select on public.app_settings to anon, authenticated;
grant insert, update on public.app_settings to authenticated;


-- ===== 20261030140000_momo_deposits_and_paystack_toggle.sql =====
-- Manual Mobile Money deposits as the main way to fund a wallet, and Paystack
-- as an optional method the admin switches on and off.
--
-- Run AFTER 20261030130000_server_side_checkout.sql.
--
-- Flow: the customer sends MoMo to the business number using their personal
-- deposit code as the reference, then submits "I've sent the money". The
-- admin checks the MoMo statement and approves the request, which credits the
-- wallet. The admin can also credit a wallet directly by deposit code.


-- ---------------------------------------------------------------------------
-- Each customer's permanent MoMo reference, e.g. TRU4F9A2C
-- ---------------------------------------------------------------------------

alter table public.profiles add column if not exists deposit_code text;
update public.profiles
  set deposit_code = 'TRU' || upper(substr(md5(id::text), 1, 6))
  where deposit_code is null;
create unique index if not exists profiles_deposit_code_key on public.profiles (deposit_code);

create or replace function public.set_deposit_code()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.deposit_code is null then
    new.deposit_code := 'TRU' || upper(substr(md5(new.id::text), 1, 6));
  end if;
  return new;
end;
$$;

drop trigger if exists set_deposit_code on public.profiles;
create trigger set_deposit_code
  before insert on public.profiles
  for each row execute function public.set_deposit_code();

-- ---------------------------------------------------------------------------
-- "I've sent the money" requests
-- ---------------------------------------------------------------------------

create table if not exists public.deposit_requests (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  amount          numeric(10, 2) not null check (amount > 0),
  momo_txn_id     text,
  sender_phone    text,
  status          text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  credited_amount numeric(10, 2),
  admin_note      text,
  created_at      timestamptz not null default now(),
  reviewed_at     timestamptz,
  reviewed_by     uuid
);
create index if not exists deposit_requests_status_idx on public.deposit_requests (status, created_at desc);

alter table public.deposit_requests enable row level security;
drop policy if exists "Users view own deposit requests" on public.deposit_requests;
create policy "Users view own deposit requests" on public.deposit_requests
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
revoke all on public.deposit_requests from anon, authenticated;
grant select on public.deposit_requests to authenticated;

create or replace function public.submit_deposit_request(
  p_amount numeric, p_momo_txn_id text default null, p_sender_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_txn text := nullif(upper(trim(coalesce(p_momo_txn_id, ''))), '');
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'Please log in first';
  end if;
  if p_amount is null or p_amount < 5 or p_amount > 10000 then
    raise exception 'Amount must be between GHS 5 and GHS 10,000';
  end if;
  if v_txn is not null and v_txn !~ '^[A-Z0-9.\-]{4,40}$' then
    raise exception 'Enter the MoMo transaction ID exactly as it appears in your SMS';
  end if;
  if nullif(p_sender_phone, '') is not null and p_sender_phone !~ '^0[0-9]{9}$' then
    raise exception 'Enter the 10-digit number you sent from';
  end if;
  if (select count(*) from public.deposit_requests where user_id = v_uid and status = 'pending') >= 5 then
    raise exception 'You already have 5 deposits waiting for review. Please wait for them to be checked.';
  end if;
  if v_txn is not null and exists (
    select 1 from public.deposit_requests where momo_txn_id = v_txn and status <> 'rejected'
  ) then
    raise exception 'This MoMo transaction ID has already been submitted';
  end if;

  insert into public.deposit_requests (user_id, amount, momo_txn_id, sender_phone)
  values (v_uid, round(p_amount, 2), v_txn, nullif(p_sender_phone, ''))
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.submit_deposit_request(numeric, text, text) from public, anon;
grant execute on function public.submit_deposit_request(numeric, text, text) to authenticated;

-- Credits a wallet once per MoMo transaction ID (or once per request when
-- there is no transaction ID). Shared by approve and direct credit.
create or replace function public.credit_momo_deposit(
  p_user uuid, p_amount numeric, p_reference text
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_balance numeric;
begin
  insert into public.transactions (user_id, type, amount, fee, reference, status, created_at)
  values (p_user, 'deposit', p_amount, 0, p_reference, 'completed', now())
  on conflict (reference) do nothing;
  if not found then
    raise exception 'This MoMo transaction has already been credited (%)', p_reference;
  end if;

  update public.profiles set balance = coalesce(balance, 0) + p_amount, updated_at = now()
  where id = p_user
  returning balance into v_balance;
  return v_balance;
end;
$$;

revoke execute on function public.credit_momo_deposit(uuid, numeric, text) from public, anon, authenticated;

create or replace function public.approve_deposit_request(p_id uuid, p_amount numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req     public.deposit_requests%rowtype;
  v_amount  numeric;
  v_balance numeric;
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

  v_balance := public.credit_momo_deposit(
    v_req.user_id, v_amount,
    coalesce('MOMO-' || v_req.momo_txn_id, 'MOMO-REQ-' || v_req.id::text));

  update public.deposit_requests
  set status = 'approved', credited_amount = v_amount, reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id;

  return jsonb_build_object('credited', v_amount, 'new_balance', v_balance);
end;
$$;

revoke execute on function public.approve_deposit_request(uuid, numeric) from public, anon;
grant execute on function public.approve_deposit_request(uuid, numeric) to authenticated;

create or replace function public.reject_deposit_request(p_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update public.deposit_requests
  set status = 'rejected', admin_note = left(p_note, 300), reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;
end;
$$;

revoke execute on function public.reject_deposit_request(uuid, text) from public, anon;
grant execute on function public.reject_deposit_request(uuid, text) to authenticated;

-- Admin credits a wallet directly by deposit code (no request needed).
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
  v_balance numeric;
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

  v_balance := public.credit_momo_deposit(
    v_profile.id, round(p_amount, 2),
    coalesce('MOMO-' || v_txn, 'MOMO-ADMIN-' || gen_random_uuid()::text));

  -- A matching pending request for the same transaction is now settled.
  if v_txn is not null then
    update public.deposit_requests
    set status = 'approved', credited_amount = round(p_amount, 2), reviewed_at = now(), reviewed_by = auth.uid()
    where momo_txn_id = v_txn and status = 'pending';
  end if;

  return jsonb_build_object('name', v_profile.full_name, 'email', v_profile.email,
                            'credited', round(p_amount, 2), 'new_balance', v_balance);
end;
$$;

revoke execute on function public.admin_credit_wallet(text, numeric, text) from public, anon;
grant execute on function public.admin_credit_wallet(text, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Paystack switch and keys
-- ---------------------------------------------------------------------------
-- The switch and public key live in app_settings (readable by everyone, that
-- is what "public" key means). The secret key lives in a private table that
-- no browser role can read; only the verify-deposit Edge Function reads it.

insert into public.app_settings (key, value) values
  ('paystack_enabled', 'false'),
  ('paystack_public_key', to_jsonb('pk_live_ea1b78f7fb20ea947f216c78e6ae3adc32d45f1b'::text))
on conflict (key) do nothing;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.secrets (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
revoke all on private.secrets from public, anon, authenticated;

create or replace function public.set_paystack_secret_key(p_secret text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if coalesce(p_secret, '') !~ '^sk_(live|test)_[A-Za-z0-9]{20,}$' then
    raise exception 'That does not look like a Paystack secret key (sk_live_... or sk_test_...)';
  end if;
  insert into private.secrets (key, value, updated_at) values ('paystack_secret_key', p_secret, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end;
$$;

-- Lets the admin page show "set, ending in ...1234" without revealing the key.
create or replace function public.paystack_secret_key_status()
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare v_row private.secrets%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_row from private.secrets where key = 'paystack_secret_key';
  if not found then
    return jsonb_build_object('set', false);
  end if;
  return jsonb_build_object('set', true, 'last4', right(v_row.value, 4),
                            'mode', case when v_row.value like 'sk_live_%' then 'live' else 'test' end,
                            'updated_at', v_row.updated_at);
end;
$$;

create or replace function public.get_paystack_secret_key()
returns text
language sql
stable
security definer
set search_path = public, private
as $$
  select value from private.secrets where key = 'paystack_secret_key';
$$;

revoke execute on function public.set_paystack_secret_key(text) from public, anon;
grant execute on function public.set_paystack_secret_key(text) to authenticated;
revoke execute on function public.paystack_secret_key_status() from public, anon;
grant execute on function public.paystack_secret_key_status() to authenticated;
revoke execute on function public.get_paystack_secret_key() from public, anon, authenticated;
grant execute on function public.get_paystack_secret_key() to service_role;


commit;
