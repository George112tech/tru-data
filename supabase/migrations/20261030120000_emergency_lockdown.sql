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
-- Side effect: the current live frontend can no longer deposit or purchase.
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

create policy "Admins manage agent_profiles" on public.agent_profiles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Agents view own profile" on public.agent_profiles
  for select to authenticated using (user_id = auth.uid());

create policy "Admins manage agent_base_prices" on public.agent_base_prices
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Prices are readable" on public.agent_base_prices
  for select to anon, authenticated using (true);

create policy "Admins manage agent_prices" on public.agent_prices
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Prices are readable" on public.agent_prices
  for select to anon, authenticated using (true);

create policy "Admins manage agent_withdrawals" on public.agent_withdrawals
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Agents view own withdrawals" on public.agent_withdrawals
  for select to authenticated using (user_id = auth.uid());

create policy "Admins manage agent_earnings" on public.agent_earnings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Agents view own earnings" on public.agent_earnings
  for select to authenticated
  using (agent_id in (select id from public.agent_profiles where user_id = auth.uid()));

create policy "Admins manage failed_orders" on public.failed_orders
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

commit;
