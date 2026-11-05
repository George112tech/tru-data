-- Audit log: who did what, when, and from where.
--
-- Database triggers write one line for every important change, whichever way
-- it was made (the website, the app, an edge function, or the Supabase
-- dashboard). The log lives in the private schema: nobody can add, edit or
-- delete lines through the website or the API, the admin included. The admin
-- reads it with public.admin_audit_log() (Admin -> Audit log).
--
-- What is recorded:
--   money     MoMo deposit requests, approvals and rejections; wallet credits
--             and refunds; any wallet balance change that has no wallet record
--             (for example a balance edited by hand in the dashboard)
--   orders    orders placed, status changes, deletions
--   agents    applications, approvals and suspensions, withdrawals requested,
--             paid and rejected, price changes and price-change requests
--   catalog   bundles and agent base prices
--   settings  site settings (MoMo details, fees, Paystack, agent
--             deactivation), SMS settings, Paystack secret key (never the key)
--   messages  announcements, SMS sent and deleted by the admin
--   accounts  new accounts, profile changes, account deletion requests
--   security  role changes, admin sign-ins, accounts locked and unlocked,
--             password changes
--
-- Customers buying data do not add wallet lines (the order line covers it).
-- Lines older than 400 days are removed.

begin;

create schema if not exists private;

create table if not exists private.audit_log (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  actor_id      uuid,
  actor_kind    text not null,   -- admin | agent | customer | visitor | system | database
  actor_email   text,
  ip            text,
  category      text not null,
  action        text not null,
  summary       text not null,
  target_table  text,
  target_id     text,
  subject_id    uuid,            -- the customer the change is about
  subject_email text,
  details       jsonb not null default '{}'::jsonb
);
create index if not exists audit_log_at_idx on private.audit_log (at desc);
create index if not exists audit_log_category_idx on private.audit_log (category, id desc);
create index if not exists audit_log_subject_idx on private.audit_log (subject_id, id desc);
revoke all on private.audit_log from public, anon, authenticated;

-- ---------------------------------------------------------------- helpers

create or replace function private.ghs(p numeric)
returns text language sql immutable as $$
  select '₵' || to_char(coalesce(p, 0), 'FM999999990.00');
$$;

-- Fields that are never written to the log.
create or replace function private.audit_redact(p jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, case
           when k in ('r2b_api_key', 'api_key', 'dispatch_secret', 'encrypted_password')
             then case when v = 'null'::jsonb then v else to_jsonb('(hidden)'::text) end
           else v end), '{}'::jsonb)
  from jsonb_each(coalesce(p, '{}'::jsonb)) as e(k, v)
  where k not in ('api_response');
$$;

-- {"field": {"from": old, "to": new}} for every field that changed.
create or replace function private.audit_diff(p_old jsonb, p_new jsonb, p_ignore text[] default '{}')
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_object('from', o.v, 'to', n.v)), '{}'::jsonb)
  from jsonb_each(private.audit_redact(p_new)) as n(k, v)
  left join jsonb_each(private.audit_redact(p_old)) as o(k, v) using (k)
  where o.v is distinct from n.v
    and not (k = any (p_ignore || array['updated_at']));
$$;

create or replace function private.audit_email(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select email from public.profiles where id = p_user),
                  (select email from auth.users where id = p_user));
$$;

-- Add one line. Works out who is acting from the request.
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
    v_kind := case
      when v_role = 'admin' then 'admin'
      when exists (select 1 from public.agent_profiles where user_id = v_uid and status = 'active') then 'agent'
      else 'customer' end;
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
  -- The log must never stop the real change.
  raise warning 'audit_add(%) failed: %', p_action, sqlerrm;
end;
$$;
revoke all on function private.audit_add(text, text, text, text, text, uuid, text, jsonb) from public, anon, authenticated;

-- ------------------------------------------------------- the row trigger

