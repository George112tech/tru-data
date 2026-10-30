-- Agents no longer earn profit on their own purchases.
--
-- An agent buying through their own referral link paid base cost + markup and
-- then earned the markup back as withdrawable profit, i.e. bought at cost.
-- Now place_order() ignores an agent's own code (normal price, no profit), and
-- get_agent_link_prices() shows them normal prices on their own link.
-- Past self-referral profit (GHS 4 across 6 orders, none withdrawn) is zeroed.
--
-- Run AFTER 20261030160000_signup_fixes.sql.

begin;

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
    -- An agent buying through their own link pays the normal price and
    -- earns no profit (otherwise they buy at cost and withdraw the markup).
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
$$;

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
  where a.agent_id = p_agent_code and a.status = 'active'
    and a.user_id is distinct from auth.uid();
$$;

update public.orders o
set agent_profit = 0
from public.agent_profiles a
where a.id = o.agent_id and o.user_id = a.user_id and coalesce(o.agent_profit, 0) <> 0;

commit;
