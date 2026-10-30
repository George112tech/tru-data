-- Manual Mobile Money deposits as the main way to fund a wallet, and Paystack
-- as an optional method the admin switches on and off.
--
-- Run AFTER 20261030130000_server_side_checkout.sql.
--
-- Flow: the customer sends MoMo to the business number using their personal
-- deposit code as the reference, then submits "I've sent the money". The
-- admin checks the MoMo statement and approves the request, which credits the
-- wallet. The admin can also credit a wallet directly by deposit code.

begin;

-- ---------------------------------------------------------------------------
-- Each customer's permanent MoMo reference, e.g. TRU4F9A2C
-- ---------------------------------------------------------------------------

alter table public.profiles add column if not exists deposit_code text;
update public.profiles
  set deposit_code = 'TRU' || upper(substr(md5(id::text), 1, 6))
  where deposit_code is null;
create unique index if not exists profiles_deposit_code_key on public.profiles (deposit_code);

create or replace function public.set_deposit_code()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.deposit_code is null then
    new.deposit_code := 'TRU' || upper(substr(md5(new.id::text), 1, 6));
  end if;
  return new;
end;
$$;

drop trigger if exists set_deposit_code on public.profiles;
create trigger set_deposit_code
  before insert on public.profiles
  for each row execute function public.set_deposit_code();

-- ---------------------------------------------------------------------------
-- "I've sent the money" requests
-- ---------------------------------------------------------------------------

create table if not exists public.deposit_requests (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  amount          numeric(10, 2) not null check (amount > 0),
  momo_txn_id     text,
  sender_phone    text,
  status          text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  credited_amount numeric(10, 2),
  admin_note      text,
  created_at      timestamptz not null default now(),
  reviewed_at     timestamptz,
  reviewed_by     uuid
);
create index if not exists deposit_requests_status_idx on public.deposit_requests (status, created_at desc);

alter table public.deposit_requests enable row level security;
drop policy if exists "Users view own deposit requests" on public.deposit_requests;
create policy "Users view own deposit requests" on public.deposit_requests
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
revoke all on public.deposit_requests from anon, authenticated;
grant select on public.deposit_requests to authenticated;

