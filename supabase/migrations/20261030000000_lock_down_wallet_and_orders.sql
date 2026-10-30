-- TRU Data security hardening.
--
-- Moves every money-moving operation (wallet credit, wallet debit, order
-- creation) off the browser and into the database, and replaces whatever RLS
-- policies currently exist on profiles/orders/transactions with strict ones.
--
-- Run this in the Supabase SQL editor (or `supabase db push`) BEFORE deploying
-- the updated index.html. The whole script runs in one transaction: if any
-- column name differs from what the app uses, it aborts and changes nothing.

begin;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ---------------------------------------------------------------------------
-- Server-authoritative price list (the browser copy is display-only)
-- ---------------------------------------------------------------------------

create table if not exists public.bundles (
  id       text primary key,
  network  text not null check (network in ('mtn', 'airteltigo', 'telecel')),
  size     text not null,
  price    numeric(10, 2) not null check (price > 0),
  active   boolean not null default true
);

insert into public.bundles (id, network, size, price) values
  ('m-1','mtn','1GB',5.40),('m-2','mtn','2GB',10.00),('m-3','mtn','3GB',15.00),
  ('m-4','mtn','4GB',19.50),('m-5','mtn','5GB',24.50),('m-6','mtn','6GB',28.50),
  ('m-7','mtn','7GB',32.00),('m-8','mtn','8GB',37.50),('m-10','mtn','10GB',45.80),
  ('m-12','mtn','12GB',56.80),('m-15','mtn','15GB',66.50),('m-20','mtn','20GB',83.00),
  ('m-25','mtn','25GB',102.90),('m-30','mtn','30GB',125.00),('m-40','mtn','40GB',165.50),
  ('m-50','mtn','50GB',193.90),('m-100','mtn','100GB',388.90),
  ('a-1','airteltigo','1GB',6.50),('a-2','airteltigo','2GB',11.00),('a-3','airteltigo','3GB',15.50),
  ('a-4','airteltigo','4GB',20.50),('a-5','airteltigo','5GB',23.50),('a-6','airteltigo','6GB',27.00),
  ('a-7','airteltigo','7GB',32.00),('a-8','airteltigo','8GB',34.50),('a-10','airteltigo','10GB',42.50),
  ('a-15','airteltigo','15GB',64.00),('a-20','airteltigo','20GB',82.00),('a-25','airteltigo','25GB',99.90),
  ('a-30','airteltigo','30GB',118.70),('a-40','airteltigo','40GB',163.50),('a-50','airteltigo','50GB',199.90),
  ('t-10','telecel','10GB',40.00),('t-15','telecel','15GB',58.00),('t-20','telecel','20GB',78.00),
  ('t-25','telecel','25GB',99.00),('t-30','telecel','30GB',113.00),('t-40','telecel','40GB',148.00),
  ('t-50','telecel','50GB',183.00),('t-100','telecel','100GB',369.00)
on conflict (id) do update
  set network = excluded.network, size = excluded.size, price = excluded.price;

-- A Paystack reference can only ever be credited once.
create unique index if not exists transactions_reference_key
  on public.transactions (reference);

-- ---------------------------------------------------------------------------
-- Profiles are created by the database, never by the browser
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone, email, role, balance, created_at)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)), 100),
    left(coalesce(new.raw_user_meta_data ->> 'phone', ''), 15),
    new.email,
    'user',
    0,
    now()
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Row level security: drop every existing policy, then add strict ones
-- ---------------------------------------------------------------------------

do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles', 'orders', 'transactions', 'bundles')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.profiles     enable row level security;
alter table public.orders       enable row level security;
alter table public.transactions enable row level security;
alter table public.bundles      enable row level security;

create policy profiles_select on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy orders_select on public.orders
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy orders_admin_update on public.orders
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy orders_admin_delete on public.orders
  for delete to authenticated
  using (public.is_admin());

create policy transactions_select on public.transactions
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

create policy bundles_select on public.bundles
  for select to anon, authenticated
  using (active);

-- Column-level grants: RLS decides which rows, grants decide which columns.
-- Users can edit their name/phone only; balance and role are unreachable.
revoke all on public.profiles, public.orders, public.transactions, public.bundles
  from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;
grant select on public.orders to authenticated;
grant update ("Status", updated_at) on public.orders to authenticated;
grant delete on public.orders to authenticated;
grant select on public.transactions to authenticated;
grant select on public.bundles to anon, authenticated;

-- ---------------------------------------------------------------------------
-- place_order: the only way to create an order. Price comes from the bundles
-- table, and the balance row is locked so two tabs cannot double-spend.
-- ---------------------------------------------------------------------------

create or replace function public.place_order(p_bundle_id text, p_phone text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_bundle  public.bundles%rowtype;
  v_balance numeric;
  v_ref     text;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_phone !~ '^0(24|54|55|59|25|53|63|77|57|20|50|26|56|27|76|23|28|58)[0-9]{7}$' then
    raise exception 'Invalid Ghana phone number';
  end if;

  select * into v_bundle from public.bundles where id = p_bundle_id and active;
  if not found then
    raise exception 'Bundle not found';
  end if;

  select balance into v_balance from public.profiles where id = v_uid for update;
  if v_balance is null or v_balance < v_bundle.price then
    raise exception 'Insufficient balance';
  end if;

  v_ref := 'ORD-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  update public.profiles set balance = balance - v_bundle.price where id = v_uid;

  insert into public.transactions (user_id, type, amount, reference, status, created_at)
  values (v_uid, 'purchase', v_bundle.price, v_ref, 'completed', now());

  insert into public.orders (ref, "Phone", "Network", bundle_name, "Amount", "Status", user_id, created_at)
  values (v_ref, p_phone, v_bundle.network, v_bundle.size, v_bundle.price, 'Pending', v_uid, now());

  return v_ref;
end;
$$;

revoke execute on function public.place_order(text, text) from public, anon;
grant execute on function public.place_order(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- credit_deposit: called only by the verify-deposit Edge Function (service
-- role) after Paystack has confirmed the payment server-to-server.
-- ---------------------------------------------------------------------------

create or replace function public.credit_deposit(
  p_user uuid, p_reference text, p_net numeric, p_fee numeric
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.transactions (user_id, type, amount, fee, reference, status, created_at)
  values (p_user, 'deposit', p_net, p_fee, p_reference, 'completed', now())
  on conflict (reference) do nothing;

  if not found then
    return false; -- already credited
  end if;

  update public.profiles set balance = balance + p_net where id = p_user;
  return true;
end;
$$;

revoke execute on function public.credit_deposit(uuid, text, numeric, numeric)
  from public, anon, authenticated;
grant execute on function public.credit_deposit(uuid, text, numeric, numeric)
  to service_role;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

commit;
