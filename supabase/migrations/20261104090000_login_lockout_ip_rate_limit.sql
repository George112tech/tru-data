-- Account lockout + IP rate limiting for password sign-in.
--
-- How a sign-in works now:
--   1. The page calls begin_login(email). It refuses when the visitor's IP has
--      too many failed sign-ins, or the account is locked; otherwise it
--      records the attempt and says how many tries are left.
--   2. The page signs in with Supabase Auth as before, so Supabase's own
--      per-IP sign-in limit still sees each visitor's real IP.
--   3. After a successful sign-in the page calls finish_login(attempt). An
--      attempt that never succeeds counts as a failed one.
--   4. login_lock_hook (the "Custom Access Token" hook, Free plan) refuses to
--      issue a session for a locked account, even when someone calls the
--      Supabase Auth API directly.
--
-- Rules
--   Account: 5 wrong passwords lock it for 5 minutes. When the time is up the
--   person can try again; 3 more wrong passwords lock it again for longer:
--   15 min, 30 min, 1 h, 2 h, 4 h, 8 h, then 24 h each time. The person is
--   told when they can try again (the page shows a countdown). The steps go
--   back to the start after a successful sign-in, a password reset, or 24
--   hours without a lock. The owner gets an SMS when the account is locked.
--   Sessions already signed in keep working.
--   IP: 20 failed attempts in 15 minutes or 100 in 24 hours from one IP
--   address pause new attempts from it. Only failures count, so many people
--   sharing one mobile-network IP are not blocked by each other's successes.
--   Unknown emails are treated exactly like real ones (no hint whether an
--   account exists).
--
-- After running this, switch on the hook: Supabase Dashboard -> Authentication
-- -> Hooks -> Custom Access Token -> Postgres -> public.login_lock_hook.
--
-- Run AFTER 20261102170000_online_payment_sms.sql.

begin;

create schema if not exists private;

create table if not exists private.login_attempts (
  id           uuid primary key default gen_random_uuid(),
  email        text not null,
  ip           text,
  created_at   timestamptz not null default now(),
  succeeded_at timestamptz
);
create index if not exists login_attempts_email_idx on private.login_attempts (email, created_at desc);
create index if not exists login_attempts_ip_idx on private.login_attempts (ip, created_at desc) where succeeded_at is null;

create table if not exists private.login_locks (
  email           text primary key,
  locked_until    timestamptz,
  lock_level      integer not null default 0,
  last_locked_at  timestamptz,
  last_success_at timestamptz,
  updated_at      timestamptz not null default now()
);

revoke all on private.login_attempts, private.login_locks from public, anon, authenticated;

-- The visitor's IP address as seen by the API gateway (Cloudflare sets
-- cf-connecting-ip, which a visitor cannot fake).
create or replace function private.client_ip()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(trim(coalesce(
           h ->> 'cf-connecting-ip',
           h ->> 'x-real-ip',
           split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1))), '')
  from (select coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json as h) x;
$$;

-- How long the Nth lock lasts.
create or replace function private.lock_minutes(p_level integer)
returns integer
language sql
immutable
as $$
  select (array[5, 15, 30, 60, 120, 240, 480, 1440])[least(greatest(p_level, 1), 8)];
$$;

create or replace function private.lock_text(p_minutes integer)
returns text
language sql
immutable
as $$
  select case when p_minutes >= 60 and p_minutes % 60 = 0
              then (p_minutes / 60) || case when p_minutes = 60 then ' hour' else ' hours' end
              else p_minutes || ' minutes' end;
$$;

create or replace function private.minutes_until(p_at timestamptz)
returns integer
language sql
stable
as $$
  select greatest(1, ceil(extract(epoch from (p_at - now())) / 60)::integer);
$$;

