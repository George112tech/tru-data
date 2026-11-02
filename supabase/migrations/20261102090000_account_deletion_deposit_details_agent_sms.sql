-- 1. Account deletion requests (customers and agents ask; the admin approves).
-- 2. Mobile Money deposit details editable by the admin (app_settings).
-- 3. The admin can text an agent (looked up by agent ID) through httpSMS.
--
-- Run AFTER 20261031120000_manage_bundles.sql.

begin;

-- ---------------------------------------------------------------------------
-- 1. Account deletion
-- ---------------------------------------------------------------------------
-- Approving a request deletes the sign-in account and, with it, the profile
-- (wallet balance, which is not refunded), orders, transactions, deposit
-- requests, the agent profile, agent prices, price-change requests and
-- withdrawals. The one exception: orders the person placed through ANOTHER
-- agent's link keep existing without the person's details (no account, phone
-- number hidden), because that agent's earned profit is counted from them.
-- The request row itself stays as a record that the deletion happened, with
-- only a masked label.

create table if not exists public.account_deletion_requests (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid references auth.users (id) on delete set null,
  label            text,                       -- name / email while pending; masked once deleted
  email            text,
  phone            text,
  agent_code       text,
  reason           text check (reason is null or char_length(reason) <= 300),
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  balance_forfeited numeric(10, 2),
  admin_note       text check (admin_note is null or char_length(admin_note) <= 300),
  created_at       timestamptz not null default now(),
  reviewed_at      timestamptz,
  reviewed_by      uuid
);
create index if not exists account_deletion_requests_status_idx
  on public.account_deletion_requests (status, created_at);

alter table public.account_deletion_requests enable row level security;
drop policy if exists "Own deletion requests" on public.account_deletion_requests;
create policy "Own deletion requests" on public.account_deletion_requests
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
revoke all on public.account_deletion_requests from anon, authenticated;
grant select on public.account_deletion_requests to authenticated;

