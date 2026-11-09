-- Guest checkout: a paid guest payment always becomes its order.
--
-- Until now the order was made only when the customer's own browser, after
-- Paystack's popup, called the guest-checkout function. If the customer
-- closed the popup while approving the MoMo prompt, lost connection, or left
-- the page, the payment stayed 'pending' and no order appeared for the admin.
--
-- Now two more routes reach guest_complete(), both on the server:
--   1. Paystack's webhook (the paystack-webhook function) on charge.success.
--   2. guest-checkout with { reconcile: true }, run when an admin opens the
--      dashboard: it asks Paystack about every pending guest payment from the
--      last 3 days and completes the paid ones.
--
-- This migration adds the two helpers those use (service_role only):
--   guest_pending_references(days)  the references to check
--   guest_mark_unpaid(ref, status)  stops checking a payment Paystack says
--                                   failed or was abandoned (after 24 h)

alter table private.guest_checkouts drop constraint if exists guest_checkouts_status_check;
alter table private.guest_checkouts
  add constraint guest_checkouts_status_check
  check (status in ('pending', 'paid', 'underpaid', 'failed', 'abandoned', 'reversed'));

create or replace function public.guest_pending_references(p_days int default 3)
returns setof text
language sql
stable
security definer
set search_path = public, private
as $$
  select reference
    from private.guest_checkouts
   where status = 'pending'
     and created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 3), 14)))
   order by created_at desc
   limit 100;
$$;

create or replace function public.guest_mark_unpaid(p_reference text, p_status text)
returns boolean
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if p_status not in ('failed', 'abandoned', 'reversed') then
    raise exception 'Unexpected status';
  end if;
  -- Only a payment still pending after a day: a MoMo approval can take a while.
  update private.guest_checkouts
     set status = p_status
   where reference = p_reference
     and status = 'pending'
     and created_at < now() - interval '24 hours';
  return found;
end;
$$;

revoke execute on function public.guest_pending_references(int) from public, anon, authenticated;
revoke execute on function public.guest_mark_unpaid(text, text) from public, anon, authenticated;
grant execute on function public.guest_pending_references(int) to service_role;
grant execute on function public.guest_mark_unpaid(text, text) to service_role;
