-- Agent accounts are gone for good.
--
-- Every agent had withdrawn their profit (all three at GHS 0.00, no
-- withdrawal pending) when the owner asked for the agent system and its data
-- to be removed. This deletes, permanently:
--   - the agent tables: agent_profiles, agent_prices, agent_base_prices,
--     agent_earnings, agent_withdrawals and price_unlock_requests (with their
--     rows, policies and triggers);
--   - every function that only served them (agent pricing, links,
--     withdrawals, price-change requests, the 7-day deactivation, agent SMS);
--   - agent details kept on other tables: orders.agent_id, agent_code and
--     agent_profit, account_deletion_requests.agent_code;
--   - the agent settings (agent_shutdown, withdrawal_override), the agent SMS
--     switches and the agent texts in the SMS log.
-- The people who were agents keep their normal customer accounts, wallets and
-- orders. The audit log keeps its lines (it cannot be edited).
--
-- Functions that stay are rewritten first so nothing refers to a dropped table:
-- place_order (the p_agent_code parameter stays so older pages still work; it
-- is ignored), account deletion, and the audit log's "who did it".

begin;

-- 1. Orders: same as before, without agent links.
create or replace function public.place_order(p_bundle_id text, p_phone text, p_agent_code text default null::text, p_request_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_bundle    public.bundles%rowtype;
  v_price     numeric;
  v_balance   numeric;
  v_existing  public.orders%rowtype;
  v_ref       text;
  v_fee       numeric := 0;
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
                                'new_balance', v_balance, 'duplicate', true,
                                'unverified_fee', v_existing.unverified_fee);
    end if;
  end if;
  if coalesce(p_phone, '') !~ '^0(24|54|55|59|25|53|63|77|57|20|50|26|56|27|76|23|28|58)[0-9]{7}$' then
    raise exception 'Enter a valid 10-digit Ghana phone number';
  end if;
  select * into v_bundle from public.bundles where id = p_bundle_id and active;
  if not found then
    raise exception 'Bundle not found';
  end if;
  -- Unverified MTN number: fixed extra on top of the price.
  v_fee := private.unverified_fee(p_phone, v_bundle.network);
  v_price := v_bundle.price + v_fee;
  if v_balance < v_price then
    raise exception 'Insufficient balance. Please deposit funds.';
  end if;
  v_ref := 'ORD-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));
  update public.profiles set balance = balance - v_price, updated_at = now() where id = v_uid;
  insert into public.transactions (user_id, type, amount, reference, status, created_at)
  values (v_uid, 'purchase', v_price, v_ref, 'completed', now());
  insert into public.orders (
    ref, "Phone", "Network", bundle_name, "Amount", "Status", provider, user_id,
    pricing_mode, base_price_used, api_status, retry_count, processed_by_api,
    client_request_id, unverified_fee, created_at, updated_at
  ) values (
    v_ref, p_phone, v_bundle.network, v_bundle.size, v_price, 'Pending', 'patupaa', v_uid,
    'system', v_bundle.price, 'pending', 0, false, p_request_id, v_fee, now(), now()
  );
  return jsonb_build_object('ref', v_ref, 'amount', v_price,
                            'new_balance', v_balance - v_price, 'duplicate', false,
                            'unverified_fee', v_fee);
end;
$function$;

