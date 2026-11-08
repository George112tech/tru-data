-- TRU SMS: send texts from your own Android phone, without httpSMS.
--
-- The TRU SMS app (android-sms/) runs on a phone with a SIM. Every few seconds
-- it calls gateway_poll() with its pairing code: the database hands it the
-- waiting texts (sms_outbox) and the phone sends them from its SIM, then
-- reports each result with gateway_report() (sent, failed, delivered).
-- No outside service is involved, so there is no monthly limit; each text
-- costs what an SMS costs on that SIM.
--
-- Admin -> SMS chooses who sends: 'httpsms' (as before) or 'device' (the
-- phone). In 'device' mode the database no longer calls the send-sms
-- function, so httpSMS is never used.
--
-- Pairing: Admin -> SMS -> "Pair a phone" makes a one-time code
-- (xxxx-xxxx-xxxx-xxxx-xxxx, 80 random bits) that is typed or pasted into the
-- app. Only its SHA-256 is stored. Pairing again disconnects the old phone.
-- The phone's "last seen" and status live in private.sms_device, not in
-- sms_settings, so the audit log does not get a line every few seconds.

begin;

alter table private.sms_settings
  add column if not exists provider text not null default 'httpsms';
do $$ begin
  alter table private.sms_settings add constraint sms_settings_provider_check check (provider in ('httpsms', 'device'));
exception when duplicate_object then null; end $$;

create table if not exists private.sms_device (
  id          boolean primary key default true check (id),
  token_hash  text,
  paired_at   timestamptz,
  seen_at     timestamptz,
  info        jsonb not null default '{}'::jsonb
);
insert into private.sms_device (id) values (true) on conflict (id) do nothing;
revoke all on private.sms_device from public, anon, authenticated;

-- When a text was handed to the phone, and when the network said it arrived.
alter table public.sms_outbox add column if not exists claimed_at timestamptz;
alter table public.sms_outbox add column if not exists delivered_at timestamptz;

-- Can texts go out right now (the chosen sender is set up)?
create or replace function private.sms_ready()
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select coalesce((
    select case when s.provider = 'device'
                then (select token_hash is not null from private.sms_device where id)
                else s.api_key is not null and s.from_number is not null end
      from private.sms_settings s where s.id), false);
$$;

