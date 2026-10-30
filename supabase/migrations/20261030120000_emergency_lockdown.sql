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

begin;

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

commit;
