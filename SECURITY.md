# Security fixes: deployment steps

The old app did all wallet and order logic in the browser. Anyone could open the
browser console and give themselves money, admin rights or free data. The fixes
move that logic into the database and an Edge Function.

## Deploy in this order

The new `index.html` depends on the backend changes. If you deploy it first,
purchases and deposits will break.

1. **Back up the database** (Supabase dashboard → Database → Backups).
2. **Run the migration** `supabase/migrations/20261030000000_lock_down_wallet_and_orders.sql`
   in the SQL editor. It runs as one transaction. It **drops every existing
   policy** on `profiles`, `orders`, `transactions` and replaces them with
   strict ones.
3. **Deploy the Edge Function** and set the Paystack secret:
   ```
   supabase secrets set PAYSTACK_SECRET_KEY=sk_live_...
   supabase functions deploy verify-deposit
   ```
4. **Deploy `index.html`.**
5. **Audit for past abuse.** The old holes were open to anyone, so check:
   ```sql
   -- Who is admin? Anyone unexpected here promoted themselves.
   select id, email, role from profiles where role = 'admin';
   -- Balances that don't match deposits minus purchases
   select p.email, p.balance,
          coalesce(sum(case when t.type='deposit' then t.amount else -t.amount end),0) as expected
   from profiles p left join transactions t on t.user_id = p.id
   group by p.id having p.balance <> coalesce(sum(case when t.type='deposit' then t.amount else -t.amount end),0);
   ```
   Also check `deposit` transactions against your Paystack dashboard. Deposits
   used to be recorded without verification, so fake references are possible.
6. In Supabase **Auth settings**: turn on email confirmation and set the
   minimum password length to 8. Add your site URL to the redirect allow list.

## Still to do (not covered by this change)

- Add a Paystack **webhook** to credit deposits when the user closes the tab
  before the callback fires. The `credit_deposit` function is already
  idempotent, so a webhook can safely reuse it.
- Replace the Tailwind Play CDN (`cdn.tailwindcss.com`) with a built CSS file.
  The CDN is not meant for production and forces `'unsafe-inline'` in the CSP.
- Add Subresource Integrity hashes to the pinned CDN scripts.
