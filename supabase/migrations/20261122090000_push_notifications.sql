-- Push notifications to the TRU Data Android app (Firebase Cloud Messaging).
--
-- Every text a customer gets also comes as an app notification: order
-- received / being processed / processed / delivered / cancelled (and guest
-- refunds), wallet credited (MoMo or online payment), deposit not confirmed,
-- account locked, and the admin's messages to customers. They are sent even
-- when SMS is switched off. The send-push Edge Function delivers them through
-- Firebase to every phone where that customer (the account with that phone
-- number) uses the app; the phone shows it even when the app is closed, and
-- tapping it opens the right page (My Orders, Wallet).
--
-- How: sms_enqueue (every event text) and a trigger on sms_outbox (the
-- admin's "Send a text") call private.push_from_sms with the same words.
--
--   push_devices   the app's Firebase token for each phone, and whose it is.
--                  The app registers it on sign-in (push_register) and
--                  removes it on log-out (push_unregister). A token that
--                  Firebase says is no longer valid is removed by send-push.
--   push_outbox    notifications waiting / sent / failed.
--
-- Delivery: a new row wakes send-push at once (pg_net, with a dispatch
-- secret, like the SMS queue); a pg_cron job retries every minute and gives
-- up on a notification after an hour. Nothing is sent until the
-- FCM_SERVICE_ACCOUNT secret is set on the Edge Functions (see android/README).

create table if not exists public.push_devices (
  token        text primary key check (length(token) between 20 and 4096),
  user_id      uuid not null references auth.users(id) on delete cascade,
  platform     text not null default 'android',
  app_version  text,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists push_devices_user_idx on public.push_devices (user_id);
alter table public.push_devices enable row level security;
revoke all on public.push_devices from anon, authenticated;

create table if not exists public.push_outbox (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  title      text not null,
  body       text not null,
  data       jsonb not null default '{}'::jsonb,
  status     text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'no_device', 'expired')),
  attempts   integer not null default 0,
  error      text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index if not exists push_outbox_open_idx on public.push_outbox (created_at) where status in ('pending', 'sending');
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;

insert into private.secrets (key, value)
values ('push_dispatch_secret', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (key) do nothing;

-- The app (signed in) registers this phone's token.
create or replace function public.push_register(p_token text, p_platform text default 'android', p_app_version text default null)
returns boolean
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first';
  end if;
  if coalesce(length(p_token), 0) not between 20 and 4096 then
    raise exception 'Invalid token';
  end if;
  insert into public.push_devices (token, user_id, platform, app_version)
  values (p_token, auth.uid(), coalesce(nullif(p_platform, ''), 'android'), left(p_app_version, 20))
  on conflict (token) do update
     set user_id = excluded.user_id, platform = excluded.platform,
         app_version = excluded.app_version, last_seen_at = now();
  -- At most 10 phones per account (the oldest go).
  delete from public.push_devices
   where user_id = auth.uid()
     and token not in (select token from public.push_devices where user_id = auth.uid() order by last_seen_at desc limit 10);
  return true;
end;
$$;

-- On log-out the app forgets this phone (only the phone knows its token).
create or replace function public.push_unregister(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public, private
as $$
begin
  delete from public.push_devices where token = p_token;
  return found;
end;
$$;

-- Queue a notification for a customer who has the app on at least one phone.
create or replace function private.push_enqueue(p_user uuid, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if p_user is null or not exists (select 1 from public.push_devices where user_id = p_user) then
    return;
  end if;
  insert into public.push_outbox (user_id, title, body, data)
  values (p_user, left(p_title, 120), left(p_body, 400), coalesce(p_data, '{}'::jsonb));
exception when others then
  raise warning 'push_enqueue failed: %', sqlerrm;
end;
$$;

-- The same words as a text, as a notification to the app of the account with that phone.
create or replace function private.push_from_sms(p_event text, p_to text, p_content text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_to    text := public.sms_normalize_phone(p_to);
  v_body  text;
  v_title text;
  v_open  text;
  v_ref   text;
  r       record;
begin
  -- Alerts for the admin and test texts are not for customers.
  if v_to is null or p_event = 'test'
     or (p_event like 'admin%' and p_event not in ('admin_message', 'admin_broadcast')) then
    return;
  end if;
  v_body := regexp_replace(coalesce(p_content, ''), '^TRU Data( admin)?:\s*', '');
  if v_body = '' then
    return;
  end if;
  v_ref := substring(p_content from 'ORD-[A-Z0-9]+');
  v_title := case p_event
    when 'order_placed'     then 'Order received'
    when 'order_processing' then 'Your order is being processed'
    when 'order_processed'  then 'Order processed'
    when 'order_delivered'  then 'Data delivered'
    when 'order_cancelled'  then 'Order cancelled'
    when 'deposit_credited' then 'Wallet credited'
    when 'deposit_rejected' then 'Deposit not confirmed'
    when 'account_locked'   then 'Account locked'
    else 'TRU Data' end;
  v_open := case when p_event like 'order%' then '#/my-orders'
                 when p_event like 'deposit%' then '#/wallet'
                 else '#/home' end;
  for r in select id from public.profiles where public.sms_normalize_phone(phone) = v_to loop
    perform private.push_enqueue(r.id, v_title, v_body,
      jsonb_strip_nulls(jsonb_build_object('kind', p_event, 'ref', v_ref, 'open', v_open)));
  end loop;
exception when others then
  raise warning 'push_from_sms(%) failed: %', p_event, sqlerrm;
end;
$$;

-- Every event text (orders, deposits, account locked) goes through sms_enqueue:
-- the notification is queued first, whether or not SMS is switched on.
create or replace function public.sms_enqueue(p_event text, p_to text, p_content text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_set private.sms_settings%rowtype;
  v_to  text;
begin
  perform private.push_from_sms(p_event, p_to, p_content);
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

-- The admin's "Send a text" (to chosen customers / numbers, or to everyone).
create or replace function private.push_on_admin_text()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if new.event in ('admin_message', 'admin_broadcast') then
    perform private.push_from_sms(new.event, new.to_phone, new.content);
  end if;
  return null;
end;
$$;

drop trigger if exists push_admin_texts on public.sms_outbox;
create trigger push_admin_texts
  after insert on public.sms_outbox
  for each row execute function private.push_on_admin_text();

-- Wake send-push (after the transaction commits; pg_net is asynchronous).
create table if not exists private.push_state (
  id        boolean primary key default true check (id),
  last_kick timestamptz not null default '-infinity'
);
insert into private.push_state (id) values (true) on conflict do nothing;
revoke all on private.push_state from public, anon, authenticated;

create or replace function private.push_kick()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare v_secret text;
begin
  -- One wake-up is enough for many notifications (a message to every customer):
  -- at most one per transaction and per 2 seconds; each run sends everything waiting.
  update private.push_state set last_kick = now() where id and last_kick < now() - interval '2 seconds';
  if not found then
    return;
  end if;
  select value into v_secret from private.secrets where key = 'push_dispatch_secret';
  perform net.http_post(
    url     := 'https://kefcmjfvrqbgtivssdwn.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000);
exception when others then
  raise warning 'push kick failed: %', sqlerrm;
end;
$$;

create or replace function private.push_kick_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  perform private.push_kick();
  return null;
end;
$$;

drop trigger if exists push_outbox_kick on public.push_outbox;
create trigger push_outbox_kick
  after insert on public.push_outbox
  for each statement execute function private.push_kick_trigger();

-- Every minute: give up on old notifications, free stuck ones, retry the rest.
create or replace function private.push_retry()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  update public.push_outbox set status = 'expired', error = coalesce(error, 'Not sent within an hour')
   where status in ('pending', 'sending') and created_at < now() - interval '1 hour';
  update public.push_outbox set status = 'pending'
   where status = 'sending' and created_at < now() - interval '5 minutes';
  if exists (select 1 from public.push_outbox where status = 'pending') then
    perform private.push_kick();
  end if;
end;
$$;

select cron.unschedule(jobid) from cron.job where jobname = 'push-retry';
select cron.schedule('push-retry', '1 minute', 'select private.push_retry()');

-- ===== For the send-push Edge Function (service role) =====
create or replace function public.push_dispatch_secret_ok(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select coalesce(p_secret, '') <> '' and p_secret = (select value from private.secrets where key = 'push_dispatch_secret');
$$;

-- Hands out waiting notifications with the phones to send them to.
create or replace function public.push_claim(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare v jsonb;
begin
  with c as (
    select id from public.push_outbox
     where status = 'pending'
     order by created_at
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  ), u as (
    update public.push_outbox o set status = 'sending', attempts = attempts + 1
      from c where o.id = c.id
    returning o.id, o.user_id, o.title, o.body, o.data
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'title', u.title, 'body', u.body, 'data', u.data,
           'tokens', coalesce((select jsonb_agg(d.token) from public.push_devices d where d.user_id = u.user_id), '[]'::jsonb))), '[]'::jsonb)
    into v from u;
  return v;
end;
$$;

create or replace function public.push_mark(p_id uuid, p_status text, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if p_status not in ('pending', 'sent', 'failed', 'no_device') then
    raise exception 'Unexpected status';
  end if;
  update public.push_outbox
     set status = case when p_status = 'pending' and attempts >= 5 then 'failed' else p_status end,
         error = left(p_error, 300),
         sent_at = case when p_status = 'sent' then now() else sent_at end
   where id = p_id;
end;
$$;

create or replace function public.push_drop_token(p_token text)
returns void
language sql
security definer
set search_path = public, private
as $$
  delete from public.push_devices where token = p_token;
$$;

revoke execute on function public.push_register(text, text, text) from public, anon;
grant execute on function public.push_register(text, text, text) to authenticated;
revoke execute on function public.push_unregister(text) from public;
grant execute on function public.push_unregister(text) to anon, authenticated;
revoke execute on function private.push_enqueue(uuid, text, text, jsonb) from public, anon, authenticated;
revoke execute on function private.push_from_sms(text, text, text) from public, anon, authenticated;
revoke execute on function private.push_on_admin_text() from public, anon, authenticated;
revoke execute on function private.push_kick() from public, anon, authenticated;
revoke execute on function private.push_kick_trigger() from public, anon, authenticated;
revoke execute on function private.push_retry() from public, anon, authenticated;
revoke execute on function public.push_dispatch_secret_ok(text) from public, anon, authenticated;
revoke execute on function public.push_claim(integer) from public, anon, authenticated;
revoke execute on function public.push_mark(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.push_drop_token(text) from public, anon, authenticated;
grant execute on function public.push_dispatch_secret_ok(text) to service_role;
grant execute on function public.push_claim(integer) to service_role;
grant execute on function public.push_mark(uuid, text, text) to service_role;
grant execute on function public.push_drop_token(text) to service_role;
