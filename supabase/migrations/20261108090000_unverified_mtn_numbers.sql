-- Unverified MTN numbers pay a fixed extra (default GHS 1.80).
--
-- A beneficiary number counts as verified once a bundle to it has been
-- delivered (Status "Completed" or "Delivered"), or when the admin marks it
-- verified. MTN bundles to any other number cost the normal price plus the
-- extra, and the customer is told delivery can take longer. Telecel and
-- AirtelTigo always pay the normal price.
--
-- place_order() adds the extra on the server, so the browser cannot skip it;
-- the order keeps it in orders.unverified_fee. Customers see the result
-- before confirming through number_status(). Admin -> Bundles: switch it on
-- and off, set the amount, and manage the verified numbers.

begin;

create table if not exists public.verified_numbers (
  phone       text primary key check (phone ~ '^0[0-9]{9}$'),
  network     text,
  source      text not null default 'admin' check (source in ('order', 'admin')),
  verified_at timestamptz not null default now(),
  verified_by uuid,
  note        text
);
alter table public.verified_numbers enable row level security;
drop policy if exists "Admins manage verified numbers" on public.verified_numbers;
create policy "Admins manage verified numbers" on public.verified_numbers
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.verified_numbers from anon;
grant select, insert, update, delete on public.verified_numbers to authenticated;

alter table public.orders add column if not exists unverified_fee numeric(10, 2) not null default 0;

-- Numbers that have already received a bundle are verified.
insert into public.verified_numbers (phone, network, source, verified_at)
select distinct on ("Phone") "Phone", lower("Network"), 'order', coalesce(updated_at, created_at, now())
  from public.orders
 where "Status" in ('Completed', 'Delivered') and "Phone" ~ '^0[0-9]{9}$'
 order by "Phone", coalesce(updated_at, created_at) asc
on conflict (phone) do nothing;

-- Settings: unverified_enabled (true/false) and unverified_surcharge (GHS 0 to 50).
insert into public.app_settings (key, value, updated_at) values
  ('unverified_enabled', 'true', now()),
  ('unverified_surcharge', '1.8', now())
on conflict (key) do nothing;

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
  if new.key = 'agent_shutdown' then
    if jsonb_typeof(new.value) <> 'object' or new.value ->> 'closes_at' is null then
      raise exception 'agent_shutdown needs a closing time';
    end if;
    perform (new.value ->> 'closes_at')::timestamptz;
  end if;
  return new;
end;
$function$;

