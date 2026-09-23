-- =============================================================================
-- Explore Philippines Map — Anonymous name + usage + presence tracking
-- =============================================================================
-- Run this WHOLE file once in: Supabase → SQL Editor → New query → Run
-- Safe to re-run (uses IF NOT EXISTS / CREATE OR REPLACE).
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1) Core tables
-- -----------------------------------------------------------------------------

create table if not exists public.pmm_users (
  id uuid primary key,
  name text not null check (char_length(trim(name)) between 2 and 80),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  session_count integer not null default 0,
  quiz_started_count integer not null default 0,
  quiz_completed_count integer not null default 0,
  last_mode text,
  updated_at timestamptz not null default now()
);

create table if not exists public.pmm_user_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.pmm_users(id) on delete cascade,
  name text not null,
  session_id text not null,
  event_type text not null,
  mode text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.pmm_presence (
  user_id uuid primary key references public.pmm_users(id) on delete cascade,
  name text not null,
  mode text,
  last_seen timestamptz not null default now()
);

-- Helpful comments (show in Table Editor / schema browser)
comment on table public.pmm_users is 'Anonymous visitors (browser UUID + name they typed)';
comment on column public.pmm_users.id is 'Stable anonymous browser ID (localStorage)';
comment on column public.pmm_users.name is 'Display name from welcome gate';
comment on column public.pmm_users.first_seen is 'First time this browser was seen';
comment on column public.pmm_users.last_seen is 'Last activity / heartbeat (auto-updates)';
comment on column public.pmm_users.session_count is 'How many distinct browser sessions';
comment on column public.pmm_users.quiz_started_count is 'Times a quiz was started';
comment on column public.pmm_users.quiz_completed_count is 'Times a quiz was finished';
comment on column public.pmm_users.last_mode is 'Last game mode (explore, quiz, etc.)';

comment on table public.pmm_user_events is 'Event log (session start, quiz start/complete, etc.)';
comment on table public.pmm_presence is 'Who is online right now (heartbeat every ~30s; offline after 90s)';

create index if not exists pmm_users_last_seen_idx on public.pmm_users(last_seen desc);
create index if not exists pmm_users_name_idx on public.pmm_users(name);
create index if not exists pmm_events_user_created_idx on public.pmm_user_events(user_id, created_at desc);
create index if not exists pmm_events_created_idx on public.pmm_user_events(created_at desc);
create index if not exists pmm_events_type_idx on public.pmm_user_events(event_type);
create index if not exists pmm_presence_last_seen_idx on public.pmm_presence(last_seen desc);

-- -----------------------------------------------------------------------------
-- 2) Lock tables from browser (anon / authenticated)
--    Browser may only call the RPC functions below.
-- -----------------------------------------------------------------------------

alter table public.pmm_users enable row level security;
alter table public.pmm_user_events enable row level security;
alter table public.pmm_presence enable row level security;

revoke all on public.pmm_users from anon, authenticated;
revoke all on public.pmm_user_events from anon, authenticated;
revoke all on public.pmm_presence from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3) RPC functions used by the website
-- -----------------------------------------------------------------------------

