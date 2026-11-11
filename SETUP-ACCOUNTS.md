# Shared customer accounts (Supabase) – setup guide

Until you do this, accounts only live inside each visitor's own browser, so Owner mode
can only see accounts made on the same device. After this setup, **every customer account
is stored online and listed in Owner mode > Accounts**, from any phone or computer.

It takes about 10 minutes and the free Supabase plan is enough.

## 1. Create the database
1. Go to https://supabase.com, sign up and click **New project**.
   Name it "flamin-pit", choose a strong database password (save it somewhere safe) and
   pick the region closest to your customers (e.g. *Southeast Asia – Singapore*).
2. Wait a minute for the project to finish setting up.

## 2. Run the setup script
1. Open `supabase-setup.sql` from this folder in Notepad (or any text editor).
2. Near the top, find these two lines and put in **your own** owner username and password
   (password at least 10 characters). The script refuses to run until you change them:

       v_user text := 'owner';
       v_pass text := 'CHANGE-THIS-PASSWORD';

3. In Supabase click **SQL Editor > New query**, paste the whole file and press **Run**.
   You should see "Success. No rows returned".

   (Re-running the script later is safe; it will not delete accounts.)

## 3. Connect the website
1. In Supabase open **Project Settings > API** (or the **Connect** button).
   Copy the **Project URL** (looks like `https://abcdxyz.supabase.co`) and the
   **publishable / anon key**. These two values are meant to be public.
2. Open `index.html`, search for `const FP_CFG` and paste them in:

       const FP_CFG={supabaseUrl:'https://abcdxyz.supabase.co',supabaseKey:'YOUR-KEY'};

3. Upload the folder to Netlify again (drag the unzipped folder onto your site's Deploys page).
   The security headers already allow `*.supabase.co`.

## 4. Check it works
1. Open your site, tap **Sign in > Create account** and register with a mobile number.
2. Open `yoursite.com/#login`, sign in with the owner username/password from step 2.
3. Click **Accounts** in the top menu: the customer appears there. The page shows a green
   "Online" banner when the database is connected.

## What the owner can do in Accounts
- See every customer: name, mobile number, join date, last sign-in, status. Search by name or number.
- **Edit** name / number, add a private note, **disable** or **delete** an account.
- **Reset password**: set (or generate) a temporary password. The customer is signed out
  everywhere and must choose their own new password at next sign-in.
- **Add customer** (walk-in or phone customers).
- Customers who tap **Forgot password?** appear as "Reset requested" (with a badge on the Accounts menu).
- **Owner logins** tab: add staff/owner logins, change usernames, reset their passwords,
  change your own password, delete logins (you cannot delete yourself or the last owner).

## What customers can do
Sign up and sign in with their **mobile number + password**, edit their name/number and change
their password under **My account**, and request a reset with **Forgot password?**.

## Good to know
- **Mobile numbers are not verified by SMS.** Anyone can register with any number. Sending
  text-message codes needs a paid SMS provider (e.g. Twilio, Semaphore); ask if you want it added.
  Because of this, password resets are done by you (call or message the customer the temporary password).
- Passwords are stored only as bcrypt hashes. Nobody (including you) can read them, only reset them.
- Failed logins are rate-limited on the server (5 wrong tries = 5 minute lock for customers,
  6 = 10 minutes for owners). Sign-ups are capped at 60 per hour.
- The tables sit in a private database schema that the website cannot read directly; it can only
  call the functions in the setup script, which check the owner/customer session first.
- Supabase **free projects pause after about a week without activity**. Visit the Supabase dashboard
  and click "Restore" if that happens, or upgrade to a paid plan for a live shop.
- Use a long, unique owner password: owner logins can see every customer's name and number.
- Accounts created with the old email version of the site were stored only in customers' own browsers
  and do not carry over; those customers simply create a new account with their mobile number.
- You are responsible for these personal details under the Data Privacy Act: keep the Privacy Policy
  accurate (it has been updated) and delete accounts when customers ask.
