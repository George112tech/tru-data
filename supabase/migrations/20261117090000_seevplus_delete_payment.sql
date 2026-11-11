-- Admin: delete a SeevPlus payment record from the dashboard list.
--
-- Deleting only removes the record from the SeevPlus list. A wallet credit
-- already made stays (it is in the customer's transactions), and a deleted
-- record cannot be credited again: SeevPlus webhooks and checks for it find
-- nothing and do nothing.
--
-- A payment still waiting for SeevPlus ('creating' / 'pending') can be
-- deleted only once it is more than a day old, so a payment the customer is
-- still making is not lost. Each deletion is written to the audit log.

create or replace function public.admin_delete_seev_payment(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_row public.seev_payments%rowtype;
  v_email text;
begin
  if not public.is_admin() then
    raise exception 'Admin access only';
  end if;
  select * into v_row from public.seev_payments where id = p_id for update;
  if not found then
    raise exception 'Payment not found';
  end if;
  if v_row.status in ('creating', 'pending') and v_row.created_at > now() - interval '24 hours' then
    raise exception 'This payment is still waiting for SeevPlus. Tap Check first, or delete it after a day.';
  end if;

  delete from public.seev_payments where id = p_id;

  select email into v_email from public.profiles where id = v_row.user_id;
  perform private.audit_add('money', 'seevplus.payment_deleted',
    'SeevPlus payment record deleted: ' || private.ghs(v_row.deposit) || ' (' || v_row.status || ')'
      || coalesce(' ' || v_row.reference, ''),
    'seev_payments', p_id::text, v_row.user_id, v_email,
    jsonb_build_object('reference', v_row.reference, 'status', v_row.status,
      'deposit', v_row.deposit, 'charge', v_row.charge, 'created_at', v_row.created_at));
  return jsonb_build_object('deleted', true);
end;
$$;

revoke execute on function public.admin_delete_seev_payment(uuid) from public, anon;
grant execute on function public.admin_delete_seev_payment(uuid) to authenticated;
