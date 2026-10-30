-- Closes data that was readable by anyone holding the public key, even logged
-- out:
--   * agent_profiles: every active agent's account id, name, phone, business,
--     sales, profit and withdrawals
--   * agent_base_prices: the business's cost price for every bundle, admin notes
--   * agent_prices: every agent's markup on every bundle
-- Agent referral links now get only the final prices for one agent code from
-- get_agent_link_prices().
--
-- Also: get_user_role() no longer reveals other users' roles, trigger
-- functions can't be called through the API, and the two remaining trigger
-- functions get a fixed search_path.
--
-- Run AFTER 20261030140000_momo_deposits_and_paystack_toggle.sql.

begin;

-- ---------------------------------------------------------------------------
-- Prices for an agent referral link (?agent=AGT-XXXXXX)
-- ---------------------------------------------------------------------------
-- Same rule as place_order(): agent base cost + that agent's approved markup,
-- for bundles that have an agent base price. Other bundles use the normal
-- price, so they are not returned. An unknown or inactive code returns nothing.

create or replace function public.get_agent_link_prices(p_agent_code text)
returns table (bundle_id text, price numeric)
language sql
stable
security definer
set search_path = public
as $$
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
  where a.agent_id = p_agent_code and a.status = 'active';
$$;

revoke execute on function public.get_agent_link_prices(text) from public;
grant execute on function public.get_agent_link_prices(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Agent tables: admins, and each agent for their own data only
-- ---------------------------------------------------------------------------

drop policy if exists "Active agents are visible" on public.agent_profiles;

drop policy if exists "Prices are readable" on public.agent_base_prices;
drop policy if exists "Active agents read base prices" on public.agent_base_prices;
create policy "Active agents read base prices" on public.agent_base_prices
  for select to authenticated
  using (exists (select 1 from public.agent_profiles a where a.user_id = auth.uid() and a.status = 'active'));

drop policy if exists "Prices are readable" on public.agent_prices;
drop policy if exists "Agents read own markups" on public.agent_prices;
create policy "Agents read own markups" on public.agent_prices
  for select to authenticated
  using (agent_id in (select id from public.agent_profiles where user_id = auth.uid()));

revoke all on public.agent_profiles, public.agent_base_prices, public.agent_prices,
              public.agent_withdrawals, public.agent_earnings, public.failed_orders
  from anon;

-- ---------------------------------------------------------------------------
-- get_user_role(): only your own role (admins may look up anyone). The order
-- policies only ever pass auth.uid(), so they behave exactly as before.
-- ---------------------------------------------------------------------------

create or replace function public.get_user_role(user_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  user_role text;
begin
  if user_id is distinct from auth.uid()
     and not exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin') then
    return 'user';
  end if;
  select role into user_role from public.profiles where id = user_id;
  return coalesce(user_role, 'user');
end;
$$;

-- ---------------------------------------------------------------------------
-- Trigger functions are not API endpoints
-- ---------------------------------------------------------------------------

alter function public.update_agent_total_sales() set search_path = public;
alter function public.update_updated_at_column() set search_path = public;

revoke execute on function public.guard_agent_profile_update() from public, anon, authenticated;
revoke execute on function public.guard_agent_price() from public, anon, authenticated;
revoke execute on function public.sync_agent_price_locks() from public, anon, authenticated;
revoke execute on function public.sync_agent_final_prices() from public, anon, authenticated;
revoke execute on function public.update_agent_total_withdrawn() from public, anon, authenticated;
revoke execute on function public.update_agent_total_sales() from public, anon, authenticated;
revoke execute on function public.update_updated_at_column() from public, anon, authenticated;
revoke execute on function public.set_deposit_code() from public, anon, authenticated;

commit;
