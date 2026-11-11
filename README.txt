Flamin' Pit website - Netlify deploy

1. Go to app.netlify.com/drop (or Sites > Add new site > Deploy manually).
2. Drag the UNZIPPED folder (not the .zip) onto the page.
3. Before going public, fill in the business details in index.html
   (search for: const B={ ) - registered name, address, phone, email,
   hours, DTI/SEC no., TIN, permit no., privacy contact, retention periods,
   refund terms, image credits.

index.html  - the whole site
_headers    - security headers Netlify applies automatically

--- Added: customer accounts, cart, add-to-cart animation ---

Customer sign-in (mobile number)
  Visitors see a Sign in / Create account screen on their first visit, with
  "Continue as guest". Customers sign up and sign in with their MOBILE NUMBER
  (not email) and a password. They can edit their details and change their
  password under "My account", and tap "Forgot password?" to ask the shop for a
  reset. To make sign-in mandatory, open index.html, search for REQUIRE_LOGIN
  and change false to true.

Owner mode > Accounts (NEW)
  Log in via the "Staff" link in the footer or yoursite.com/#login, then open
  "Accounts" in the top menu. You can list/search customers, edit them, add a
  note, disable/delete, reset passwords (temporary password, customer must pick
  a new one), add walk-in customers, and manage owner/staff logins too.

  *** To see accounts from ALL customers' phones you must connect the free
  Supabase database: follow SETUP-ACCOUNTS.md (about 10 minutes, then re-upload
  the folder). Until then accounts are saved only in each visitor's own browser
  and the Accounts page shows only this device's accounts. ***

  After you connect Supabase, the owner login is the username/password you put
  in supabase-setup.sql (the old built-in owner login is no longer used).
  Without Supabase (device-only mode) the original owner login still works the
  first time and is then stored on this device; if you forget a changed owner
  password there, run  localStorage.removeItem('fpCust')  in the browser
  console on your site to start over (this also removes device-only customers).

Cart
  Every product (menu, House picks, product pop-up) has Add to cart. The cart
  is saved in the visitor's browser. "Place order" opens the visitor's email
  app addressed to B.email, or copies the order summary if B.email is empty.
  So fill in B.email (and phone) before going public.

Checkout + payments (NEW)
  The cart's "Checkout" button opens a panel: name, mobile, notes, then the customer picks
  Cash, GCash, Maya or Bank/InstaPay. QR methods show the QR image, amount, account details and ask
  for the payment reference number. Payments are MANUAL (customer pays by scanning, you confirm
  it in your own app); the site does not verify payments automatically.
  Owner mode > "Payments" (in the owner bar): switch methods on/off, upload YOUR real QR,
  set account name/number and instructions. Until you upload a QR, customers see a SAMPLE QR
  that does not receive money. Then use Save site and upload the downloaded file.

Legal text
  Privacy Policy, Cookie Policy and Terms were updated to mention accounts and
  the cart. Please have them reviewed once your business details are filled in.

--- Performance update ---
img/t/ holds smaller thumbnails used by the menu cards, gallery and cart; full-size
images in img/ are used for the hero/banners and the product pop-up. Keep both folders
when you upload. Photos now load as you scroll instead of all at once.

--- Orders tab (NEW) ---
Owner mode > Orders lists every order placed at checkout. See SETUP-ORDERS.md
(run supabase-orders.sql in Supabase so orders from all customers' phones arrive).

--- Receipt (NEW) ---
After "Place order" the customer sees an animated receipt (any payment method) with a
"Download receipt (image)" button that saves a PNG. Nothing to set up.
