-- Remove what is left of the agent feature.
--
-- The agent tables, columns, settings and texts were removed on 9 Nov
-- (20261109090000_remove_agents.sql). What remained:
--   * place_order still took a p_agent_code argument (always null) and set
--     orders.pricing_mode, which is 'system' on every order since then.
--   * The audit log trigger still had branches for the deleted agent tables
--     and the agent deactivation setting.
--   * approve_account_deletion still returned 'orders_kept_for_agents'.
--   * One old audit entry is marked as made by an 'agent' (agents were
--     customer accounts).
--
-- Run this AFTER the site version that no longer sends p_agent_code (and no
-- longer reads orders.pricing_mode) is live.

begin;

-- 1. place_order without the agent argument and without pricing_mode.
drop function if exists public.place_order(text, text, text, uuid);
create function public.place_order(p_bundle_id text, p_phone text, p_request_id uuid default null::uuid)
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
  v_quote     jsonb;
  v_fee       numeric := 0;
  v_combo     text;
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
                                'unverified_fee', v_existing.unverified_fee,
                                'unverified_combo', v_existing.unverified_combo);
    end if;
  end if;
  if coalesce(p_phone, '') !~ '^0(24|54|55|59|25|53|63|77|57|20|50|26|56|27|76|23|28|58)[0-9]{7}$' then
    raise exception 'Enter a valid 10-digit Ghana phone number';
  end if;
  select * into v_bundle from public.bundles where id = p_bundle_id and active;
  if not found then
    raise exception 'Bundle not found';
  end if;
  -- Unverified MTN number: this bundle's extra, or two bundles for a combo.
  v_quote := private.unverified_quote(p_phone, v_bundle.id);
  v_fee   := coalesce((v_quote ->> 'fee')::numeric, 0);
  v_combo := v_quote ->> 'combo';
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
    base_price_used, api_status, retry_count, processed_by_api,
    client_request_id, unverified_fee, unverified_combo, created_at, updated_at
  ) values (
    v_ref, p_phone, v_bundle.network, v_bundle.size, v_price, 'Pending', 'patupaa', v_uid,
    v_bundle.price, 'pending', 0, false, p_request_id, v_fee, v_combo, now(), now()
  );
  return jsonb_build_object('ref', v_ref, 'amount', v_price,
                            'new_balance', v_balance - v_price, 'duplicate', false,
                            'unverified_fee', v_fee, 'unverified_combo', v_combo);
end;
$function$;
revoke execute on function public.place_order(text, text, uuid) from public, anon;
grant execute on function public.place_order(text, text, uuid) to authenticated, service_role;

-- 2. Agent pricing is gone: every order is priced by the shop.
alter table public.orders drop column if exists pricing_mode;

-- 3. Account deletion: no agent field in the answer.
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

  return jsonb_build_object('deleted', true, 'balance_forfeited', v_balance);
end;
$function$;

-- 4. The audit log trigger, without the agent tables and the agent settings.
create or replace function private.audit_row()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  o     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r     jsonb := coalesce(n, o);
  d     jsonb;
  t     text := tg_table_name;
  v_sub uuid;
  v_txt text;
  v_code text;
  v_tx  boolean;
begin
  d := case tg_op
         when 'UPDATE' then private.audit_diff(o, n, case t
              when 'orders' then array['api_response', 'retry_count']
              when 'bundles' then array['sort_order']
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
      perform private.audit_add('orders', 'order.placed', v_txt || ' placed', t, r ->> 'ref', v_sub, null, d);
    elsif tg_op = 'DELETE' then
      perform private.audit_add('orders', 'order.deleted', v_txt || ' removed from the database', t, r ->> 'ref', v_sub, null, d);
    elsif d ? 'Status' or d ? 'Amount' or d ? 'user_id' then
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

  elsif t = 'announcements' then
    perform private.audit_add('messages', 'announcement.' || lower(tg_op),
      'Announcement ' || case tg_op when 'INSERT' then 'posted' when 'DELETE' then 'removed' else 'edited' end
      || ': ' || left(coalesce(r ->> 'main_message', ''), 120),
      t, r ->> 'id', null, null, d);

  elsif t = 'app_settings' then
    v_code := r ->> 'key';
    v_txt := case
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
$function$;

-- 5. Agents were customer accounts.
update private.audit_log set actor_kind = 'customer' where actor_kind = 'agent';

commit;