create or replace function public.submit_deposit_request(
  p_amount numeric, p_momo_txn_id text default null, p_sender_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_txn text := nullif(upper(trim(coalesce(p_momo_txn_id, ''))), '');
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'Please log in first';
  end if;
  if p_amount is null or p_amount < 5 or p_amount > 10000 then
    raise exception 'Amount must be between GHS 5 and GHS 10,000';
  end if;
  if v_txn is not null and v_txn !~ '^[A-Z0-9.\-]{4,40}$' then
    raise exception 'Enter the MoMo transaction ID exactly as it appears in your SMS';
  end if;
  if nullif(p_sender_phone, '') is not null and p_sender_phone !~ '^0[0-9]{9}$' then
    raise exception 'Enter the 10-digit number you sent from';
  end if;
  if (select count(*) from public.deposit_requests where user_id = v_uid and status = 'pending') >= 5 then
    raise exception 'You already have 5 deposits waiting for review. Please wait for them to be checked.';
  end if;
  if v_txn is not null and exists (
    select 1 from public.deposit_requests where momo_txn_id = v_txn and status <> 'rejected'
  ) then
    raise exception 'This MoMo transaction ID has already been submitted';
  end if;

  insert into public.deposit_requests (user_id, amount, momo_txn_id, sender_phone)
  values (v_uid, round(p_amount, 2), v_txn, nullif(p_sender_phone, ''))
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.submit_deposit_request(numeric, text, text) from public, anon;
grant execute on function public.submit_deposit_request(numeric, text, text) to authenticated;

-- Credits a wallet once per MoMo transaction ID (or once per request when
-- there is no transaction ID). Shared by approve and direct credit.
create or replace function public.credit_momo_deposit(
  p_user uuid, p_amount numeric, p_reference text
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_balance numeric;
begin
  insert into public.transactions (user_id, type, amount, fee, reference, status, created_at)
  values (p_user, 'deposit', p_amount, 0, p_reference, 'completed', now())
  on conflict (reference) do nothing;
  if not found then
    raise exception 'This MoMo transaction has already been credited (%)', p_reference;
  end if;

  update public.profiles set balance = coalesce(balance, 0) + p_amount, updated_at = now()
  where id = p_user
  returning balance into v_balance;
  return v_balance;
end;
$$;

revoke execute on function public.credit_momo_deposit(uuid, numeric, text) from public, anon, authenticated;

create or replace function public.approve_deposit_request(p_id uuid, p_amount numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req     public.deposit_requests%rowtype;
  v_amount  numeric;
  v_balance numeric;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;

  select * into v_req from public.deposit_requests where id = p_id for update;
  if not found then
    raise exception 'Deposit request not found';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request was already %', v_req.status;
  end if;

  v_amount := round(coalesce(p_amount, v_req.amount), 2);
  if v_amount <= 0 or v_amount > 10000 then
    raise exception 'Amount must be between GHS 0.01 and GHS 10,000';
  end if;

  v_balance := public.credit_momo_deposit(
    v_req.user_id, v_amount,
    coalesce('MOMO-' || v_req.momo_txn_id, 'MOMO-REQ-' || v_req.id::text));

  update public.deposit_requests
  set status = 'approved', credited_amount = v_amount, reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id;

  return jsonb_build_object('credited', v_amount, 'new_balance', v_balance);
end;
$$;

revoke execute on function public.approve_deposit_request(uuid, numeric) from public, anon;
grant execute on function public.approve_deposit_request(uuid, numeric) to authenticated;

create or replace function public.reject_deposit_request(p_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update public.deposit_requests
  set status = 'rejected', admin_note = left(p_note, 300), reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;
end;
$$;

revoke execute on function public.reject_deposit_request(uuid, text) from public, anon;
grant execute on function public.reject_deposit_request(uuid, text) to authenticated;

-- Admin credits a wallet directly by deposit code (no request needed).
create or replace function public.admin_credit_wallet(
  p_deposit_code text, p_amount numeric, p_momo_txn_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_txn     text := nullif(upper(trim(coalesce(p_momo_txn_id, ''))), '');
  v_balance numeric;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_profile from public.profiles where deposit_code = upper(trim(p_deposit_code));
  if not found then
    raise exception 'No customer has the reference %', upper(trim(p_deposit_code));
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 10000 then
    raise exception 'Amount must be between GHS 0.01 and GHS 10,000';
  end if;

  v_balance := public.credit_momo_deposit(
    v_profile.id, round(p_amount, 2),
    coalesce('MOMO-' || v_txn, 'MOMO-ADMIN-' || gen_random_uuid()::text));

  -- A matching pending request for the same transaction is now settled.
  if v_txn is not null then
    update public.deposit_requests
    set status = 'approved', credited_amount = round(p_amount, 2), reviewed_at = now(), reviewed_by = auth.uid()
    where momo_txn_id = v_txn and status = 'pending';
  end if;

  return jsonb_build_object('name', v_profile.full_name, 'email', v_profile.email,
                            'credited', round(p_amount, 2), 'new_balance', v_balance);
end;
$$;

revoke execute on function public.admin_credit_wallet(text, numeric, text) from public, anon;
grant execute on function public.admin_credit_wallet(text, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Paystack switch and keys
-- ---------------------------------------------------------------------------
-- The switch and public key live in app_settings (readable by everyone, that
-- is what "public" key means). The secret key lives in a private table that
-- no browser role can read; only the verify-deposit Edge Function reads it.

insert into public.app_settings (key, value) values
  ('paystack_enabled', 'false'),
  ('paystack_public_key', to_jsonb('pk_live_ea1b78f7fb20ea947f216c78e6ae3adc32d45f1b'::text))
on conflict (key) do nothing;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.secrets (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
revoke all on private.secrets from public, anon, authenticated;

create or replace function public.set_paystack_secret_key(p_secret text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if coalesce(p_secret, '') !~ '^sk_(live|test)_[A-Za-z0-9]{20,}$' then
    raise exception 'That does not look like a Paystack secret key (sk_live_... or sk_test_...)';
  end if;
  insert into private.secrets (key, value, updated_at) values ('paystack_secret_key', p_secret, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end;
$$;

-- Lets the admin page show "set, ending in ...1234" without revealing the key.
create or replace function public.paystack_secret_key_status()
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare v_row private.secrets%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_row from private.secrets where key = 'paystack_secret_key';
  if not found then
    return jsonb_build_object('set', false);
  end if;
  return jsonb_build_object('set', true, 'last4', right(v_row.value, 4),
                            'mode', case when v_row.value like 'sk_live_%' then 'live' else 'test' end,
                            'updated_at', v_row.updated_at);
end;
$$;

create or replace function public.get_paystack_secret_key()
returns text
language sql
stable
security definer
set search_path = public, private
as $$
  select value from private.secrets where key = 'paystack_secret_key';
$$;

revoke execute on function public.set_paystack_secret_key(text) from public, anon;
grant execute on function public.set_paystack_secret_key(text) to authenticated;
revoke execute on function public.paystack_secret_key_status() from public, anon;
grant execute on function public.paystack_secret_key_status() to authenticated;
revoke execute on function public.get_paystack_secret_key() from public, anon, authenticated;
grant execute on function public.get_paystack_secret_key() to service_role;

commit;
