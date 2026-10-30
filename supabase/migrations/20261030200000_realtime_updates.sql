-- Live updates: the page subscribes to these tables through Supabase Realtime,
-- so customers, agents and the admin see changes (order status, wallet
-- balance, deposit and withdrawal decisions, price-change answers, ...) without
-- refreshing.
--
-- Realtime applies each table's row level security per subscriber: a customer
-- only receives their own orders, an agent only their own requests, and so on.
--
-- Run AFTER 20261030190000_sms_notifications.sql.

do $$
declare
  t text;
begin
  foreach t in array array[
    'orders', 'profiles', 'transactions', 'deposit_requests', 'agent_profiles',
    'agent_prices', 'agent_base_prices', 'agent_withdrawals', 'price_unlock_requests',
    'announcements', 'app_settings', 'sms_outbox'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end;
$$;