-- Step 1: may this sign-in go ahead?
create or replace function public.begin_login(p_email text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, private
as $$
declare
  v_email   text := lower(trim(coalesce(p_email, '')));
  v_ip      text := private.client_ip();
  v_lock    private.login_locks%rowtype;
  v_since   timestamptz;
  v_fail    integer;
  v_ip15    integer;
  v_ip24    integer;
  v_level   integer;   -- locks so far in this streak
  v_max     integer;   -- wrong passwords allowed before the next lock
  v_until   timestamptz;
  v_uid     uuid;
  v_id      uuid;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(v_email) > 254 then
    raise exception 'Enter a valid email address';
  end if;

  -- Old attempts are only needed for 24 hours.
  if random() < 0.05 then
    delete from private.login_attempts where created_at < now() - interval '2 days';
  end if;

  -- IP rate limit (failed attempts only).
  if v_ip is not null then
    select count(*) filter (where created_at > now() - interval '15 minutes'),
           count(*)
      into v_ip15, v_ip24
      from private.login_attempts
     where ip = v_ip and succeeded_at is null and created_at > now() - interval '24 hours';
    if v_ip15 >= 20 or v_ip24 >= 100 then
      return jsonb_build_object('ok', false, 'reason', 'ip_limited',
        'retry_after_minutes', case when v_ip15 >= 20 then 15 else 60 end,
        'message', 'Too many failed sign-in attempts from your network. Please wait ' ||
                   case when v_ip15 >= 20 then '15 minutes' else 'an hour' end || ' and try again.');
    end if;
  end if;

  select * into v_lock from private.login_locks where email = v_email for update;

  if found and v_lock.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'locked', 'retry_at', v_lock.locked_until,
      'retry_after_seconds', ceil(extract(epoch from (v_lock.locked_until - now())))::integer,
      'message', 'Too many wrong passwords. You can try again in ' || private.minutes_until(v_lock.locked_until) ||
                 ' minute(s), or use "Forgot password?" to unlock your account now.');
  end if;

  -- The streak of locks ends after 24 hours without one.
  v_level := case when v_lock.last_locked_at > now() - interval '24 hours' then coalesce(v_lock.lock_level, 0) else 0 end;
  v_max := case when v_level = 0 then 5 else 3 end;

  -- Failed attempts since the last success / lock, within 15 minutes.
  v_since := greatest(now() - interval '15 minutes',
                      coalesce(v_lock.last_success_at, '-infinity'),
                      coalesce(v_lock.locked_until, '-infinity'));
  select count(*) into v_fail
    from private.login_attempts
   where email = v_email and succeeded_at is null and created_at > v_since;

  if v_fail >= v_max then
    v_level := v_level + 1;
    v_until := now() + make_interval(mins => private.lock_minutes(v_level));
    insert into private.login_locks (email, locked_until, lock_level, last_locked_at, updated_at)
    values (v_email, v_until, v_level, now(), now())
    on conflict (email) do update
      set locked_until = excluded.locked_until, lock_level = excluded.lock_level,
          last_locked_at = excluded.last_locked_at, updated_at = now();

    -- Tell the owner (if this is a real account with a phone number).
    select id into v_uid from auth.users where lower(email) = v_email limit 1;
    if v_uid is not null then
      perform public.sms_enqueue('account_locked', public.sms_customer_phone(v_uid, null),
        'TRU Data: Your account was locked for ' || private.lock_text(private.lock_minutes(v_level)) ||
        ' after too many wrong passwords. If this was not you, reset your password on the TRU Data site.');
    end if;

    return jsonb_build_object('ok', false, 'reason', 'locked', 'retry_at', v_until,
      'retry_after_seconds', private.lock_minutes(v_level) * 60,
      'message', 'Too many wrong passwords. Your account is locked for ' || private.lock_text(private.lock_minutes(v_level)) ||
                 '. You can try again when the time is up, or use "Forgot password?" to unlock it now.');
  end if;

  insert into private.login_attempts (email, ip) values (v_email, v_ip) returning id into v_id;
  return jsonb_build_object('ok', true, 'attempt', v_id,
    'attempts_left_after_failure', v_max - v_fail - 1,
    'next_lock', private.lock_text(private.lock_minutes(v_level + 1)));