create or replace function public.pmm_upsert_user(
  p_user_id uuid,
  p_name text,
  p_session_id text,
  p_mode text default null,
  p_new_session boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := left(regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g'), 80);
  result public.pmm_users;
begin
  if p_user_id is null or char_length(clean_name) < 2 then
    raise exception 'Invalid user data';
  end if;

  insert into public.pmm_users(id, name, first_seen, last_seen, session_count, last_mode, updated_at)
  values(p_user_id, clean_name, now(), now(), case when p_new_session then 1 else 0 end, nullif(p_mode,''), now())
  on conflict (id) do update set
    name = excluded.name,
    last_seen = now(),
    last_mode = coalesce(excluded.last_mode, public.pmm_users.last_mode),
    session_count = public.pmm_users.session_count + case when p_new_session then 1 else 0 end,
    updated_at = now()
  returning * into result;

  -- Keep presence in sync so "online" stays accurate after name/session upsert
  insert into public.pmm_presence(user_id, name, mode, last_seen)
  values(p_user_id, clean_name, nullif(p_mode,''), now())
  on conflict (user_id) do update set
    name = excluded.name,
    mode = coalesce(excluded.mode, public.pmm_presence.mode),
    last_seen = now();

  return jsonb_build_object(
    'id', result.id,
    'name', result.name,
    'first_seen', result.first_seen,
    'last_seen', result.last_seen,
    'session_count', result.session_count
  );
end;
$$;

create or replace function public.pmm_heartbeat(
  p_user_id uuid,
  p_name text,
  p_mode text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := left(regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g'), 80);
begin
  if p_user_id is null or char_length(clean_name) < 2 then
    return;
  end if;

  insert into public.pmm_users(id, name, first_seen, last_seen, session_count, last_mode, updated_at)
  values(p_user_id, clean_name, now(), now(), 0, nullif(p_mode,''), now())
  on conflict (id) do update set
    name = excluded.name,
    last_seen = now(),
    last_mode = coalesce(excluded.last_mode, public.pmm_users.last_mode),
    updated_at = now();

  insert into public.pmm_presence(user_id, name, mode, last_seen)
  values(p_user_id, clean_name, nullif(p_mode,''), now())
  on conflict (user_id) do update set
    name = excluded.name,
    mode = excluded.mode,
    last_seen = now();
end;
$$;

create or replace function public.pmm_record_event(
  p_user_id uuid,
  p_name text,
  p_session_id text,
  p_event_type text,
  p_mode text default null,
  p_payload jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := left(regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g'), 80);
  clean_type text := left(trim(coalesce(p_event_type,'')), 60);
  new_id bigint;
begin
  if p_user_id is null or char_length(clean_name) < 2 or char_length(clean_type) < 1 then
    raise exception 'Invalid event data';
  end if;

  insert into public.pmm_users(id, name, first_seen, last_seen, session_count, last_mode, updated_at)
  values(p_user_id, clean_name, now(), now(), 0, nullif(p_mode,''), now())
  on conflict (id) do update set
    name = excluded.name,
    last_seen = now(),
    last_mode = coalesce(excluded.last_mode, public.pmm_users.last_mode),
    updated_at = now();

  insert into public.pmm_user_events(user_id, name, session_id, event_type, mode, payload)
  values(
    p_user_id,
    clean_name,
    left(coalesce(p_session_id,''), 120),
    clean_type,
    nullif(left(coalesce(p_mode,''), 60), ''),
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into new_id;

  if clean_type = 'quiz_started' then
    update public.pmm_users
    set quiz_started_count = quiz_started_count + 1, last_seen = now(), updated_at = now()
    where id = p_user_id;
  elsif clean_type = 'quiz_completed' then
    update public.pmm_users
    set quiz_completed_count = quiz_completed_count + 1, last_seen = now(), updated_at = now()
    where id = p_user_id;
  else
    update public.pmm_users
    set last_seen = now(), updated_at = now()
    where id = p_user_id;
  end if;

  -- Touch presence so online status stays fresh on meaningful events
  insert into public.pmm_presence(user_id, name, mode, last_seen)
  values(p_user_id, clean_name, nullif(p_mode,''), now())
  on conflict (user_id) do update set
    name = excluded.name,
    mode = coalesce(excluded.mode, public.pmm_presence.mode),
    last_seen = now();

  return new_id;
end;
$$;

create or replace function public.pmm_online_count()
returns bigint
language sql
security definer
set search_path = public
as $$
  select count(*)::bigint
  from public.pmm_presence
  where last_seen >= now() - interval '90 seconds';
$$;

grant execute on function public.pmm_upsert_user(uuid, text, text, text, boolean) to anon, authenticated;
grant execute on function public.pmm_heartbeat(uuid, text, text) to anon, authenticated;
grant execute on function public.pmm_record_event(uuid, text, text, text, text, jsonb) to anon, authenticated;
grant execute on function public.pmm_online_count() to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4) Cleanup (owner only — run manually or via cron)
-- -----------------------------------------------------------------------------

create or replace function public.pmm_cleanup_presence()
returns integer
language sql
security definer
set search_path = public
as $$
  with deleted as (
    delete from public.pmm_presence
    where last_seen < now() - interval '1 day'
    returning 1
  )
  select count(*)::integer from deleted;
$$;

revoke all on function public.pmm_cleanup_presence() from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5) READABLE ADMIN VIEWS  ← open these in Table Editor / SQL
--    (views are for YOU as project owner; browser still cannot read tables)
-- -----------------------------------------------------------------------------

-- Who is online RIGHT NOW (heartbeat within last 90 seconds)
create or replace view public.pmm_v_online as
select
  p.name,
  p.mode,
  p.last_seen,
  case
    when p.last_seen >= now() - interval '30 seconds' then '🟢 live'
    when p.last_seen >= now() - interval '90 seconds' then '🟡 recent'
    else '⚪ offline'
  end as status,
  round(extract(epoch from (now() - p.last_seen)))::int as seconds_ago,
  u.session_count,
  u.quiz_started_count,
  u.quiz_completed_count,
  p.user_id
from public.pmm_presence p
left join public.pmm_users u on u.id = p.user_id
where p.last_seen >= now() - interval '90 seconds'
order by p.last_seen desc;

comment on view public.pmm_v_online is 'Currently online visitors (last heartbeat ≤ 90s). Refresh to update.';

-- All users, human-friendly (sort by last activity)
create or replace view public.pmm_v_users as
select
  u.name,
  case
    when p.last_seen >= now() - interval '90 seconds' then '🟢 online'
    when u.last_seen >= now() - interval '1 hour' then '🟡 today'
    when u.last_seen >= now() - interval '7 days' then '🔵 this week'
    else '⚪ older'
  end as status,
  u.last_mode as mode,
  u.last_seen,
  to_char(u.last_seen at time zone 'Asia/Manila', 'Mon DD, HH24:MI') as last_seen_ph,
  case
    when u.last_seen >= now() - interval '1 minute' then 'just now'
    when u.last_seen >= now() - interval '1 hour' then
      (extract(epoch from (now() - u.last_seen)) / 60)::int::text || ' min ago'
    when u.last_seen >= now() - interval '1 day' then
      (extract(epoch from (now() - u.last_seen)) / 3600)::int::text || ' hr ago'
    else
      (extract(epoch from (now() - u.last_seen)) / 86400)::int::text || ' days ago'
  end as last_seen_rel,
  u.session_count as sessions,
  u.quiz_started_count as quizzes_started,
  u.quiz_completed_count as quizzes_done,
  to_char(u.first_seen at time zone 'Asia/Manila', 'Mon DD, YYYY HH24:MI') as first_seen_ph,
  u.id as user_id
from public.pmm_users u
left join public.pmm_presence p on p.user_id = u.id
order by u.last_seen desc;

comment on view public.pmm_v_users is 'All visitors with readable last-seen (PH time) and online status';

-- Recent events (easy activity feed)
create or replace view public.pmm_v_recent_events as
select
  e.created_at,
  to_char(e.created_at at time zone 'Asia/Manila', 'Mon DD HH24:MI:SS') as time_ph,
  e.name,
  e.event_type,
  e.mode,
  e.payload,
  e.user_id,
  e.id as event_id
from public.pmm_user_events e
order by e.created_at desc
limit 500;

comment on view public.pmm_v_recent_events is 'Last 500 events (newest first). Good for debugging activity.';

-- One-row dashboard summary
create or replace view public.pmm_v_stats as
select
  (select count(*) from public.pmm_presence where last_seen >= now() - interval '90 seconds') as online_now,
  (select count(*) from public.pmm_users) as total_users,
  (select count(*) from public.pmm_users where last_seen >= now() - interval '1 day') as active_today,
  (select count(*) from public.pmm_users where last_seen >= now() - interval '7 days') as active_7d,
  (select coalesce(sum(session_count), 0) from public.pmm_users) as total_sessions,
  (select coalesce(sum(quiz_started_count), 0) from public.pmm_users) as total_quizzes_started,
  (select coalesce(sum(quiz_completed_count), 0) from public.pmm_users) as total_quizzes_completed,
  (select count(*) from public.pmm_user_events where created_at >= now() - interval '1 day') as events_today;

comment on view public.pmm_v_stats is 'Single-row overview: online now, totals, today activity';

-- -----------------------------------------------------------------------------
-- 6) Quick queries you can paste in SQL Editor anytime
-- -----------------------------------------------------------------------------
-- Online right now:
--   select * from public.pmm_v_online;
--
-- All users (readable):
--   select * from public.pmm_v_users;
--
-- Dashboard numbers:
--   select * from public.pmm_v_stats;
--
-- Recent activity:
--   select * from public.pmm_v_recent_events;
--
-- Manual presence cleanup:
--   select public.pmm_cleanup_presence();
-- =============================================================================
)
