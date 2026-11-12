-- Refuse sign-ups (and email changes) with throwaway email addresses.
--
-- A security scanner signed up as ghostkefcmjfv@mailinator.com straight
-- through the Supabase sign-up API (not the site's form). Throwaway inboxes
-- like mailinator.com can be read by anyone, so they are only used by bots
-- and people who do not want to be reached.
--
-- The check is a trigger on auth.users, so it applies however the sign-up
-- arrives (the site, the app or a direct API call). Subdomains count too
-- (x.mailinator.com). The admin can add or remove domains:
--   insert into private.blocked_email_domains (domain) values ('example.com');
--   delete from private.blocked_email_domains where domain = 'example.com';

create table if not exists private.blocked_email_domains (
  domain     text primary key check (domain = lower(domain) and domain !~ '\s'),
  created_at timestamptz not null default now()
);
revoke all on private.blocked_email_domains from public, anon, authenticated;

insert into private.blocked_email_domains (domain) values
  ('mailinator.com'), ('mailinator.net'), ('mailinator.org'), ('mailinator2.com'),
  ('guerrillamail.com'), ('guerrillamail.net'), ('guerrillamail.org'), ('guerrillamail.biz'),
  ('guerrillamail.de'), ('guerrillamailblock.com'), ('sharklasers.com'), ('grr.la'),
  ('pokemail.net'), ('spam4.me'), ('10minutemail.com'), ('10minutemail.net'),
  ('10minemail.com'), ('20minutemail.com'), ('tempmail.com'), ('temp-mail.org'),
  ('temp-mail.io'), ('tempmail.net'), ('tempmailo.com'), ('tempmail.dev'),
  ('tempail.com'), ('tempr.email'), ('discard.email'), ('discardmail.com'),
  ('yopmail.com'), ('yopmail.net'), ('yopmail.fr'), ('cool.fr.nf'),
  ('jetable.fr.nf'), ('nospam.ze.tc'), ('trashmail.com'), ('trashmail.net'),
  ('trashmail.de'), ('trash-mail.com'), ('getnada.com'), ('nada.email'),
  ('dispostable.com'), ('maildrop.cc'), ('mailnesia.com'), ('mailcatch.com'),
  ('mintemail.com'), ('mohmal.com'), ('emailondeck.com'), ('fakeinbox.com'),
  ('fakemail.net'), ('throwawaymail.com'), ('getairmail.com'), ('mailpoof.com'),
  ('moakt.com'), ('mytemp.email'), ('burnermail.io'), ('spamgourmet.com'),
  ('mailsac.com'), ('inboxkitten.com'), ('emailfake.com'), ('email-fake.com'),
  ('fakemailgenerator.com'), ('armyspy.com'), ('cuvox.de'), ('dayrep.com'),
  ('einrot.com'), ('fleckens.hu'), ('gustr.com'), ('jourrapide.com'),
  ('rhyta.com'), ('superrito.com'), ('teleworm.us'), ('1secmail.com'),
  ('1secmail.net'), ('1secmail.org'), ('kzccv.com'), ('qiott.com'),
  ('wuuvo.com'), ('icznn.com'), ('ezztt.com'), ('vjuum.com'),
  ('laafd.com'), ('txcct.com'), ('linshiyouxiang.net'), ('33mail.com'),
  ('anonaddy.me'), ('spambox.us'), ('mailtemp.info'), ('tmpmail.org'),
  ('tmpmail.net'), ('tmails.net'), ('emltmp.com'), ('dropmail.me'),
  ('minuteinbox.com'), ('harakirimail.com'), ('mvrht.net'), ('byom.de')
on conflict (domain) do nothing;

create or replace function private.refuse_disposable_email()
returns trigger
language plpgsql
security definer
set search_path = private, public
as $$
declare
  v_domain text := lower(split_part(coalesce(new.email, ''), '@', 2));
begin
  if v_domain <> '' and exists (
       select 1 from private.blocked_email_domains d
        where v_domain = d.domain or v_domain like '%.' || d.domain) then
    raise exception 'Please use your real email address. Temporary email addresses are not accepted.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function private.refuse_disposable_email() from public, anon, authenticated;

drop trigger if exists refuse_disposable_email on auth.users;
create trigger refuse_disposable_email
  before insert or update of email on auth.users
  for each row execute function private.refuse_disposable_email();