create or replace function private.audit_row()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  o     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r     jsonb := coalesce(n, o);
  d     jsonb;
  t     text := tg_table_name;
  v_sub uuid;
  v_txt text;
  v_txt2 text;
  v_code text;
  v_tx  boolean;
begin
  d := case tg_op
         when 'UPDATE' then private.audit_diff(o, n, case t
              when 'agent_profiles' then array['total_sales', 'total_withdrawn', 'agent_profit']
              when 'orders' then array['api_response', 'retry_count']
              when 'bundles' then array['sort_order']
              when 'agent_prices' then array['final_price', 'locked']
              else '{}'::text[] end)
         else private.audit_redact(r) end;
  if tg_op = 'UPDATE' and d = '{}'::jsonb then
    return null;
  end if;

  if t = 'profiles' then
    v_sub := (r ->> 'id')::uuid;
    if tg_op = 'INSERT' then
      perform private.audit_add('accounts', 'account.created',
        'New account: ' || coalesce(r ->> 'email', '') || coalesce(' (' || nullif(r ->> 'phone', '') || ')', ''),
        t, r ->> 'id', v_sub, r ->> 'email', d);
    elsif tg_op = 'DELETE' then
      perform private.audit_add('accounts', 'account.deleted',
        'Account deleted: ' || coalesce(r ->> 'email', '') || ' (balance ' || private.ghs((r ->> 'balance')::numeric) || ')',
        t, r ->> 'id', v_sub, r ->> 'email', d);
    else
      if d ? 'role' or d ? 'is_admin' then
        perform private.audit_add('security', 'account.role_changed',
          'Role of ' || coalesce(r ->> 'email', '') || ' changed: ' || coalesce(o ->> 'role', '-') || ' → ' || coalesce(n ->> 'role', '-'),
          t, r ->> 'id', v_sub, r ->> 'email', d);
        d := d - 'role' - 'is_admin';
      end if;
      if d ? 'balance' then
        -- A wallet change with a wallet record (purchase, deposit, refund) made in
        -- the same database transaction is already covered by that record.
        select exists (select 1 from public.transactions
                        where user_id = v_sub and created_at >= now() - interval '1 second'
                          and abs(amount) = abs((n ->> 'balance')::numeric - (o ->> 'balance')::numeric))
          into v_tx;
        if not v_tx then
          perform private.audit_add('money', 'wallet.balance_edited',
            'Wallet of ' || coalesce(r ->> 'email', '') || ' changed with no wallet record: '
              || private.ghs((o ->> 'balance')::numeric) || ' → ' || private.ghs((n ->> 'balance')::numeric)
              || ' (' || case when (n ->> 'balance')::numeric >= (o ->> 'balance')::numeric then '+' else '-' end
              || private.ghs(abs((n ->> 'balance')::numeric - (o ->> 'balance')::numeric)) || ')',
            t, r ->> 'id', v_sub, r ->> 'email', jsonb_build_object('balance', d -> 'balance'));
        end if;
        d := d - 'balance';
      end if;
      d := d - 'deposit_code';
      if d <> '{}'::jsonb then
        select string_agg(k, ', ') into v_txt from jsonb_object_keys(d) k;
        perform private.audit_add('accounts', 'account.updated',
          'Account of ' || coalesce(r ->> 'email', '') || ' changed: ' || v_txt,
          t, r ->> 'id', v_sub, r ->> 'email', d);
      end if;
    end if;

  elsif t = 'orders' then
    v_sub := (r ->> 'user_id')::uuid;
    v_txt := 'Order ' || coalesce(r ->> 'ref', '') || ' (' || upper(coalesce(r ->> 'Network', '')) || ' '
             || coalesce(r ->> 'bundle_name', '') || ' to ' || coalesce(r ->> 'Phone', '') || ', '
             || private.ghs((r ->> 'Amount')::numeric) || ')';
    if tg_op = 'INSERT' then
      perform private.audit_add('orders', 'order.placed',
        v_txt || ' placed' || coalesce(' through agent ' || nullif(r ->> 'agent_code', ''), ''),
        t, r ->> 'ref', v_sub, null, d);
    elsif tg_op = 'DELETE' then
      perform private.audit_add('orders', 'order.deleted', v_txt || ' removed from the database', t, r ->> 'ref', v_sub, null, d);
    elsif d ? 'Status' or d ? 'Amount' or d ? 'agent_profit' or d ? 'user_id' then
      perform private.audit_add('orders', 'order.' || lower(coalesce(n ->> 'Status', 'updated')),
        v_txt || coalesce(': ' || (o ->> 'Status') || ' → ' || (n ->> 'Status'), ' changed'),
        t, r ->> 'ref', v_sub, null, d);
    end if;

  elsif t = 'transactions' then
    v_sub := (r ->> 'user_id')::uuid;
    if tg_op = 'INSERT' then
      if coalesce(r ->> 'type', '') = 'purchase' then
        return null;
      end if;
      perform private.audit_add('money', 'wallet.' || coalesce(r ->> 'type', 'entry'),
        case r ->> 'type'
          when 'deposit' then case when coalesce(r ->> 'reference', '') like 'MOMO-%' then 'MoMo deposit' else 'Online payment' end
          when 'refund' then 'Refund'
          else initcap(coalesce(r ->> 'type', 'Wallet entry')) end
        || ' of ' || private.ghs((r ->> 'amount')::numeric) || ' credited to ' || coalesce(private.audit_email(v_sub), 'unknown')
        || case when coalesce((r ->> 'fee')::numeric, 0) > 0 then ' (fee ' || private.ghs((r ->> 'fee')::numeric) || ')' else '' end
        || coalesce(', ref ' || (r ->> 'reference'), ''),
        t, r ->> 'id', v_sub, null, d);
    else
      perform private.audit_add('money', 'wallet.record_' || lower(tg_op) || 'd',
        'Wallet record ' || coalesce(r ->> 'reference', r ->> 'id') || ' of ' || coalesce(private.audit_email(v_sub), 'unknown')
        || case when tg_op = 'DELETE' then ' deleted' else ' edited' end,
        t, r ->> 'id', v_sub, null, d);
    end if;

  elsif t = 'deposit_requests' then
    v_sub := (r ->> 'user_id')::uuid;
    v_txt := 'MoMo deposit of ' || private.ghs((r ->> 'amount')::numeric) || ' from ' || coalesce(private.audit_email(v_sub), 'unknown')
             || coalesce(' (txn ' || nullif(r ->> 'momo_txn_id', '') || ')', '');
    if tg_op = 'INSERT' then
      perform private.audit_add('money', 'deposit.requested', v_txt || ' submitted for approval', t, r ->> 'id', v_sub, null, d);
    elsif tg_op = 'DELETE' then
      perform private.audit_add('money', 'deposit.deleted', v_txt || ' deleted', t, r ->> 'id', v_sub, null, d);
    elsif d ? 'status' then
      perform private.audit_add('money', 'deposit.' || coalesce(n ->> 'status', 'updated'),
        v_txt || ' ' || coalesce(n ->> 'status', 'updated')
        || case when n ->> 'status' = 'approved'
                then ': credited ' || private.ghs((n ->> 'credited_amount')::numeric)
                     || case when coalesce((n ->> 'fee_amount')::numeric, 0) > 0 then ' (fee ' || private.ghs((n ->> 'fee_amount')::numeric) || ')' else '' end
                else coalesce(' (' || nullif(n ->> 'admin_note', '') || ')', '') end,
        t, r ->> 'id', v_sub, null, d);
    else
      perform private.audit_add('money', 'deposit.updated', v_txt || ' edited', t, r ->> 'id', v_sub, null, d);
    end if;

  elsif t = 'agent_profiles' then
    v_sub := (r ->> 'user_id')::uuid;
    v_txt := 'Agent ' || coalesce(r ->> 'agent_id', '') || ' (' || coalesce(r ->> 'name', '') || ')';
    if tg_op = 'INSERT' then
      perform private.audit_add('agents', 'agent.applied', v_txt || ' applied to become an agent', t, r ->> 'id', v_sub, null, d);
    elsif tg_op = 'DELETE' then
      perform private.audit_add('agents', 'agent.deleted', v_txt || ' deleted', t, r ->> 'id', v_sub, null, d);
    elsif d ? 'status' then
      perform private.audit_add('agents', 'agent.' || coalesce(n ->> 'status', 'updated'),
        v_txt || ': ' || coalesce(o ->> 'status', '-') || ' → ' || coalesce(n ->> 'status', '-'), t, r ->> 'id', v_sub, null, d);
    else
      select string_agg(k, ', ') into v_txt2 from jsonb_object_keys(d) k;
      perform private.audit_add('agents', 'agent.updated', v_txt || ' changed: ' || v_txt2, t, r ->> 'id', v_sub, null, d);
    end if;

  elsif t = 'agent_withdrawals' then
    v_sub := (r ->> 'user_id')::uuid;
    v_txt := 'Withdrawal of ' || private.ghs(coalesce((r ->> 'requested_amount')::numeric, (r ->> 'amount')::numeric))
             || ' (pays ' || private.ghs(coalesce((r ->> 'net_amount')::numeric, (r ->> 'amount')::numeric)) || ' to '
             || coalesce(r ->> 'phone', '') || ' ' || upper(coalesce(r ->> 'network', '')) || ') for agent ' || coalesce(r ->> 'agent_id', '');
    if tg_op = 'INSERT' then
      perform private.audit_add('agents', 'withdrawal.requested', v_txt || ' requested', t, r ->> 'id', v_sub, null, d);
    elsif tg_op = 'DELETE' then
      perform private.audit_add('agents', 'withdrawal.deleted', v_txt || ' deleted', t, r ->> 'id', v_sub, null, d);
    elsif d ? 'status' then
      perform private.audit_add('agents', 'withdrawal.' || coalesce(n ->> 'status', 'updated'),
        v_txt || ' marked ' || coalesce(n ->> 'status', '-'), t, r ->> 'id', v_sub, null, d);
    else
      perform private.audit_add('agents', 'withdrawal.updated', v_txt || ' edited', t, r ->> 'id', v_sub, null, d);
    end if;

  elsif t = 'agent_prices' then
    if tg_op = 'UPDATE' and not (d ? 'profit' or d ? 'status' or d ? 'agent_id' or d ? 'bundle_id') then
      return null;
    end if;
    select agent_id, user_id into v_code, v_sub from public.agent_profiles where id = (r ->> 'agent_id')::uuid;
    perform private.audit_add('agents', 'agent_price.' || lower(tg_op),
      'Agent ' || coalesce(v_code, '?') || ' price for ' || upper(coalesce(r ->> 'network', '')) || ' ' || coalesce(r ->> 'bundle_name', '')
      || case tg_op
           when 'INSERT' then ': profit ' || private.ghs((r ->> 'profit')::numeric)
           when 'DELETE' then ' removed'
           else ': profit ' || private.ghs((o ->> 'profit')::numeric) || ' → ' || private.ghs((n ->> 'profit')::numeric)
                || case when d ? 'status' then ', ' || coalesce(o ->> 'status', '-') || ' → ' || coalesce(n ->> 'status', '-') else '' end
         end,
      t, r ->> 'id', v_sub, null, d);

  elsif t = 'price_unlock_requests' then
    select agent_id, user_id into v_code, v_sub from public.agent_profiles where id = (r ->> 'agent_profile_id')::uuid;
    perform private.audit_add('agents', 'price_request.' || case when tg_op = 'UPDATE' then coalesce(n ->> 'status', 'updated') else lower(tg_op) end,
      'Price-change request from agent ' || coalesce(v_code, '?')
      || case tg_op
           when 'INSERT' then coalesce(': ' || nullif(r ->> 'note', ''), '')
           when 'DELETE' then ' deleted'
           else ' ' || coalesce(n ->> 'status', 'updated') || coalesce(' for ' || nullif(n ->> 'hours', '') || ' hours', '')
         end,
      t, r ->> 'id', v_sub, null, d);

  elsif t = 'bundles' then
    v_txt := 'Bundle ' || upper(coalesce(r ->> 'network', '')) || ' ' || coalesce(r ->> 'size', '');
    perform private.audit_add('catalog', 'bundle.' || lower(tg_op),
      v_txt || case tg_op
        when 'INSERT' then ' added at ' || private.ghs((r ->> 'price')::numeric)
        when 'DELETE' then ' deleted'
        else case when d ? 'price' then ': price ' || private.ghs((o ->> 'price')::numeric) || ' → ' || private.ghs((n ->> 'price')::numeric) else '' end
          || case when d ? 'active' then case when (n ->> 'active')::boolean then ', shown' else ', hidden' end else '' end
          || case when not (d ? 'price' or d ? 'active') then ' changed' else '' end
      end,
      t, r ->> 'id', null, null, d);

  elsif t = 'agent_base_prices' then
    perform private.audit_add('catalog', 'base_price.' || lower(tg_op),
      'Agent base price ' || upper(coalesce(r ->> 'network', '')) || ' ' || coalesce(r ->> 'bundle_name', '')
      || case tg_op
        when 'INSERT' then ' added at ' || private.ghs((r ->> 'base_price')::numeric)
        when 'DELETE' then ' deleted'
        else case when d ? 'base_price' then ': ' || private.ghs((o ->> 'base_price')::numeric) || ' → ' || private.ghs((n ->> 'base_price')::numeric) else ' changed' end
          || case when d ? 'status' then ', ' || coalesce(o ->> 'status', '-') || ' → ' || coalesce(n ->> 'status', '-') else '' end
      end,
      t, r ->> 'id', null, null, d);

  elsif t = 'announcements' then
    perform private.audit_add('messages', 'announcement.' || lower(tg_op),
      'Announcement ' || case tg_op when 'INSERT' then 'posted' when 'DELETE' then 'removed' else 'edited' end
      || ': ' || left(coalesce(r ->> 'main_message', ''), 120),
      t, r ->> 'id', null, null, d);

  elsif t = 'app_settings' then
    v_code := r ->> 'key';
    v_txt := case
      when v_code = 'agent_shutdown' and tg_op = 'DELETE' then 'Agent deactivation cancelled (agent accounts on)'
      when v_code = 'agent_shutdown' and (o -> 'value' ->> 'closes_at') is not distinct from (n -> 'value' ->> 'closes_at')
        then 'Agent deactivation reminder sent again to ' || coalesce(n -> 'value' ->> 'sent', '0') || ' agents'
      when v_code = 'agent_shutdown'
        then 'Agent deactivation started: reminder texted to ' || coalesce(n -> 'value' ->> 'sent', '0') || ' agents, agent accounts close '
             || to_char((n -> 'value' ->> 'closes_at')::timestamptz at time zone 'Africa/Accra', 'FMDD Mon YYYY FMHH12:MI AM')
      when v_code = 'withdrawal_override'
        then case when (n ->> 'value') = 'true' then 'Withdrawal window opened outside normal hours' else 'Withdrawal window override removed' end
      when v_code = 'paystack_enabled'
        then case when (n ->> 'value') = 'true' then 'Online payments (Paystack) turned on' else 'Online payments (Paystack) turned off' end
      when tg_op = 'DELETE' then 'Setting ' || v_code || ' removed (was ' || coalesce(o ->> 'value', '') || ')'
      else 'Setting ' || v_code || ': ' || coalesce(o ->> 'value', '(not set)') || ' → ' || coalesce(n ->> 'value', '')
    end;
    perform private.audit_add('settings', 'setting.' || v_code, v_txt, t, v_code, null, null, d);

  elsif t = 'account_deletion_requests' then
    v_sub := (r ->> 'user_id')::uuid;
    perform private.audit_add('accounts', 'deletion.' || case when tg_op = 'UPDATE' then coalesce(n ->> 'status', 'updated') else lower(tg_op) end,
      'Account deletion request from ' || coalesce(r ->> 'email', private.audit_email(v_sub), '')
      || case tg_op
           when 'INSERT' then ' submitted' || coalesce(': ' || nullif(r ->> 'reason', ''), '')
           when 'DELETE' then ' withdrawn'
           else ' ' || coalesce(n ->> 'status', 'updated') || coalesce(' (' || nullif(n ->> 'admin_note', '') || ')', '')
         end,
      t, r ->> 'id', v_sub, r ->> 'email', d);

  elsif t = 'secrets' then
    perform private.audit_add('settings', 'secret.' || coalesce(r ->> 'key', ''),
      case when r ->> 'key' = 'paystack_secret_key' then 'Paystack secret key ' else 'Secret ' || coalesce(r ->> 'key', '') || ' ' end
      || case tg_op when 'INSERT' then 'saved' when 'DELETE' then 'removed' else 'replaced' end,
      'secrets', r ->> 'key', null, null, '{}'::jsonb);

  elsif t = 'sms_settings' then
    select string_agg(k, ', ') into v_txt from jsonb_object_keys(d) k;
    perform private.audit_add('settings', 'sms.settings',
      'SMS settings ' || case when tg_op = 'INSERT' then 'saved' else 'changed: ' || coalesce(v_txt, '') end,
      'sms_settings', null, null, null, d);

  elsif t = 'login_locks' then
    if (n ->> 'locked_until')::timestamptz > now()
       and coalesce((o ->> 'locked_until')::timestamptz, '-infinity') <= now() then
      perform private.audit_add('security', 'security.account_locked',
        'Account ' || coalesce(r ->> 'email', '') || ' locked for '
        || private.lock_text(private.lock_minutes(coalesce((n ->> 'lock_level')::int, 1))) || ' after too many wrong passwords',
        t, r ->> 'email', null, r ->> 'email', jsonb_build_object('lock_level', n -> 'lock_level', 'locked_until', n -> 'locked_until'));
    elsif tg_op = 'UPDATE' and (o ->> 'locked_until')::timestamptz > now() and n ->> 'locked_until' is null and public.is_admin() then
      perform private.audit_add('security', 'security.account_unlocked',
        'Account ' || coalesce(r ->> 'email', '') || ' unlocked by the admin', t, r ->> 'email', null, r ->> 'email', '{}'::jsonb);
    elsif d ? 'last_success_at' and public.is_admin()
          and lower(coalesce(auth.jwt() ->> 'email', '')) = r ->> 'email' then
      perform private.audit_add('security', 'security.admin_signed_in', 'Admin signed in: ' || coalesce(r ->> 'email', ''),
        t, r ->> 'email', auth.uid(), r ->> 'email', '{}'::jsonb);
    end if;
  end if;
  return null;