-- The extra for this number and network (0 when it does not apply).
create or replace function private.unverified_fee(p_phone text, p_network text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
    when lower(coalesce(p_network, '')) <> 'mtn' then 0
    when coalesce((select value = 'true'::jsonb from public.app_settings where key = 'unverified_enabled'), false) = false then 0
    when exists (select 1 from public.verified_numbers where phone = p_phone) then 0
    else coalesce((select (value #>> '{}')::numeric from public.app_settings where key = 'unverified_surcharge'), 1.8)
  end;
$$;

-- What the order form shows while the customer types the number.
create or replace function public.number_status(p_phone text, p_network text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare v_fee numeric;
begin
  if auth.uid() is null then
    raise exception 'Please log in first';
  end if;
  if coalesce(p_phone, '') !~ '^0[0-9]{9}$' then
    raise exception 'Enter a valid 10-digit Ghana phone number';
  end if;
  v_fee := private.unverified_fee(p_phone, p_network);
  return jsonb_build_object(
    'applies', lower(coalesce(p_network, '')) = 'mtn'
               and coalesce((select value = 'true'::jsonb from public.app_settings where key = 'unverified_enabled'), false),
    'verified', exists (select 1 from public.verified_numbers where phone = p_phone),
    'fee', v_fee);
end;
$$;
revoke execute on function public.number_status(text, text) from public, anon;
grant execute on function public.number_status(text, text) to authenticated;

-- A delivered bundle verifies the number.
create or replace function private.verify_number_on_delivery()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."Status" in ('Completed', 'Delivered') and coalesce(old."Status", '') not in ('Completed', 'Delivered')
     and new."Phone" ~ '^0[0-9]{9}$' then
    insert into public.verified_numbers (phone, network, source)
    values (new."Phone", lower(new."Network"), 'order')
    on conflict (phone) do nothing;
  end if;
  return null;
end;
$$;
drop trigger if exists verify_number_on_delivery on public.orders;
create trigger verify_number_on_delivery
  after update of "Status" on public.orders
  for each row execute function private.verify_number_on_delivery();

-- Changes the admin makes to the list go into the audit log.
create or replace function private.audit_verified_numbers()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if tg_op = 'INSERT' and new.source = 'admin' then
    perform private.audit_add('catalog', 'number.verified', 'Number ' || new.phone || ' marked verified' || coalesce(' (' || nullif(new.note, '') || ')', ''),
      'verified_numbers', new.phone, null, null, '{}'::jsonb);
  elsif tg_op = 'DELETE' then
    perform private.audit_add('catalog', 'number.unverified', 'Number ' || old.phone || ' removed from verified numbers (now pays the unverified price)',
      'verified_numbers', old.phone, null, null, '{}'::jsonb);
  end if;
  return null;
end;
$$;
drop trigger if exists audit_log on public.verified_numbers;
create trigger audit_log
  after insert or delete on public.verified_numbers
  for each row execute function private.audit_verified_numbers();

-- place_order: the same as before, plus the unverified number extra.
create or replace function public.place_order(p_bundle_id text, p_phone text, p_agent_code text default null::text, p_request_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_bundle    public.bundles%rowtype;
  v_agent     public.agent_profiles%rowtype;
  v_base      public.agent_base_prices%rowtype;
  v_price     numeric;
  v_profit    numeric := 0;
  v_mode      text := 'system';
  v_agent_id  uuid;
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
  v_price := v_bundle.price;
  if nullif(p_agent_code, '') is not null and public.agents_phase() <> 'closed' then
    select * into v_agent from public.agent_profiles
    where agent_id = p_agent_code and status = 'active' and user_id is distinct from v_uid;
    if found then
      select * into v_base from public.agent_base_prices
      where status = 'active' and network = v_bundle.network
        and (bundle_id = v_bundle.id or bundle_name = v_bundle.size)
      order by (bundle_id = v_bundle.id) desc
      limit 1;
      if found then
        select coalesce(profit, 0) into v_profit from public.agent_prices
        where agent_id = v_agent.id and bundle_id = v_base.id and status = 'approved';
        v_profit   := coalesce(v_profit, 0);
        v_price    := v_base.base_price + v_profit;
        v_mode     := 'agent';
        v_agent_id := v_agent.id;
      end if;
    end if;
  end if;
  -- Unverified MTN number: fixed extra on top of the price (not agent profit).
  v_fee := private.unverified_fee(p_phone, v_bundle.network);
  v_price := v_price + v_fee;
  if v_balance < v_price then
    raise exception 'Insufficient balance. Please deposit funds.';
  end if;
  v_ref := 'ORD-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));
  update public.profiles set balance = balance - v_price, updated_at = now() where id = v_uid;
  insert into public.transactions (user_id, type, amount, reference, status, created_at)
  values (v_uid, 'purchase', v_price, v_ref, 'completed', now());
  insert into public.orders (
    ref, "Phone", "Network", bundle_name, "Amount", "Status", provider, user_id,
    pricing_mode, agent_id, agent_code, agent_profit, base_price_used,
    api_status, retry_count, processed_by_api, client_request_id, unverified_fee, created_at, updated_at
  ) values (
    v_ref, p_phone, v_bundle.network, v_bundle.size, v_price, 'Pending', 'patupaa', v_uid,
    v_mode, v_agent_id, case when v_agent_id is null then null else p_agent_code end,
    v_profit, v_bundle.price, 'pending', 0, false, p_request_id, v_fee, now(), now()
  );
  return jsonb_build_object('ref', v_ref, 'amount', v_price,
                            'new_balance', v_balance - v_price, 'duplicate', false,
                            'unverified_fee', v_fee);
end;
$function$;

commit;
