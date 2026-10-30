-- Agents request a price change; the admin opens pricing for that agent only.
--
-- When an agent's prices are locked they can file a request (with a note).
-- Approving it opens pricing for that one agent for a set number of hours
-- (agent_profiles.price_unlock_until). Other agents stay locked. While the
-- window is open the agent can change any markup, even on bundles the admin
-- froze for everyone; when it closes (or the admin presses "Lock now") every
-- price they saved is locked again.
--
-- Run AFTER 20261030170000_no_self_referral_profit.sql.

begin;

alter table public.agent_profiles add column if not exists price_unlock_until timestamptz;

create table if not exists public.price_unlock_requests (
  id               uuid primary key default gen_random_uuid(),
  agent_profile_id uuid not null references public.agent_profiles (id) on delete cascade,
  note             text check (note is null or char_length(note) <= 300),
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  hours            integer,
  created_at       timestamptz not null default now(),
  reviewed_at      timestamptz,
  reviewed_by      uuid
);
create index if not exists price_unlock_requests_status_idx
  on public.price_unlock_requests (status, created_at);

alter table public.price_unlock_requests enable row level security;
drop policy if exists "Agents view own unlock requests" on public.price_unlock_requests;
create policy "Agents view own unlock requests" on public.price_unlock_requests
  for select to authenticated
  using (public.is_admin()
         or agent_profile_id in (select id from public.agent_profiles where user_id = auth.uid()));
revoke all on public.price_unlock_requests from anon, authenticated;
grant select on public.price_unlock_requests to authenticated;

-- ---------------------------------------------------------------------------
-- Agent: ask for pricing to be opened
-- ---------------------------------------------------------------------------

create or replace function public.request_price_unlock(p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent public.agent_profiles%rowtype;
  v_id    uuid;
begin
  select * into v_agent from public.agent_profiles
  where user_id = auth.uid() and status = 'active'
  for update;
  if not found then
    raise exception 'Only approved agents can request a price change';
  end if;
  if v_agent.price_unlock_until > now() then
    raise exception 'Your pricing is already open';
  end if;
  if exists (select 1 from public.price_unlock_requests
             where agent_profile_id = v_agent.id and status = 'pending') then
    raise exception 'You already have a request waiting for admin approval';
  end if;

  insert into public.price_unlock_requests (agent_profile_id, note)
  values (v_agent.id, nullif(left(trim(coalesce(p_note, '')), 300), ''))
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.request_price_unlock(text) from public, anon;
grant execute on function public.request_price_unlock(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve (open for N hours), reject, or lock an agent again
-- ---------------------------------------------------------------------------

create or replace function public.approve_price_unlock(p_id uuid, p_hours integer default 24)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req   public.price_unlock_requests%rowtype;
  v_until timestamptz;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if p_hours is null or p_hours < 1 or p_hours > 168 then
    raise exception 'Open pricing for between 1 and 168 hours';
  end if;
  select * into v_req from public.price_unlock_requests where id = p_id for update;
  if not found then
    raise exception 'Request not found';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request was already %', v_req.status;
  end if;

  v_until := now() + make_interval(hours => p_hours);
  update public.agent_profiles set price_unlock_until = v_until where id = v_req.agent_profile_id;
  update public.price_unlock_requests
  set status = 'approved', hours = p_hours, reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id;
  return v_until;
end;
$$;

create or replace function public.reject_price_unlock(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update public.price_unlock_requests
  set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;
end;
$$;

create or replace function public.lock_agent_pricing(p_agent_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update public.agent_profiles set price_unlock_until = null where id = p_agent_profile_id;
end;
$$;

revoke execute on function public.approve_price_unlock(uuid, integer) from public, anon;
grant execute on function public.approve_price_unlock(uuid, integer) to authenticated;
revoke execute on function public.reject_price_unlock(uuid) from public, anon;
grant execute on function public.reject_price_unlock(uuid) to authenticated;
revoke execute on function public.lock_agent_pricing(uuid) from public, anon;
grant execute on function public.lock_agent_pricing(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Enforcement
-- ---------------------------------------------------------------------------

-- Agents must not be able to open their own pricing window.
create or replace function public.guard_agent_profile_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.is_admin() then
    return new;
  end if;
  if new.user_id            is distinct from old.user_id
  or new.agent_id           is distinct from old.agent_id
  or new.agent_code         is distinct from old.agent_code
  or new.total_sales        is distinct from old.total_sales
  or new.agent_profit       is distinct from old.agent_profit
  or new.total_withdrawn    is distinct from old.total_withdrawn
  or new.can_edit_prices    is distinct from old.can_edit_prices
  or new.pricing_locked     is distinct from old.pricing_locked
  or new.price_unlock_until is distinct from old.price_unlock_until
  or (new.status is distinct from old.status and new.status <> 'pending') then
    raise exception 'Only an admin can change these agent fields';
  end if;
  return new;
end;
$$;

-- While an agent's window is open, their own locks and the admin's bundle
-- freeze don't apply to them. Saved prices are still marked locked, so they
-- lock again when the window closes.
create or replace function public.guard_agent_price()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_base public.agent_base_prices%rowtype;
  v_open boolean;
begin
  select * into v_base from public.agent_base_prices where id = new.bundle_id and status = 'active';
  if not found then
    raise exception 'Unknown bundle';
  end if;

  if current_user in ('anon', 'authenticated') and not public.is_admin() then
    if tg_op = 'UPDATE' then
      new.agent_id := old.agent_id;
      new.bundle_id := old.bundle_id;
    end if;
    select coalesce(a.price_unlock_until > now(), false) into v_open
    from public.agent_profiles a where a.id = new.agent_id;
    if not coalesce(v_open, false) then
      if tg_op = 'UPDATE' and old.locked then
        raise exception 'This price is locked. Request a price change from your dashboard.';
      end if;
      if v_base.pricing_locked then
        raise exception 'Admin has locked this bundle. Request a price change from your dashboard.';
      end if;
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

revoke execute on function public.guard_agent_profile_update() from public, anon, authenticated;
revoke execute on function public.guard_agent_price() from public, anon, authenticated;

commit;
