# Explore Philippines Map — User Tracking Setup

Anonymous name gate + browser ID + Supabase records (users, events, presence / online).

## 1. Create the free Supabase project

1. Go to https://supabase.com/ → New project (Free plan is fine).
2. Wait until the project is ready.

Free plan notes: ~500 MB DB, pauses after ~1 week of inactivity. Fine for a student / personal project.

## 2. Run the SQL (tables + functions + readable views)

1. Supabase dashboard → **SQL Editor** → **New query**
2. Open `supabase_user_tracking.sql` and copy **everything**
3. Paste → **Run**

You should see success (no errors). Safe to re-run later if you update the file.

This creates:

| Object | Purpose |
|--------|---------|
| `pmm_users` | One row per anonymous browser + name |
| `pmm_user_events` | Event log (session, quiz start/finish, …) |
| `pmm_presence` | Live heartbeat for “who is online” |
| `pmm_v_online` | **Readable view** — currently online people |
| `pmm_v_users` | **Readable view** — all users + last seen (PH time) |
| `pmm_v_recent_events` | **Readable view** — latest activity feed |
| `pmm_v_stats` | **Readable view** — one-row dashboard numbers |

## 3. Get public browser credentials

Supabase → **Project Settings** → **API**

Copy:

- **Project URL**
- **anon / publishable** public key  

**Never** put the `service_role` secret key in the HTML.

## 4. Put credentials in `index.html`

Near the bottom, find the tracking script and set:

```js
const SUPABASE_URL = "https://YOUR_PROJECT.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "your-anon-or-publishable-key";
```

Redeploy / refresh the site after changing these.

## 5. How to READ the data (easy way)

Do **not** stare only at the raw tables (`pmm_users` is full of UUIDs).

Use the views instead:

### In Table Editor

1. Open **Table Editor**
2. Look for views (or run the selects below in SQL Editor)

### In SQL Editor (copy-paste)

**Who is online right now**

```sql
select * from public.pmm_v_online;
```

**All visitors (name, status, last seen in PH time)**

```sql
select * from public.pmm_v_users;
```

**Dashboard (online count, totals)**

```sql
select * from public.pmm_v_stats;
```

**Recent activity feed**

```sql
select * from public.pmm_v_recent_events;
```

Refresh the query (or re-open the view) to see updated `last_seen` / online status.  
Heartbeats run about every **30 seconds** while the tab is open; someone drops off “online” after **~90 seconds** without a heartbeat.

## 6. What gets recorded

**`pmm_users`**

- anonymous browser UUID  
- name from the welcome gate  
- first / last seen  
- session count  
- quiz started / completed counts  
- last mode  

**`pmm_user_events`**

- user id + name snapshot  
- session id  
- event type (`session_started`, `quiz_started`, `quiz_completed`, …)  
- mode + small JSON payload  
- timestamp  

**`pmm_presence`**

- who is “online” (updated by heartbeat)  
- current mode  
- last heartbeat time  

## 7. Identity notes

- ID lives in **localStorage** → identifies a browser/device, not a real person with certainty.  
- Clear site data / private window / new device → new anonymous ID.  
- The name is also stored in Supabase so you can read it in the dashboard.

## 8. Optional cleanup

Old presence rows (offline > 1 day) can be removed with:

```sql
select public.pmm_cleanup_presence();
```

(Owner only; not callable from the website.)

## 9. Vercel Web Analytics (optional)

Vercel → Project → Analytics → Enable Web Analytics → redeploy.  
Separate from Supabase; useful for page views.
)