end;
$$;

-- ------------------------------------------------- other places to watch

-- Password and email changes (Supabase Auth's own table).
create or replace function private.audit_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password then
    perform private.audit_add('security', 'security.password_changed',
      'Password changed for ' || coalesce(new.email, ''), 'users', new.id::text, new.id, new.email, '{}'::jsonb);
  end if;
  if new.email is distinct from old.email then
    perform private.audit_add('security', 'security.email_changed',
      'Sign-in email changed: ' || coalesce(old.email, '') || ' → ' || coalesce(new.email, ''),
      'users', new.id::text, new.id, new.email, jsonb_build_object('email', jsonb_build_object('from', old.email, 'to', new.email)));
  end if;
  return null;
end;
$$;

-- SMS removed from the log by the admin: one line per action, not per text.
create or replace function private.audit_sms_deleted()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare v_n integer;
begin
  select count(*) into v_n from gone;
  if v_n > 0 and public.is_admin() then
    perform private.audit_add('messages', 'sms.deleted',
      'Deleted ' || v_n || ' SMS from the SMS log', 'sms_outbox', null, null, null, jsonb_build_object('count', v_n));
  end if;
  return null;
end;
$$;

-- The admin's own SMS: one line per send, with the message.
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
  if v_n = 0 then raise exception 'No valid Ghana phone number to send to'; end if;
  perform private.audit_add('messages', 'sms.sent',
    'SMS sent to ' || v_n || case when v_n = 1 then ' number (' || v_seen[1] || ')' else ' numbers' end || ': ' || left(v_msg, 160),
    'sms_outbox', null, null, null, jsonb_build_object('to', to_jsonb(v_seen), 'message', v_msg));
  return v_n;
end;
$function$;

-- ---------------------------------------------------------- attach them

do $$
declare t text;
begin
  foreach t in array array['orders', 'transactions', 'deposit_requests', 'agent_profiles', 'agent_withdrawals',
                           'agent_prices', 'price_unlock_requests', 'bundles', 'agent_base_prices',
                           'announcements', 'app_settings', 'account_deletion_requests'] loop
    execute format('drop trigger if exists audit_log on public.%I', t);
    execute format('create trigger audit_log after insert or update or delete on public.%I
                    for each row execute function private.audit_row()', t);
  end loop;
  foreach t in array array['secrets', 'sms_settings', 'login_locks'] loop
    execute format('drop trigger if exists audit_log on private.%I', t);
    execute format('create trigger audit_log after insert or update or delete on private.%I
                    for each row execute function private.audit_row()', t);
  end loop;
end $$;

-- Profiles: checked when the change is committed, so a purchase or deposit
-- that writes its wallet record after the balance is not reported twice.
drop trigger if exists audit_log on public.profiles;
create constraint trigger audit_log
  after insert or update or delete on public.profiles
  deferrable initially deferred
  for each row execute function private.audit_row();

drop trigger if exists audit_log_auth on auth.users;
create trigger audit_log_auth
  after update of encrypted_password, email on auth.users
  for each row execute function private.audit_auth_user();

drop trigger if exists audit_log_deleted on public.sms_outbox;
create trigger audit_log_deleted
  after delete on public.sms_outbox
  referencing old table as gone
  for each statement execute function private.audit_sms_deleted();

-- ------------------------------------------------------- reading the log

create or replace function public.admin_audit_log(
  p_category text default null,
  p_who      text default null,
  p_search   text default null,
  p_before   bigint default null,
  p_limit    integer default 50)
returns table (id bigint, at timestamptz, actor_kind text, actor_email text, ip text, category text,
               action text, summary text, target_table text, target_id text, subject_email text, details jsonb)
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  return query
    select a.id, a.at, a.actor_kind, a.actor_email, a.ip, a.category, a.action, a.summary,
           a.target_table, a.target_id, a.subject_email, a.details
      from private.audit_log a
     where (p_category is null or p_category = '' or a.category = p_category)
       and (p_who is null or p_who = '' or a.actor_kind = p_who)
       and (p_before is null or a.id < p_before)
       and (v_q is null or a.summary ilike '%' || v_q || '%' or a.actor_email ilike '%' || v_q || '%'
            or a.subject_email ilike '%' || v_q || '%' or a.target_id ilike '%' || v_q || '%' or a.ip = v_q)
     order by a.id desc
     limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;
revoke execute on function public.admin_audit_log(text, text, text, bigint, integer) from public, anon;
grant execute on function public.admin_audit_log(text, text, text, bigint, integer) to authenticated;

select private.audit_add('settings', 'audit.started', 'Audit log turned on');

commit;
