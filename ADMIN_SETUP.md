# Explore Philippines Map — Private Admin Dashboard

## Files

- `admin.html` — private username/password dashboard
- `supabase_user_tracking_admin_v2.sql` — existing tracking SQL plus admin authentication/session functions
- `index(20260923-034755).html` — existing main app; **no tracking code changes are required** because the current heartbeat already feeds the dashboard

## 1. Run the updated SQL

In Supabase:

1. Open **SQL Editor**.
2. Create a new query.
3. Paste the entire contents of `supabase_user_tracking_admin_v2.sql`.
4. Run it.

This preserves the existing tracking tables/functions/views and adds:

- `pmm_admin_credentials`
- `pmm_admin_sessions`
- `pmm_admin_login(...)`
- `pmm_admin_logout(...)`
- `pmm_admin_dashboard(...)`

The admin password is stored as a one-way hash, not plaintext.

## 2. Deploy `admin.html`

Put `admin.html` beside your existing `index.html` in the same Vercel/static project.

Then open:

`https://YOUR-DOMAIN/admin.html`

The page asks for the configured admin username and password.

## 3. What the dashboard shows

- Online users right now
- Total users
- Active today
- Total quizzes completed
- Current mode/activity
- Last seen / relative last seen
- All users
- Recent activity events
- Philippine time (Asia/Manila)

The dashboard refreshes automatically every 10 seconds.

## 4. Online behavior

The existing app heartbeat runs about every 30 seconds. A visitor is considered online for up to 90 seconds after the most recent heartbeat.

So a normal flow is:

`user opens site → heartbeat → pmm_presence → admin dashboard`

If the user closes the page or stops sending heartbeats, they naturally disappear from the online list after the 90-second window.

## 5. Important security note

Do not put the Supabase `service_role` key in `admin.html`.

The admin page uses the existing Supabase publishable key plus a short-lived server-side database session token. The credential check and dashboard data access happen through protected PostgreSQL functions.

If the admin password is ever changed, update the password hash in `pmm_admin_credentials` using a newly generated pgcrypto-compatible hash rather than putting a plaintext password into the database.
