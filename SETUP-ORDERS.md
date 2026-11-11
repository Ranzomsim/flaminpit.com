# Orders tab (Owner mode > Orders)

Every order a customer places at checkout is saved and listed in **Owner mode > Orders**,
with the customer, items, total, payment method + reference number, and status
(New, Preparing, Ready, Completed, Cancelled). You can mark an order Paid after you check
GCash/Maya/bank, change its status, view/copy the details, call the customer, or delete it.
A badge on the Orders menu shows how many new orders are waiting, and the page refreshes
every 30 seconds.

## To see orders from ALL customers' phones
1. Do `SETUP-ACCOUNTS.md` first (Supabase project + `FP_CFG` in index.html).
2. In Supabase open **SQL Editor > New query**, paste all of `supabase-orders.sql`, press **Run**.
3. Upload the folder to Netlify again.

Until then, orders are saved only in the browser of the person who placed them (so the Orders
page only shows orders made on the same device) and checkout falls back to the old
"email / copy the order" behaviour.
