# Security and payment fixes: deployment

Wallet balances, deposits, orders, agent markups and withdrawals used to be
written straight from the browser. Anyone could open the browser console and
change their own balance, credit a deposit without paying, buy data at any
price, approve themselves as an agent, or make themselves admin. All of that
now happens in the database or in Edge Functions, and the page only asks.

## Deploy in this order, back to back

Between steps 2 and 4, the old page can no longer take money, so do them
together. If a customer pays on Paystack in that gap, their wallet won't be
credited automatically: check the Paystack dashboard afterwards.

1. **Back up the database** (Supabase → Database → Backups).
2. **Run the three migrations, in order**, in the SQL Editor:
   - `supabase/migrations/20261030120000_emergency_lockdown.sql`
   - `supabase/migrations/20261030130000_server_side_checkout.sql`
   - `supabase/migrations/20261030140000_momo_deposits_and_paystack_toggle.sql`
3. **Deploy the Edge Functions**:
   - `verify-deposit` (new): confirms Paystack deposits
   - `process-order` and `r2b-proxy`: replaced with disabled stubs (the
     Refer2Bundle API is no longer used). Delete them from the dashboard and
     remove the `REFER2BUNDLE_API_KEY` secret when convenient.
4. **Publish the new `index.html`**: merge this branch into `main` and point
   GitHub Pages at `main` (Settings → Pages → Branch: `main`, `/ (root)`).

## Deposits

Mobile Money is the default. Each customer has a permanent reference such as
`TRU4F9A2C`, shown on their wallet page along with the number 0505175472 and
the name GEORGE DANQUAH DORDZIE. They send the money, then tap "I've Sent the
Money" with the amount and MoMo transaction ID.

In the admin dashboard, the **Deposits** tab lists those requests. Check each
one against your MoMo statement, then **Approve** (you can change the amount
if a different amount arrived) or **Reject**. You can also credit any wallet
directly with **Credit a wallet by reference**. A MoMo transaction ID can only
be credited once.

Paystack is **off** by default. To turn it on, open Deposits → Paystack, save
your public key (`pk_live_...`) and secret key (`sk_live_...`), then press
**Turn On**. The secret key is stored in a private table that browsers can't
read; only the `verify-deposit` function uses it. Payments made just before
you switch Paystack off are still credited.

## SMS notifications (httpSMS)

Customers, agents and the admin get text messages for orders, deposits,
withdrawals, agent applications and price-change requests. They are sent
through [httpSMS](https://httpsms.com), which sends each text from an Android
phone running the httpSMS app, using that phone's SIM.

1. Run `supabase/migrations/20261030190000_sms_notifications.sql` in the SQL
   Editor. It turns on the `pg_net` extension.
2. Deploy the `send-sms` Edge Function with **Verify JWT turned off**. The
   database calls it with its own secret header.
3. On the Android phone, install the httpSMS app from httpsms.com and sign in.
   Copy your API key from httpsms.com → Settings.
4. In the admin dashboard, open **SMS**. Paste the API key, enter the sending
   phone's number and your admin alert number, tick the events you want, turn
   SMS on and save. Then use **Send a test SMS**.

Texts are queued in `sms_outbox`. The SMS tab shows the last 50, with a
**Retry** button on failed ones. If texting fails, the order, deposit or other
action still goes through. Customers get texts at their profile phone; for
orders, if there is no profile phone, the text goes to the number the bundle
was sent to. The API key is stored in a private table that browsers can't
read.

## Live updates

The page subscribes to database changes through Supabase Realtime, so new
orders, status changes, wallet credits and the admin's decisions appear for
everyone without refreshing. Run
`supabase/migrations/20261030200000_realtime_updates.sql` once in the SQL
Editor to switch it on. Each person only receives rows that row level security
already lets them read. Until it is run, or if the connection drops, the page
checks for changes every 30 seconds and whenever it comes back into view.

## What changed

| Area | Before | After |
|---|---|---|
| Wallet balance, role | Any user could set their own (profiles had no RLS) | Only server functions change them |
| Deposits | Browser recorded the deposit itself | Mobile Money with admin approval; optional Paystack checked server-side; each payment credited once |
| Purchases | Browser debited itself, then saved the order; repeated taps charged repeatedly | `place_order()` prices, debits and saves in one step; repeated taps return the same order |
| Refer2Bundle API | Any signed-in user could order any data for free | Removed. Orders stay Pending; the admin fulfils them on patupaa.com |
| Order delete | Deleted the row, no refund | Cancels and refunds the wallet (admin chooses) |
| Agent approval and totals | Agents could approve themselves and edit totals | Admin only (database trigger) |
| Agent markups | One agent saving a price locked it for every agent | Each agent's lock is their own; admin lock or unlock applies to all |
| Withdrawals | Insert crashed (uuid = text); paid amounts counted twice; window override only in the admin's browser | Fixed trigger; server checks profit, window and pending requests; shared override |
| Phone numbers | MoMo and agent numbers lost their leading 0 | Stored as text |
| Announcements | Old ones were never cleared | Clearing works |
| XSS | Order, agent and announcement data put into the page unescaped | Escaped everywhere; order refs passed via `data-` attributes |
| Password reset | Link logged you in with no way to set a password | Shows a "Set New Password" form |

## Still worth doing

- If you use Paystack, add a **webhook** so deposits are credited even if the
  customer closes the page before the callback runs (`credit_deposit` is
  already safe to call twice).
- Replace the Tailwind CDN script with a built CSS file (the CDN isn't meant
  for production).
- In Supabase Auth settings, turn on leaked-password protection and set the
  minimum password length to 8.