end;
$$;

-- Step 3: the sign-in worked.
create or replace function public.finish_login(p_attempt uuid default null)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, private
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null or v_email = '' then
    return false;
  end if;
  if p_attempt is not null then
    update private.login_attempts set succeeded_at = now()
     where id = p_attempt and email = v_email and succeeded_at is null
       and created_at > now() - interval '10 minutes';
  end if;
  insert into private.login_locks (email, last_success_at, lock_level, updated_at)
  values (v_email, now(), 0, now())
  on conflict (email) do update
    set last_success_at = now(), lock_level = 0, locked_until = null, updated_at = now();
  return true;
end;
$$;

revoke execute on function public.begin_login(text) from public;
grant execute on function public.begin_login(text) to anon, authenticated;
revoke execute on function public.finish_login(uuid) from public, anon;
grant execute on function public.finish_login(uuid) to authenticated;

-- A new password (reset or change) unlocks the account.
create or replace function private.unlock_on_password_change()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password and new.email is not null then
    insert into private.login_locks (email, last_success_at, lock_level, updated_at)
    values (lower(new.email), now(), 0, now())
    on conflict (email) do update
      set locked_until = null, lock_level = 0, last_success_at = now(), updated_at = now();
  end if;
  return new;
end;
$$;
drop trigger if exists unlock_login_on_password_change on auth.users;
create trigger unlock_login_on_password_change
  after update of encrypted_password on auth.users
  for each row execute function private.unlock_on_password_change();

-- Step 4: Supabase Auth asks this before issuing a session ("Custom Access
-- Token" hook). Password sign-ins to a locked account are refused, wherever
-- they come from. Refreshing an existing session, password-reset links and
-- sign-ups are never blocked.
create or replace function public.login_lock_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_until timestamptz;
begin
  if coalesce(event ->> 'authentication_method', '') <> 'password' then
    return event;
  end if;
  select locked_until into v_until from private.login_locks
   where email = lower(coalesce(event -> 'claims' ->> 'email', ''));
  if v_until > now() then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 429,
      'message', 'Too many wrong passwords. You can try again in ' || private.minutes_until(v_until) ||
                 ' minute(s), or use "Forgot password?" to unlock your account now.'));
  end if;
  return event;
end;
$$;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.login_lock_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.login_lock_hook(jsonb) from public, anon, authenticated;

-- Admin: see and clear locks.
create or replace function public.admin_login_security()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  return jsonb_build_object(
    'locked', coalesce((select jsonb_agg(jsonb_build_object('email', email, 'locked_until', locked_until,
                        'lock_level', lock_level) order by locked_until desc)
                        from private.login_locks where locked_until > now()), '[]'::jsonb),
    'failed_24h', (select count(*) from private.login_attempts
                    where succeeded_at is null and created_at > now() - interval '24 hours'),
    'busy_ips', coalesce((select jsonb_agg(x order by (x ->> 'failed')::int desc) from (
                   select jsonb_build_object('ip', ip, 'failed', count(*), 'last', max(created_at)) as x
                     from private.login_attempts
                    where succeeded_at is null and ip is not null and created_at > now() - interval '24 hours'
                    group by ip having count(*) >= 10) s), '[]'::jsonb));
end;
$$;

create or replace function public.admin_unlock_login(p_email text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update private.login_locks
     set locked_until = null, lock_level = 0, last_success_at = now(), updated_at = now()
   where email = lower(trim(p_email));
end;
$$;

revoke execute on function public.admin_login_security() from public, anon;
grant execute on function public.admin_login_security() to authenticated;
revoke execute on function public.admin_unlock_login(text) from public, anon;
grant execute on function public.admin_unlock_login(text) to authenticated;

commit;
