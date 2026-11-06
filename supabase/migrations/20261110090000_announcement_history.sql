-- Announcements are kept, not deleted, when a new one is posted.
--
-- Before: posting a broadcast deleted every earlier one. Now every
-- announcement stays in the table, and exactly one (or none) is live:
-- customers see the live one. Admin -> Broadcast lists them all, and the
-- admin can post a new one, edit an old one and repost it (it goes live and
-- moves to the top), take the live one down, or delete one.

begin;

alter table public.announcements add column if not exists is_live boolean not null default false;

-- The one customers see today stays live.
update public.announcements set is_live = true
 where id = (select id from public.announcements order by created_at desc limit 1)
   and not exists (select 1 from public.announcements where is_live);

create index if not exists announcements_live_idx on public.announcements (created_at desc) where is_live;

-- Post a new announcement (p_id null) or edit and repost an old one. Either
-- way it becomes the only live one and the newest.
create or replace function public.admin_post_announcement(p_id uuid, p_main text, p_sub text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_main text := trim(coalesce(p_main, ''));
  v_sub  text := trim(coalesce(p_sub, ''));
  v_id   uuid := p_id;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  if char_length(v_main) not between 1 and 200 then
    raise exception 'The main message is needed (200 characters at most)';
  end if;
  if char_length(v_sub) > 500 then
    raise exception 'The second line is too long (500 characters at most)';
  end if;
  update public.announcements set is_live = false where is_live and id is distinct from v_id;
  if v_id is null then
    insert into public.announcements (main_message, sub_message, is_live, created_at, updated_at)
    values (v_main, v_sub, true, now(), now())
    returning id into v_id;
  else
    update public.announcements
       set main_message = v_main, sub_message = v_sub, is_live = true, created_at = now(), updated_at = now()
     where id = v_id;
    if not found then
      raise exception 'That announcement no longer exists';
    end if;
  end if;
  return v_id;
end;
$$;

-- Take the live announcement down (customers then see none).
create or replace function public.admin_take_down_announcement()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  update public.announcements set is_live = false, updated_at = now() where is_live;
end;
$$;

revoke execute on function public.admin_post_announcement(uuid, text, text) from public, anon;
grant execute on function public.admin_post_announcement(uuid, text, text) to authenticated;
revoke execute on function public.admin_take_down_announcement() from public, anon;
grant execute on function public.admin_take_down_announcement() to authenticated;

commit;
