# Security and payment fixes: deployment

Wallet balances, deposits, orders, agent markups and withdrawals used to be
written straight from the browser. Anyone could open the browser console and
change their own balance, credit a deposit without paying, buy data at any
price, approve themselves as an agent, or make themselves admin. All of that
now happens in the database or in Edge Functions, and the page only asks.

## Deploy in this order, back to back

Between steps 2 and 5, the old page on GitHub Pages can no longer take money,
so do them together. If a customer pays on Paystack in that gap, their wallet
won't be credited automatically: check the Paystack dashboard afterwards.

1. **Back up the database** (Supabase → Database → Backups).
2. **Add the Paystack secret key**: Supabase → Edge Functions → Secrets →
   `PAYSTACK_SECRET_KEY` = your `sk_live_...` key. Never put it in the page.
3. **Run the two migrations, in order**, in the SQL Editor:
   - `supabase/migrations/20261030120000_emergency_lockdown.sql`
   - `supabase/migrations/20261030130000_server_side_checkout.sql`
4. **Deploy the Edge Functions**:
   - `verify-deposit` (new): confirms deposits with Paystack
   - `process-order` (updated): only sends paid orders, each one once
   - `r2b-proxy` (updated): admin only
5. **Merge this branch into `master`** so GitHub Pages serves the new `index.html`.

## What changed

| Area | Before | After |
|---|---|---|
| Wallet balance, role | Any user could set their own (profiles had no RLS) | Only server functions change them |
| Deposits | Browser recorded the deposit itself | `verify-deposit` asks Paystack, credits each reference once |
| Purchases | Browser debited itself, then saved the order; repeated taps charged repeatedly | `place_order()` prices, debits and saves in one step; repeated taps return the same order |
| Refer2Bundle | Any signed-in user could order any data for free | `process-order` reads the paid order; owner or admin only; once per order |
| Order delete | Deleted the row, no refund | Cancels and refunds the wallet (admin chooses) |
| Agent approval and totals | Agents could approve themselves and edit totals | Admin only (database trigger) |
| Agent markups | One agent saving a price locked it for every agent | Each agent's lock is their own; admin lock or unlock applies to all |
| Withdrawals | Insert crashed (uuid = text); paid amounts counted twice; window override only in the admin's browser | Fixed trigger; server checks profit, window and pending requests; shared override |
| Phone numbers | MoMo and agent numbers lost their leading 0 | Stored as text |
| Announcements | Old ones were never cleared | Clearing works |
| XSS | Order, agent and announcement data put into the page unescaped | Escaped everywhere; order refs passed via `data-` attributes |
| Password reset | Link logged you in with no way to set a password | Shows a "Set New Password" form |

## Still worth doing

- Add a Paystack **webhook** so deposits are credited even if the customer
  closes the page before the callback runs (`credit_deposit` is already safe
  to call twice).
- Replace the Tailwind CDN script with a built CSS file (the CDN isn't meant
  for production).
- In Supabase Auth settings, turn on leaked-password protection and set the
  minimum password length to 8.