-- 2. Account deletion: no agent records to clean up any more.
create or replace function public.approve_account_deletion(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_req     public.account_deletion_requests%rowtype;
  v_uid     uuid;
  v_balance numeric(10, 2);
begin
  if not public.is_admin() then raise exception 'Admin access only'; end if;
  select * into v_req from public.account_deletion_requests where id = p_id for update;
  if not found or v_req.status <> 'pending' then raise exception 'Request not found or already reviewed'; end if;
  v_uid := v_req.user_id;
  if v_uid is null then raise exception 'This account no longer exists'; end if;
  if exists (select 1 from public.profiles where id = v_uid and (role = 'admin' or is_admin)) then
    raise exception 'The admin account cannot be deleted';
  end if;

  select coalesce(balance, 0) into v_balance from public.profiles where id = v_uid;

  delete from auth.users where id = v_uid;

  update public.account_deletion_requests
  set status = 'approved', balance_forfeited = v_balance,
      label = left(coalesce(v_req.label, ''), 1) || '*** (deleted)',
      email = null, phone = null, reason = null,
      reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id;

  return jsonb_build_object('deleted', true, 'balance_forfeited', v_balance, 'orders_kept_for_agents', 0);
end;
$function$;

create or replace function public.request_account_deletion(p_reason text default null::text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_p   public.profiles%rowtype;
  v_id  uuid;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  if public.is_admin() then raise exception 'The admin account cannot be deleted this way'; end if;
  if exists (select 1 from public.account_deletion_requests where user_id = v_uid and status = 'pending') then
    raise exception 'You already asked for your account to be deleted. The admin will review it.';
  end if;
  select * into v_p from public.profiles where id = v_uid;
  insert into public.account_deletion_requests (user_id, label, email, phone, reason)
  values (v_uid, coalesce(nullif(v_p.full_name, ''), v_p.email), v_p.email, v_p.phone,
          nullif(left(trim(coalesce(p_reason, '')), 300), ''))
  returning id into v_id;
  return v_id;
end;
$function$;

-- 3. Audit log: signed-in people are "admin" or "customer" (no more agents).
create or replace function private.audit_add(
  p_category text, p_action text, p_summary text,
  p_table text default null, p_target text default null,
  p_subject uuid default null, p_subject_email text default null,
  p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_uid   uuid;
  v_claim text;
  v_kind  text;
  v_email text;
  v_role  text;
begin
  begin
    v_uid := auth.uid();
  exception when others then
    v_uid := null;
  end;
  v_claim := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
  if v_uid is not null then
    select email, role into v_email, v_role from public.profiles where id = v_uid;
    v_email := coalesce(v_email, (select email from auth.users where id = v_uid));
    v_kind := case when v_role = 'admin' then 'admin' else 'customer' end;
  elsif v_claim = 'service_role' then
    v_kind := 'system';  v_email := 'Server (edge function)';
  elsif v_claim = 'anon' then
    v_kind := 'visitor';
  else
    v_kind := 'database'; v_email := 'Supabase dashboard / database (' || current_user || ')';
  end if;

  if random() < 0.01 then
    delete from private.audit_log where at < now() - interval '400 days';
  end if;

  insert into private.audit_log
    (actor_id, actor_kind, actor_email, ip, category, action, summary,
     target_table, target_id, subject_id, subject_email, details)
  values
    (v_uid, v_kind, v_email, case when v_claim <> '' then private.client_ip() end,
     p_category, p_action, left(p_summary, 500),
     p_table, p_target, p_subject, coalesce(p_subject_email, private.audit_email(p_subject)),
     coalesce(p_details, '{}'::jsonb));
exception when others then
  raise warning 'audit_add(%) failed: %', p_action, sqlerrm;
end;
$$;

-- 4. Settings check without the agent settings.
create or replace function public.check_app_setting()
returns trigger
language plpgsql
security definer
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
  if new.key = 'seevplus_fee_percent' and (jsonb_typeof(new.value) <> 'number' or (new.value #>> '{}')::numeric not between 0 and 10) then
    raise exception 'The SeevPlus fee must be between 0 and 10 percent';
  end if;
  if new.key = 'seevplus_enabled' then
    if jsonb_typeof(new.value) <> 'boolean' then
      raise exception 'seevplus_enabled must be true or false';
    end if;
    if new.value = 'true'::jsonb and not exists (select 1 from private.secrets where key = 'seevplus_secret_key') then
      raise exception 'Save the SeevPlus secret key first';
    end if;
  end if;
  if new.key = 'unverified_enabled' and jsonb_typeof(new.value) <> 'boolean' then
    raise exception 'unverified_enabled must be true or false';
  end if;
  if new.key = 'unverified_surcharge' and (jsonb_typeof(new.value) <> 'number' or (new.value #>> '{}')::numeric not between 0 and 50
      or (new.value #>> '{}')::numeric <> round((new.value #>> '{}')::numeric, 2)) then
    raise exception 'The unverified number charge must be between GHS 0 and GHS 50 (pesewas at most)';
  end if;
  return new;
end;
$function$;

-- 5. Agent details on tables that stay.
drop trigger if exists trigger_update_agent_sales on public.orders;
drop policy if exists "Agents can view their linked orders" on public.orders;
drop index if exists public.idx_orders_agent_id;
alter table public.orders drop constraint if exists fk_orders_agent;
alter table public.orders
  drop column if exists agent_id,
  drop column if exists agent_code,
  drop column if exists agent_profit;
update public.orders set pricing_mode = 'system' where pricing_mode is distinct from 'system';
alter table public.account_deletion_requests drop column if exists agent_code;

-- 6. The agent tables, with their rows, policies and triggers.
drop table if exists
  public.price_unlock_requests,
  public.agent_withdrawals,
  public.agent_earnings,
  public.agent_prices,
  public.agent_base_prices,
  public.agent_profiles
  cascade;

-- 7. Functions that only served agents.
drop function if exists public.admin_cancel_agent_shutdown();
drop function if exists public.admin_start_agent_shutdown(boolean);
drop function if exists public.agent_available_profit(uuid);
drop function if exists public.agent_contact(text);
drop function if exists public.agents_phase();
drop function if exists public.approve_price_unlock(uuid, integer);
drop function if exists public.delete_price_unlock_request(uuid);
drop function if exists public.get_agent_link_prices(text);
drop function if exists public.guard_agent_price();
drop function if exists public.guard_agent_profile_update();
drop function if exists public.guard_agents_open();
drop function if exists public.lock_agent_pricing(uuid);
drop function if exists public.reject_price_unlock(uuid);
drop function if exists public.request_agent_withdrawal(numeric, text, text);
drop function if exists public.request_price_unlock(text);
drop function if exists public.sms_on_agent();
drop function if exists public.sms_on_price_unlock();
drop function if exists public.sms_on_withdrawal();
drop function if exists public.sync_agent_final_prices();
drop function if exists public.sync_agent_price_locks();
drop function if exists public.update_agent_total_sales();
drop function if exists public.update_agent_total_withdrawn();

-- 8. Agent settings, SMS switches and agent texts in the SMS log.
delete from public.app_settings where key in ('agent_shutdown', 'withdrawal_override');
update private.sms_settings
   set events = coalesce(events, '{}'::jsonb) - 'agent_status' - 'withdrawal_update' - 'price_unlock_update'
                - 'admin_new_withdrawal' - 'admin_new_agent' - 'admin_price_request';
delete from public.sms_outbox
 where event in ('agent_deactivation', 'agent_status', 'withdrawal_update', 'price_unlock_update',
                 'admin_new_withdrawal', 'admin_new_agent', 'admin_price_request');

commit;
