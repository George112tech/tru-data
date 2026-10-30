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

begin;

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

commit;
