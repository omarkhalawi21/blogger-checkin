# Blogger Check-in

A tiny two-page web app for tracking blogger visits during campaigns.

- **`index.html`** — the public check-in page (behind the QR code). A blogger enters
  name + phone; if their number is pre-registered they get a ✅ "enjoy" popup and the
  visit is logged. If not, they're told to see the team.
- **`admin.html`** — a private console (owner login) to register numbers
  (paste or CSV), see who checked in, and export a CSV.

**Security:** the phone list is never exposed to the public page. The check-in page can
only call one database function that returns a yes/no and records the visit. The list and
the log are readable only after signing in.

---

## Setup (about 10 minutes)

### 1. Create a Supabase project
Go to [supabase.com](https://supabase.com) → **New project**. Pick a name and a strong
database password. Wait for it to finish provisioning.

### 2. Run the schema
Open **SQL Editor → New query**, paste the whole of **`schema.sql`**, and click **Run**.
It creates the two tables, the check-in function, and the security rules.
(The diagnostic at the bottom of the file should return `true / true / true`.)

### 3. Create your admin login
**Authentication → Users → Add user** → enter your email + a password → **Create**.
This is the account you'll sign in with on `admin.html`.
(Optional: **Authentication → Providers → Email** and turn *off* "Allow new users to sign
up" so only you can log in.)

### 4. Point the app at your project
Open **`config.js`** and fill in:
- `SUPABASE_URL` — **Project Settings → Data API → Project URL**
- `SUPABASE_ANON_KEY` — **Project Settings → API Keys → `anon` / publishable key**
  (the publishable one — **never** the `service_role` key)

### 5. Try it locally
Open `admin.html` in a browser, sign in, and paste a couple of test numbers.
Then open `index.html` and check in with one of them — you should get the popup.

### 6. Publish it (GitHub Pages)
Create a repo, push these files, then **Settings → Pages → Deploy from branch → `main` / root**.
Your pages will be at:
- Check-in: `https://<you>.github.io/<repo>/`
- Admin: `https://<you>.github.io/<repo>/admin.html`

(Any static host works — Netlify, Vercel, etc.)

### 7. Make the QR code
Generate a QR that points at the **check-in URL** (step 6). Any free QR generator works;
print it and place it where the bloggers sit. Done.

---

## Day-to-day

- **Before a campaign:** open `admin.html`, paste the bloggers' numbers (one per line,
  optionally `number, name`) or upload a CSV, click **Add to list**.
- **During:** bloggers scan the QR and check in themselves.
- **After:** open the **Check-ins** tab for counts, or **Export CSV**.

Numbers are matched on their last 9 digits, so `0551234567`, `+966551234567`, and
`551234567` are all the same person.