-- The phone's pairing code, normalised (hex digits only) and hashed.
create or replace function private.sms_device_ok(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select exists (
    select 1 from private.sms_device
     where id and token_hash is not null
       and token_hash = encode(sha256(convert_to(lower(regexp_replace(coalesce(p_code, ''), '[^0-9A-Fa-f]', '', 'g')), 'UTF8')), 'hex'));
$$;

-- ---------------------------------------------------------------------------
-- httpSMS is only called in 'httpsms' mode
-- ---------------------------------------------------------------------------

create or replace function public.sms_dispatch_config()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'private'
as $function$
  -- In phone mode send-sms gets no key, so it leaves the queue to the phone.
  select jsonb_build_object('enabled', enabled,
                            'api_key', case when provider = 'device' then null else api_key end,
                            'from_number', case when provider = 'device' then null else from_number end,
                            'dispatch_secret', dispatch_secret,
                            'provider', provider)
  from private.sms_settings where id;
$function$;

create or replace function public.sms_kick_dispatch()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare v_secret text; v_provider text;
begin
  select dispatch_secret, provider into v_secret, v_provider from private.sms_settings where id;
  if v_provider = 'device' then
    return null; -- the phone collects texts itself
  end if;
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
$function$;

create or replace function public.sms_kick_dispatch_now()
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare v_secret text; v_provider text;
begin
  select dispatch_secret, provider into v_secret, v_provider from private.sms_settings where id;
  if v_provider = 'device' then
    return;
  end if;
  perform net.http_post(
    url     := 'https://kefcmjfvrqbgtivssdwn.supabase.co/functions/v1/send-sms',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- The phone
-- ---------------------------------------------------------------------------

-- Hands the phone up to p_limit waiting texts (and records that it is online).
-- With p_limit 0 it only checks the pairing code and whether the phone is the sender.
create or replace function public.gateway_poll(p_code text, p_limit integer default 10, p_info jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_set  private.sms_settings%rowtype;
  v_msgs jsonb;
begin
  if not private.sms_device_ok(p_code) then
    raise exception 'This phone is not paired. Make a pairing code in Admin -> SMS and enter it in TRU SMS.'
      using errcode = '28000';
  end if;
  update private.sms_device
     set seen_at = now(),
         info = case when jsonb_typeof(p_info) = 'object' and char_length(p_info::text) <= 2000 then p_info else info end
   where id;
  select * into v_set from private.sms_settings where id;
  if v_set.provider <> 'device' or not v_set.enabled then
    return jsonb_build_object('active', false, 'messages', '[]'::jsonb,
      'reason', case when not v_set.enabled then 'SMS is switched off in Admin -> SMS.'
                     else 'Admin -> SMS sends through httpSMS, not this phone.' end);
  end if;
  -- p_limit 0: only check the code and the settings (the app's Connect button).
  if coalesce(p_limit, 10) <= 0 then
    return jsonb_build_object('active', true, 'messages', '[]'::jsonb);
  end if;
  with claimed as (
    update public.sms_outbox o
       set status = 'sending', attempts = o.attempts + 1, claimed_at = now()
     where o.id in (
       select id from public.sms_outbox
        where attempts < 3
          and (status = 'pending'
               or (status = 'sending' and coalesce(claimed_at, created_at) < now() - interval '10 minutes'))
        order by created_at
        limit greatest(1, least(coalesce(p_limit, 10), 50))
        for update skip locked)
    returning o.id, o.to_phone, o.content, o.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'to', to_phone, 'content', content) order by created_at), '[]'::jsonb)
    into v_msgs from claimed;
  return jsonb_build_object('active', true, 'messages', v_msgs);
end;
$$;

-- The phone reports results: [{"id": "...", "stage": "sent" | "failed" | "delivered", "error": "..."}].
create or replace function public.gateway_report(p_code text, p_results jsonb)
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  r     jsonb;
  v_id  uuid;
  v_n   integer := 0;
  v_c   integer;
begin
  if not private.sms_device_ok(p_code) then
    raise exception 'This phone is not paired.' using errcode = '28000';
  end if;
  if jsonb_typeof(p_results) <> 'array' then
    raise exception 'Results must be a list';
  end if;
  update private.sms_device set seen_at = now() where id;
  for r in select * from jsonb_array_elements(p_results) limit 200 loop
    begin
      v_id := (r ->> 'id')::uuid;
    exception when others then
      continue;
    end;
    if r ->> 'stage' = 'sent' then
      update public.sms_outbox set status = 'sent', sent_at = coalesce(sent_at, now()), error = null
       where id = v_id and status in ('sending', 'pending', 'failed');
    elsif r ->> 'stage' = 'delivered' then
      update public.sms_outbox set status = 'sent', sent_at = coalesce(sent_at, now()), delivered_at = now(), error = null
       where id = v_id;
    elsif r ->> 'stage' = 'failed' then
      update public.sms_outbox
         set status = case when attempts >= 3 then 'failed' else 'pending' end,
             error = left(coalesce(nullif(r ->> 'error', ''), 'The phone could not send it'), 500)
       where id = v_id and status = 'sending';
    else
      continue;
    end if;
    get diagnostics v_c = row_count;
    v_n := v_n + v_c;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.gateway_poll(text, integer, jsonb) from public;
revoke execute on function public.gateway_report(text, jsonb) from public;
grant execute on function public.gateway_poll(text, integer, jsonb) to anon, authenticated;
grant execute on function public.gateway_report(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

-- A new pairing code (shown once). The old phone stops working.
create or replace function public.admin_sms_pair_device()
returns text
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_hex  text := left(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 20);
  v_code text;
begin
  if not public.is_admin() then raise exception 'Admin access only'; end if;
  v_code := substr(v_hex, 1, 4) || '-' || substr(v_hex, 5, 4) || '-' || substr(v_hex, 9, 4) || '-' || substr(v_hex, 13, 4) || '-' || substr(v_hex, 17, 4);
  update private.sms_device
     set token_hash = encode(sha256(convert_to(v_hex, 'UTF8')), 'hex'),
         paired_at = now(), seen_at = null, info = '{}'::jsonb
   where id;
  perform private.audit_add('settings', 'sms.phone_paired', 'New pairing code made for the TRU SMS phone (any earlier phone is disconnected)',
    'sms_device', null, null, null, '{}'::jsonb);
  return v_code;
end;
$$;

create or replace function public.admin_sms_unpair_device()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if not public.is_admin() then raise exception 'Admin access only'; end if;
  update private.sms_device set token_hash = null, paired_at = null, seen_at = null, info = '{}'::jsonb where id;
  perform private.audit_add('settings', 'sms.phone_unpaired', 'TRU SMS phone disconnected', 'sms_device', null, null, null, '{}'::jsonb);
end;
$$;

revoke execute on function public.admin_sms_pair_device() from public, anon;
revoke execute on function public.admin_sms_unpair_device() from public, anon;
grant execute on function public.admin_sms_pair_device() to authenticated;
grant execute on function public.admin_sms_unpair_device() to authenticated;

create or replace function public.get_sms_settings()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare v private.sms_settings%rowtype; d private.sms_device%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v from private.sms_settings where id;
  select * into d from private.sms_device where id;
  return jsonb_build_object(
    'enabled', v.enabled,
    'provider', v.provider,
    'api_key_set', v.api_key is not null,
    'api_key_last4', right(v.api_key, 4),
    'from_number', v.from_number,
    'admin_phone', v.admin_phone,
    'events', v.events,
    'updated_at', v.updated_at,
    'device_paired', d.token_hash is not null,
    'device_paired_at', d.paired_at,
    'device_seen_at', d.seen_at,
    'device_info', d.info,
    'waiting', (select count(*) from public.sms_outbox where status in ('pending', 'sending')));
end;
$function$;

drop function if exists public.save_sms_settings(boolean, text, text, jsonb, text);
create or replace function public.save_sms_settings(p_enabled boolean, p_from_number text, p_admin_phone text, p_events jsonb,
                                                    p_api_key text default null, p_provider text default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  v_from     text := public.sms_normalize_phone(p_from_number);
  v_admin    text := public.sms_normalize_phone(p_admin_phone);
  v_key      text := nullif(trim(coalesce(p_api_key, '')), '');
  v_provider text;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  v_provider := coalesce(nullif(trim(coalesce(p_provider, '')), ''), (select provider from private.sms_settings where id), 'httpsms');
  if v_provider not in ('httpsms', 'device') then
    raise exception 'Choose who sends the texts: your phone (TRU SMS) or httpSMS';
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
    provider    = v_provider,
    updated_at  = now()
  where id;

  if p_enabled and not private.sms_ready() then
    raise exception '%', case when v_provider = 'device'
      then 'Pair your phone (TRU SMS app) before turning SMS on'
      else 'Save the httpSMS API key and the sending phone before turning SMS on' end;
  end if;
  update private.sms_settings set enabled = coalesce(p_enabled, false) where id;
end;
$function$;
revoke execute on function public.save_sms_settings(boolean, text, text, jsonb, text, text) from public, anon;
grant execute on function public.save_sms_settings(boolean, text, text, jsonb, text, text) to authenticated;

-- "Set up SMS first" now means: the chosen sender is set up.
create or replace function public.send_test_sms(p_to text)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
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
  if not private.sms_ready() then
    raise exception 'Set up SMS first: pair your phone (TRU SMS) or save the httpSMS key and sending phone';
  end if;
  insert into public.sms_outbox (event, to_phone, content)
  values ('test', v_to, 'TRU Data: test message. SMS notifications are working.')
  returning id into v_id;
  return v_id;
end;
$function$;

create or replace function public.admin_send_sms(p_to text[], p_message text)
returns integer
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  v_msg text := trim(coalesce(p_message, ''));
  v_n   integer := 0;
  v_to  text;
  v_seen text[] := '{}';
begin
  if not public.is_admin() then raise exception 'Admin access only'; end if;
  if char_length(v_msg) < 1 then raise exception 'Type a message first'; end if;
  if char_length(v_msg) > 480 then raise exception 'The message is too long (480 characters at most)'; end if;
  if not private.sms_ready() then
    raise exception 'Set up SMS first (Admin → SMS: pair your phone or save the httpSMS key)';
  end if;
  foreach v_to in array coalesce(p_to, '{}') loop
    v_to := public.sms_normalize_phone(v_to);
    if v_to is not null and not (v_to = any (v_seen)) then
      insert into public.sms_outbox (event, to_phone, content) values ('admin_message', v_to, v_msg);
      v_seen := v_seen || v_to;
      v_n := v_n + 1;
    end if;
  end loop;
  if v_n = 0 then raise exception 'No valid Ghana phone number to send to'; end if;
  perform private.audit_add('messages', 'sms.sent',
    'SMS sent to ' || v_n || case when v_n = 1 then ' number (' || v_seen[1] || ')' else ' numbers' end || ': ' || left(v_msg, 160),
    'sms_outbox', null, null, null, jsonb_build_object('to', to_jsonb(v_seen), 'message', v_msg));
  return v_n;
end;
$function$;

create or replace function public.admin_sms_customers(p_message text)
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_msg text := trim(coalesce(p_message, ''));
  v_n   integer;
begin
  if not public.is_admin() then raise exception 'Admin access only'; end if;
  if char_length(v_msg) < 1 then raise exception 'Type a message first'; end if;
  if char_length(v_msg) > 480 then raise exception 'The message is too long (480 characters at most)'; end if;
  if not private.sms_ready() then
    raise exception 'Set up SMS first (Admin → SMS: pair your phone or save the httpSMS key)';
  end if;
  insert into public.sms_outbox (event, to_phone, content)
  select distinct 'admin_broadcast', public.sms_normalize_phone(phone), v_msg
    from public.profiles
   where coalesce(role, 'user') <> 'admin' and not coalesce(is_admin, false)
     and public.sms_normalize_phone(phone) is not null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'No customer has a valid phone number yet'; end if;
  perform private.audit_add('messages', 'sms.broadcast',
    'SMS sent to all customers (' || v_n || ' numbers): ' || left(v_msg, 160),
    'sms_outbox', null, null, null, jsonb_build_object('count', v_n, 'message', v_msg));
  return v_n;
end;
$$;

commit;
