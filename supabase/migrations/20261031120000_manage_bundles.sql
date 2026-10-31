-- Bundles are managed from the admin dashboard (Bundles tab) instead of being
-- written into index.html.
--
-- public.bundles already holds the prices place_order charges; it gains the
-- validity text and a display order the shop shows, and is added to Realtime
-- so price changes reach open pages immediately. Customers only see active
-- bundles; only the admin can add, edit, hide or delete them (existing RLS).
--
-- Run AFTER 20261031090000_latest_app_release.sql.

begin;

alter table public.bundles add column if not exists validity text not null default '30 Days';
alter table public.bundles add column if not exists sort_order integer not null default 0;
alter table public.bundles add column if not exists updated_at timestamptz not null default now();

-- Order bundles by their size (1GB, 2GB, ... 100GB) to start with.
update public.bundles
set sort_order = coalesce(nullif(regexp_replace(size, '[^0-9.]', '', 'g'), '')::numeric * 10, 0)::int
where sort_order = 0;

alter table public.bundles drop constraint if exists bundles_text_check;
alter table public.bundles add constraint bundles_text_check
  check (char_length(trim(size)) between 1 and 20
     and char_length(trim(validity)) between 1 and 30
     and char_length(id) between 1 and 40);
alter table public.bundles drop constraint if exists bundles_price_max;
alter table public.bundles add constraint bundles_price_max check (price < 10000);

create or replace function public.touch_bundle()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.size := trim(new.size);
  new.validity := trim(new.validity);
  new.price := round(new.price, 2);
  return new;
end;
$$;

drop trigger if exists bundles_touch on public.bundles;
create trigger bundles_touch
  before insert or update on public.bundles
  for each row execute function public.touch_bundle();

revoke execute on function public.touch_bundle() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bundles') then
    alter publication supabase_realtime add table public.bundles;
  end if;
end;
$$;

commit;
