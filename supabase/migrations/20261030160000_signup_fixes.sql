-- Sign-up fixes.
--
--   * profiles.full_name had a UNIQUE constraint, so a second customer with
--     the same name (two "Kwame Mensah"s) could not register: sign-up failed
--     with "Database error saving new user".
--   * handle_new_user() stored a missing phone as '' and phone is UNIQUE, so a
--     second sign-up without a phone would fail the same way. Missing phones
--     are now NULL (UNIQUE allows many NULLs).
--   * Names and phones from sign-up metadata had no length limit; anything the
--     browser sent was stored and shown on the admin screens.
--
-- Run AFTER 20261030150000_close_data_leaks.sql.

begin;

alter table public.profiles drop constraint if exists profiles_full_name_key;

update public.profiles set phone = null where phone = '';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, email, balance)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
                  nullif(trim(new.raw_user_meta_data ->> 'name'), ''), 'User'), 100),
    nullif(left(trim(coalesce(new.raw_user_meta_data ->> 'phone', '')), 15), ''),
    new.email,
    0.00
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Length limits (existing data is well within them).
alter table public.profiles drop constraint if exists profiles_full_name_length;
alter table public.profiles add constraint profiles_full_name_length
  check (char_length(full_name) <= 100);
alter table public.profiles drop constraint if exists profiles_phone_length;
alter table public.profiles add constraint profiles_phone_length
  check (phone is null or char_length(phone) <= 15);
alter table public.agent_profiles drop constraint if exists agent_profiles_text_length;
alter table public.agent_profiles add constraint agent_profiles_text_length
  check (char_length(coalesce(name, '')) <= 100
     and char_length(coalesce(business_name, '')) <= 100
     and char_length(coalesce(phone, '')) <= 15);

commit;
