-- SMS notifications through httpSMS (https://httpsms.com).
--
-- httpSMS turns an Android phone into an SMS gateway: we call its API and the
-- phone running the httpSMS app sends the text from its own SIM.
--
-- How it works here:
--   1. Triggers on orders, transactions, deposit_requests, agent_withdrawals,
--      agent_profiles and price_unlock_requests write a row to sms_outbox.
--      A failure here never blocks the order/deposit/etc.
--   2. A statement trigger on sms_outbox asks pg_net to call the send-sms
--      Edge Function once the transaction commits (pg_net's queue is
--      transactional, so a rolled-back order sends nothing).
--   3. send-sms claims pending rows and posts each one to
--      https://api.httpsms.com/v1/messages/send.
--
-- Settings (on/off, API key, sending phone, admin alert phone, which events)
-- live in private.sms_settings. Only the admin can change them, and the API
-- key is never readable from the browser.
--
-- Run AFTER 20261030180000_agent_price_unlock_requests.sql.

begin;

create extension if not exists pg_net;

-- ---------------------------------------------------------------------------
-- Settings and outbox
-- ---------------------------------------------------------------------------

create table if not exists private.sms_settings (
  id              boolean primary key default true check (id),
  enabled         boolean not null default false,
  api_key         text,
  from_number     text,
  admin_phone     text,
  events          jsonb not null default '{}'::jsonb,
  dispatch_secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  updated_at      timestamptz not null default now()
);
insert into private.sms_settings (id) values (true) on conflict (id) do nothing;
revoke all on private.sms_settings from public, anon, authenticated;

create table if not exists public.sms_outbox (
  id          uuid primary key default gen_random_uuid(),
  event       text not null,
  to_phone    text not null,
  content     text not null check (char_length(content) <= 480),
  status      text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts    integer not null default 0,
  provider_id text,
  error       text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index if not exists sms_outbox_status_idx on public.sms_outbox (status, created_at);

alter table public.sms_outbox enable row level security;
drop policy if exists "Admins view sms outbox" on public.sms_outbox;
create policy "Admins view sms outbox" on public.sms_outbox
  for select to authenticated using (public.is_admin());
revoke all on public.sms_outbox from anon, authenticated;
grant select on public.sms_outbox to authenticated;

-- 0241234567 / 241234567 / 233241234567 / +233241234567 -> +233241234567.
-- Anything else (including foreign numbers) is rejected.
create or replace function public.sms_normalize_phone(p_phone text)
returns text
language sql
immutable
as $$
  select case
    when d ~ '^0[2-5][0-9]{8}$'   then '+233' || substr(d, 2)
    when d ~ '^[2-5][0-9]{8}$'    then '+233' || d
    when d ~ '^233[2-5][0-9]{8}$' then '+' || d
  end
  from (select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as d) s;
$$;

-- Queue one SMS. p_to = null means "the admin alert phone".
-- Never raises: notifications must not break the action that caused them.
create or replace function public.sms_enqueue(p_event text, p_to text, p_content text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_set private.sms_settings%rowtype;
  v_to  text;
begin
  select * into v_set from private.sms_settings where id;
  if not found or not v_set.enabled or nullif(p_content, '') is null then
    return;
  end if;
  if coalesce((v_set.events ->> p_event)::boolean, true) = false then
    return;
  end if;
  v_to := public.sms_normalize_phone(coalesce(p_to, v_set.admin_phone));
  if v_to is null then
    return;
  end if;
  insert into public.sms_outbox (event, to_phone, content)
  values (p_event, v_to, left(p_content, 480));
exception when others then
  raise warning 'sms_enqueue(%) failed: %', p_event, sqlerrm;
end;
$$;

revoke execute on function public.sms_enqueue(text, text, text) from public, anon, authenticated;

-- After the statement that queued messages: ask send-sms to deliver them.
create or replace function public.sms_kick_dispatch()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare v_secret text;
begin
  select dispatch_secret into v_secret from private.sms_settings where id;
  perform net.http_post(
    url     := 'https://kefcmjfvrqbgtivssdwn.supabase.co/functions/v1/send-sms',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  return null;
exception when others then
  raise warning 'sms dispatch kick failed: %', sqlerrm;
  return null;
end;
$$;

revoke execute on function public.sms_kick_dispatch() from public, anon, authenticated;

drop trigger if exists sms_outbox_dispatch on public.sms_outbox;
create trigger sms_outbox_dispatch
  after insert on public.sms_outbox
  for each statement execute function public.sms_kick_dispatch();

-- ---------------------------------------------------------------------------
-- Used by the send-sms Edge Function (service role only)
-- ---------------------------------------------------------------------------

create or replace function public.sms_dispatch_config()
returns jsonb
language sql
stable
security definer
set search_path = public, private
as $$
  select jsonb_build_object('enabled', enabled, 'api_key', api_key, 'from_number', from_number,
                            'dispatch_secret', dispatch_secret)
  from private.sms_settings where id;
$$;

-- Claims up to p_limit messages. Messages stuck in "sending" for 5 minutes
-- (function crashed mid-way) are picked up again; 3 attempts at most.
create or replace function public.sms_claim_batch(p_limit integer default 20)
returns setof public.sms_outbox
language sql
security definer
set search_path = public
as $$
  update public.sms_outbox o
  set status = 'sending', attempts = o.attempts + 1
  where o.id in (
    select id from public.sms_outbox
    where attempts < 3
      and (status = 'pending' or (status = 'sending' and created_at < now() - interval '5 minutes'))
    order by created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  )
  returning o.*;
$$;

create or replace function public.sms_mark(p_id uuid, p_ok boolean, p_provider_id text, p_error text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.sms_outbox
  set status = case when p_ok then 'sent'
                    when attempts >= 3 then 'failed'
                    else 'pending' end,
      provider_id = coalesce(p_provider_id, provider_id),
      error = left(p_error, 500),
      sent_at = case when p_ok then now() else sent_at end
  where id = p_id;
$$;

revoke execute on function public.sms_dispatch_config() from public, anon, authenticated;
revoke execute on function public.sms_claim_batch(integer) from public, anon, authenticated;
revoke execute on function public.sms_mark(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.sms_dispatch_config() to service_role;
grant execute on function public.sms_claim_batch(integer) to service_role;
grant execute on function public.sms_mark(uuid, boolean, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Admin settings screen
-- ---------------------------------------------------------------------------

create or replace function public.get_sms_settings()
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare v private.sms_settings%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v from private.sms_settings where id;
  return jsonb_build_object(
    'enabled', v.enabled,
    'api_key_set', v.api_key is not null,
    'api_key_last4', right(v.api_key, 4),
    'from_number', v.from_number,
    'admin_phone', v.admin_phone,
    'events', v.events,
    'updated_at', v.updated_at);
end;
$$;

-- p_api_key: null or '' keeps the saved key.
create or replace function public.save_sms_settings(
  p_enabled boolean, p_from_number text, p_admin_phone text, p_events jsonb, p_api_key text default null
)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_from  text := public.sms_normalize_phone(p_from_number);
  v_admin text := public.sms_normalize_phone(p_admin_phone);
  v_key   text := nullif(trim(coalesce(p_api_key, '')), '');
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if nullif(trim(coalesce(p_from_number, '')), '') is not null and v_from is null then
    raise exception 'Sending phone must be a Ghana number like 0505175472';
  end if;
  if nullif(trim(coalesce(p_admin_phone, '')), '') is not null and v_admin is null then
    raise exception 'Admin alert phone must be a Ghana number like 0505175472';
  end if;
  if v_key is not null and (char_length(v_key) < 20 or char_length(v_key) > 200 or v_key ~ '\s') then
    raise exception 'That does not look like an httpSMS API key';
  end if;
  if p_events is not null and jsonb_typeof(p_events) <> 'object' then
    raise exception 'Invalid event settings';
  end if;

  update private.sms_settings set
    api_key     = coalesce(v_key, api_key),
    from_number = v_from,
    admin_phone = v_admin,
    events      = coalesce(p_events, events),
    updated_at  = now()
  where id;

  if p_enabled and ((select api_key from private.sms_settings where id) is null or v_from is null) then
    raise exception 'Save the httpSMS API key and the sending phone before turning SMS on';
  end if;
  update private.sms_settings set enabled = coalesce(p_enabled, false) where id;
end;
$$;

create or replace function public.send_test_sms(p_to text)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_to text := public.sms_normalize_phone(p_to);
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if v_to is null then
    raise exception 'Enter a Ghana number like 0241234567';
  end if;
  if not exists (select 1 from private.sms_settings where id and api_key is not null and from_number is not null) then
    raise exception 'Save the httpSMS API key and the sending phone first';
  end if;
  insert into public.sms_outbox (event, to_phone, content)
  values ('test', v_to, 'TRU Data: test message. SMS notifications are working.')
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.retry_sms(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update public.sms_outbox set status = 'pending', attempts = 0, error = null
  where id = p_id and status in ('failed', 'pending');
  -- An UPDATE does not fire the insert trigger, so kick the sender directly.
  perform public.sms_kick_dispatch_now();
end;
$$;

create or replace function public.sms_kick_dispatch_now()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare v_secret text;
begin
  select dispatch_secret into v_secret from private.sms_settings where id;
  perform net.http_post(
    url     := 'https://kefcmjfvrqbgtivssdwn.supabase.co/functions/v1/send-sms',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
end;
$$;

revoke execute on function public.sms_kick_dispatch_now() from public, anon, authenticated;
revoke execute on function public.get_sms_settings() from public, anon;
grant execute on function public.get_sms_settings() to authenticated;
revoke execute on function public.save_sms_settings(boolean, text, text, jsonb, text) from public, anon;
grant execute on function public.save_sms_settings(boolean, text, text, jsonb, text) to authenticated;
revoke execute on function public.send_test_sms(text) from public, anon;
grant execute on function public.send_test_sms(text) to authenticated;
revoke execute on function public.retry_sms(uuid) from public, anon;
grant execute on function public.retry_sms(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Event triggers
-- ---------------------------------------------------------------------------

create or replace function public.sms_money(p numeric)
returns text
language sql
immutable
as $$ select 'GHS ' || to_char(coalesce(p, 0), 'FM999990.00') $$;

-- Customer's own phone, else the number the bundle went to.
create or replace function public.sms_customer_phone(p_user uuid, p_fallback text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.sms_normalize_phone((select phone from public.profiles where id = p_user)),
                  public.sms_normalize_phone(p_fallback));
$$;

revoke execute on function public.sms_customer_phone(uuid, text) from public, anon, authenticated;

create or replace function public.sms_on_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to       text := public.sms_customer_phone(new.user_id, new."Phone");
  v_bundle   text := coalesce(new.bundle_name, '') || ' ' || upper(coalesce(new."Network", ''));
  v_refunded boolean;
begin
  if tg_op = 'INSERT' then
    perform public.sms_enqueue('order_placed', v_to,
      'TRU Data: Order ' || new.ref || ' received. ' || v_bundle || ' to ' || coalesce(new."Phone", '') ||
      ', ' || public.sms_money(new."Amount") || '. We will text you when it is delivered.');
    perform public.sms_enqueue('admin_new_order', null,
      'TRU Data admin: New order ' || new.ref || ' - ' || v_bundle || ' to ' || coalesce(new."Phone", '') ||
      ', ' || public.sms_money(new."Amount") || '.');
  elsif new."Status" is distinct from old."Status" then
    if new."Status" in ('Delivered', 'Completed') and coalesce(old."Status", '') not in ('Delivered', 'Completed') then
      perform public.sms_enqueue('order_delivered', v_to,
        'TRU Data: Your ' || v_bundle || ' data to ' || coalesce(new."Phone", '') ||
        ' has been delivered. Ref ' || new.ref || '. Thank you!');
    elsif new."Status" = 'Deleted' then
      v_refunded := exists (select 1 from public.transactions where reference = 'RFD-' || new.ref);
      perform public.sms_enqueue('order_cancelled', v_to,
        'TRU Data: Order ' || new.ref || ' (' || v_bundle || ') was cancelled.' ||
        case when v_refunded then ' ' || public.sms_money(new."Amount") || ' has been refunded to your wallet.' else '' end);
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists sms_order_events on public.orders;
create trigger sms_order_events
  after insert or update of "Status" on public.orders
  for each row execute function public.sms_on_order();

-- Wallet credits (MoMo approval, direct credit, Paystack). Deferred to the
-- end of the transaction so the balance update that follows the insert is
-- already done and the new balance is right.
create or replace function public.sms_on_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_balance numeric;
begin
  if new.type = 'deposit' and new.status = 'completed' then
    select balance into v_balance from public.profiles where id = new.user_id;
    perform public.sms_enqueue('deposit_credited', public.sms_customer_phone(new.user_id, null),
      'TRU Data: ' || public.sms_money(new.amount) || ' has been added to your wallet. New balance ' ||
      public.sms_money(v_balance) || '.');
  end if;
  return null;
end;
$$;

drop trigger if exists sms_transaction_events on public.transactions;
create constraint trigger sms_transaction_events
  after insert on public.transactions
  deferrable initially deferred
  for each row execute function public.sms_on_transaction();

create or replace function public.sms_on_deposit_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_who text;
begin
  if tg_op = 'INSERT' then
    select coalesce(nullif(full_name, ''), email) || ' (' || coalesce(deposit_code, '?') || ')'
      into v_who from public.profiles where id = new.user_id;
    perform public.sms_enqueue('admin_new_deposit', null,
      'TRU Data admin: ' || coalesce(v_who, 'A customer') || ' says they sent ' || public.sms_money(new.amount) ||
      coalesce(' (MoMo ID ' || new.momo_txn_id || ')', '') || '. Check and approve in Deposits.');
  elsif new.status = 'rejected' and old.status = 'pending' then
    perform public.sms_enqueue('deposit_rejected', public.sms_customer_phone(new.user_id, new.sender_phone),
      'TRU Data: We could not confirm your deposit of ' || public.sms_money(new.amount) || '.' ||
      coalesce(' ' || rtrim(nullif(left(trim(new.admin_note), 100), ''), '.') || '.', '') ||
      ' Call 0505175472 if you need help.');
  end if;
  return null;
end;
$$;

drop trigger if exists sms_deposit_request_events on public.deposit_requests;
create trigger sms_deposit_request_events
  after insert or update of status on public.deposit_requests
  for each row execute function public.sms_on_deposit_request();

create or replace function public.sms_on_withdrawal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent public.agent_profiles%rowtype;
  v_to    text;
  v_net   numeric := coalesce(new.net_amount, new.amount);
begin
  select * into v_agent from public.agent_profiles where user_id = new.user_id limit 1;
  v_to := coalesce(public.sms_normalize_phone(v_agent.phone), public.sms_normalize_phone(new.phone));
  if tg_op = 'INSERT' then
    perform public.sms_enqueue('admin_new_withdrawal', null,
      'TRU Data admin: Agent ' || coalesce(nullif(v_agent.name, ''), new.agent_id, '') || ' requested a withdrawal of ' ||
      public.sms_money(v_net) || ' to ' || coalesce(new.phone, '') || ' (' || upper(coalesce(new.network, '')) || ').');
  elsif new.status is distinct from old.status then
    if new.status = 'paid' then
      perform public.sms_enqueue('withdrawal_update', v_to,
        'TRU Data: Your withdrawal of ' || public.sms_money(v_net) || ' has been sent to ' ||
        coalesce(new.phone, 'your MoMo') || '.');
    elsif new.status = 'rejected' then
      perform public.sms_enqueue('withdrawal_update', v_to,
        'TRU Data: Your withdrawal request of ' || public.sms_money(v_net) ||
        ' was not approved. Please contact the admin.');
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists sms_withdrawal_events on public.agent_withdrawals;
create trigger sms_withdrawal_events
  after insert or update of status on public.agent_withdrawals
  for each row execute function public.sms_on_withdrawal();

create or replace function public.sms_on_agent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from 'pending') then
    perform public.sms_enqueue('admin_new_agent', null,
      'TRU Data admin: New agent application from ' || coalesce(new.name, '') || ' (' || coalesce(new.phone, '') ||
      '). Review it in Agents.');
  elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
    perform public.sms_enqueue('agent_status', new.phone,
      case new.status
        when 'active'    then 'TRU Data: Your agent account is approved. Log in to set your prices and share your agent link.'
        when 'rejected'  then 'TRU Data: Your agent application was not approved. You can update it and apply again.'
        when 'suspended' then 'TRU Data: Your agent account has been suspended. Please contact the admin.'
      end);
  end if;
  return null;
end;
$$;

drop trigger if exists sms_agent_events on public.agent_profiles;
create trigger sms_agent_events
  after insert or update of status on public.agent_profiles
  for each row execute function public.sms_on_agent();

create or replace function public.sms_on_price_unlock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_agent public.agent_profiles%rowtype;
begin
  select * into v_agent from public.agent_profiles where id = new.agent_profile_id;
  if tg_op = 'INSERT' then
    perform public.sms_enqueue('admin_price_request', null,
      'TRU Data admin: Agent ' || coalesce(nullif(v_agent.name, ''), v_agent.agent_id, '') || ' asked to change their prices.' ||
      coalesce(' Reason: ' || left(new.note, 80), ''));
  elsif new.status is distinct from old.status then
    perform public.sms_enqueue('price_unlock_update', v_agent.phone,
      case new.status
        when 'approved' then 'TRU Data: Your pricing is open until ' ||
          to_char(v_agent.price_unlock_until at time zone 'Africa/Accra', 'DD Mon HH24:MI') ||
          '. Change your prices before then.'
        when 'rejected' then 'TRU Data: Your price-change request was not approved.'
      end);
  end if;
  return null;
end;
$$;

drop trigger if exists sms_price_unlock_events on public.price_unlock_requests;
create trigger sms_price_unlock_events
  after insert or update of status on public.price_unlock_requests
  for each row execute function public.sms_on_price_unlock();

revoke execute on function public.sms_on_order() from public, anon, authenticated;
revoke execute on function public.sms_on_transaction() from public, anon, authenticated;
revoke execute on function public.sms_on_deposit_request() from public, anon, authenticated;
revoke execute on function public.sms_on_withdrawal() from public, anon, authenticated;
revoke execute on function public.sms_on_agent() from public, anon, authenticated;
revoke execute on function public.sms_on_price_unlock() from public, anon, authenticated;

commit;
