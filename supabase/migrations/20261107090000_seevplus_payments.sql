-- SeevPlus online payments, set up like Paystack.
--
-- The customer enters the amount to add to their wallet. The "seevplus" edge
-- function creates a SeevPlus hosted checkout on the server (the secret key
-- never reaches the browser) for deposit / (1 - fee), and sends the customer
-- to SeevPlus to pay. When they come back, or when they open their wallet
-- later, the function looks the payment up at SeevPlus and credits the wallet
-- once, through credit_deposit(), with reference SEEV-<SeevPlus reference>.
--
-- Admin -> Deposits -> SeevPlus: switch it on and off, set the fee and save
-- the secret key (stored in private.secrets, never shown again).

begin;

create table if not exists public.seev_payments (
  id              uuid primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  reference       text unique,
  deposit         numeric(12, 2) not null check (deposit > 0),
  charge          numeric(12, 2) not null check (charge >= deposit),
  fee_percent     numeric(5, 2) not null default 0,
  status          text not null default 'creating'
                  check (status in ('creating', 'pending', 'paid', 'failed', 'expired')),
  checkout_url    text,
  env             text,
  provider_status text,
  error           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  checked_at      timestamptz,
  paid_at         timestamptz
);
create index if not exists seev_payments_user_idx on public.seev_payments (user_id, created_at desc);
create index if not exists seev_payments_open_idx on public.seev_payments (status, created_at desc)
  where status in ('creating', 'pending');

alter table public.seev_payments enable row level security;
drop policy if exists "Customers see their own SeevPlus payments" on public.seev_payments;
create policy "Customers see their own SeevPlus payments" on public.seev_payments
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
-- Only the edge function (service role) writes rows.
revoke insert, update, delete on public.seev_payments from anon, authenticated;
grant select on public.seev_payments to authenticated;

-- Settings: seevplus_enabled (true/false) and seevplus_fee_percent (0 to 10).
create or replace function public.check_app_setting()
returns trigger
language plpgsql
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
  if new.key = 'agent_shutdown' then
    if jsonb_typeof(new.value) <> 'object' or new.value ->> 'closes_at' is null then
      raise exception 'agent_shutdown needs a closing time';
    end if;
    perform (new.value ->> 'closes_at')::timestamptz;
  end if;
  return new;
end;
$function$;

-- The secret key: the admin saves it, only the server can read it.
create or replace function public.set_seevplus_secret_key(p_secret text)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare v_key text := trim(coalesce(p_secret, ''));
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  -- Any printable key without spaces (SeevPlus key formats may change).
  if v_key !~ '^[!-~]{16,255}$' then
    raise exception 'That does not look like a SeevPlus API key';
  end if;
  insert into private.secrets (key, value, updated_at) values ('seevplus_secret_key', v_key, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end;
$$;

create or replace function public.seevplus_key_status()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare v_row private.secrets%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_row from private.secrets where key = 'seevplus_secret_key';
  if not found then
    return jsonb_build_object('set', false);
  end if;
  return jsonb_build_object('set', true, 'last4', right(v_row.value, 4),
    'mode', case when v_row.value ~* '(^|_)live_' then 'live' when v_row.value ~* '(^|_)test_' then 'test' else 'unknown' end,
    'updated_at', v_row.updated_at);
end;
$$;

create or replace function public.get_seevplus_secret_key()
returns text
language sql
stable
security definer
set search_path to 'public', 'private'
as $$
  select value from private.secrets where key = 'seevplus_secret_key';
$$;

revoke execute on function public.set_seevplus_secret_key(text) from public, anon;
grant execute on function public.set_seevplus_secret_key(text) to authenticated;
revoke execute on function public.seevplus_key_status() from public, anon;
grant execute on function public.seevplus_key_status() to authenticated;
revoke execute on function public.get_seevplus_secret_key() from public, anon, authenticated;
grant execute on function public.get_seevplus_secret_key() to service_role;

insert into public.app_settings (key, value, updated_at) values ('seevplus_enabled', 'false', now())
on conflict (key) do nothing;

commit;