create or replace function public.request_account_deletion(p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_p   public.profiles%rowtype;
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'Please log in first';
  end if;
  if public.is_admin() then
    raise exception 'The admin account cannot be deleted this way';
  end if;
  if exists (select 1 from public.account_deletion_requests where user_id = v_uid and status = 'pending') then
    raise exception 'You already asked for your account to be deleted. The admin will review it.';
  end if;
  select * into v_p from public.profiles where id = v_uid;
  insert into public.account_deletion_requests (user_id, label, email, phone, agent_code, reason)
  values (v_uid, coalesce(nullif(v_p.full_name, ''), v_p.email), v_p.email, v_p.phone,
          (select agent_id from public.agent_profiles where user_id = v_uid limit 1),
          nullif(left(trim(coalesce(p_reason, '')), 300), ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.cancel_account_deletion()
returns void
language sql
security definer
set search_path = public
as $$
  update public.account_deletion_requests set status = 'cancelled', reviewed_at = now()
  where user_id = auth.uid() and status = 'pending';
$$;

create or replace function public.reject_account_deletion(p_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update public.account_deletion_requests
  set status = 'rejected', admin_note = nullif(left(trim(coalesce(p_note, '')), 300), ''),
      reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;
end;
$$;

create or replace function public.approve_account_deletion(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_req     public.account_deletion_requests%rowtype;
  v_uid     uuid;
  v_agent   public.agent_profiles%rowtype;
  v_balance numeric(10, 2);
  v_kept    integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_req from public.account_deletion_requests where id = p_id for update;
  if not found or v_req.status <> 'pending' then
    raise exception 'Request not found or already reviewed';
  end if;
  v_uid := v_req.user_id;
  if v_uid is null then
    raise exception 'This account no longer exists';
  end if;
  if exists (select 1 from public.profiles where id = v_uid and (role = 'admin' or is_admin)) then
    raise exception 'The admin account cannot be deleted';
  end if;

  select coalesce(balance, 0) into v_balance from public.profiles where id = v_uid;

  -- Orders through another agent's link: keep for that agent, without this person.
  update public.orders o
  set user_id = null,
      "Phone" = case when length(coalesce(o."Phone", '')) >= 7
                     then left(o."Phone", 3) || '****' || right(o."Phone", 3) else '****' end,
      full_name = 'Deleted customer'
  where o.user_id = v_uid
    and o.agent_id is not null
    and o.agent_id not in (select id from public.agent_profiles where user_id = v_uid)
    and coalesce(o.agent_profit, 0) > 0;
  get diagnostics v_kept = row_count;

  -- Agent records (not linked to the sign-in account, so removed here).
  select * into v_agent from public.agent_profiles where user_id = v_uid limit 1;
  if found then
    delete from public.agent_prices where agent_id = v_agent.id;
    delete from public.agent_earnings where agent_id = v_agent.id;
    delete from public.agent_withdrawals
      where user_id = v_uid or agent_id in (v_agent.agent_id, v_agent.id::text);
    delete from public.agent_profiles where id = v_agent.id; -- price-change requests go with it
  end if;
  delete from public.agent_withdrawals where user_id = v_uid;

  -- The sign-in account; the profile, orders, transactions and deposit requests go with it.
  delete from auth.users where id = v_uid;

  update public.account_deletion_requests
  set status = 'approved', balance_forfeited = v_balance,
      label = left(coalesce(v_req.label, ''), 1) || '*** (deleted)',
      email = null, phone = null, reason = null,
      reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id;

  return jsonb_build_object('deleted', true, 'balance_forfeited', v_balance, 'orders_kept_for_agents', v_kept);
end;
$$;

revoke execute on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;
revoke execute on function public.cancel_account_deletion() from public, anon;
grant execute on function public.cancel_account_deletion() to authenticated;
revoke execute on function public.reject_account_deletion(uuid, text) from public, anon;
grant execute on function public.reject_account_deletion(uuid, text) to authenticated;
revoke execute on function public.approve_account_deletion(uuid) from public, anon;
grant execute on function public.approve_account_deletion(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Mobile Money deposit details (shown on every wallet page)
-- ---------------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('momo_number', '"0505175472"'),
  ('momo_name', '"GEORGE DANQUAH DORDZIE"')
on conflict (key) do nothing;

-- Only sensible values can be saved (the admin edits these from the dashboard).
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
  return new;
end;
$$;

drop trigger if exists app_settings_check on public.app_settings;
create trigger app_settings_check
  before insert or update on public.app_settings
  for each row execute function public.check_app_setting();

revoke execute on function public.check_app_setting() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Admin texts an agent
-- ---------------------------------------------------------------------------
-- Phone numbers on an agent's account (agent application and sign-up), for
-- the admin's "Message an agent" box.
create or replace function public.agent_contact(p_agent_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_a public.agent_profiles%rowtype;
  v_p public.profiles%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_a from public.agent_profiles where upper(agent_id) = upper(trim(p_agent_code)) limit 1;
  if not found then
    return null;
  end if;
  select * into v_p from public.profiles where id = v_a.user_id;
  return jsonb_build_object('agent_id', v_a.agent_id, 'name', v_a.name, 'business_name', v_a.business_name,
    'status', v_a.status, 'agent_phone', v_a.phone, 'account_phone', v_p.phone, 'email', v_p.email);
end;
$$;

create or replace function public.admin_send_sms(p_to text[], p_message text)
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_msg text := trim(coalesce(p_message, ''));
  v_n   integer := 0;
  v_to  text;
  v_seen text[] := '{}';
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if char_length(v_msg) < 1 then
    raise exception 'Type a message first';
  end if;
  if char_length(v_msg) > 480 then
    raise exception 'The message is too long (480 characters at most)';
  end if;
  if not exists (select 1 from private.sms_settings where id and api_key is not null and from_number is not null) then
    raise exception 'Set up SMS first (Admin → SMS: API key and sending phone)';
  end if;
  foreach v_to in array coalesce(p_to, '{}') loop
    v_to := public.sms_normalize_phone(v_to);
    if v_to is not null and not (v_to = any (v_seen)) then
      insert into public.sms_outbox (event, to_phone, content) values ('admin_message', v_to, v_msg);
      v_seen := v_seen || v_to;
      v_n := v_n + 1;
    end if;
  end loop;
  if v_n = 0 then
    raise exception 'No valid Ghana phone number to send to';
  end if;
  return v_n;
end;
$$;

revoke execute on function public.agent_contact(text) from public, anon;
grant execute on function public.agent_contact(text) to authenticated;
revoke execute on function public.admin_send_sms(text[], text) from public, anon;
grant execute on function public.admin_send_sms(text[], text) to authenticated;

-- Live updates for deletion requests.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'account_deletion_requests') then
    alter publication supabase_realtime add table public.account_deletion_requests;
  end if;
end;
$$;

commit;
