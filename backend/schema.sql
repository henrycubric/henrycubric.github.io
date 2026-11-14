-- GOLDILOCKS backend (Supabase / Postgres).
-- Run this whole file once in the Supabase SQL editor. It is safe to run again.
--
-- What it stores
--   plays   one row per answer a player launches (daily star, or galaxy-map level with day = 0)
--   misses  answers the game did not recognize, so the answer lists can grow
--   scores  one finished daily score per player per day (feeds the "better than X%" curve)
--   admins  which login accounts may open the admin dashboard
--
-- Who can do what
--   Anyone playing (the public "anon" key) can ADD rows, but can never read raw rows back.
--   Anyone can read AGGREGATED answer counts and daily score totals: that is what makes rarity real.
--   Only signed-in accounts listed in admins can read everything, through the admin_* functions.

-- ---------------------------------------------------------------- tables
create table if not exists public.plays (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  day        integer not null check (day between 0 and 100000),          -- star number; 0 = map level
  prompt_id  text    not null check (prompt_id ~ '^q[0-9a-z]{1,12}$'),     -- stable id derived from the question
  answer     text    not null check (char_length(answer) between 1 and 60),
  player     uuid    not null,                                           -- random id kept in the player's browser
  unique (day, prompt_id, player)                                         -- one answer per prompt per player per day
);
create index if not exists plays_prompt_answer on public.plays (prompt_id, answer);
create index if not exists plays_day on public.plays (day);

create table if not exists public.misses (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  day        integer not null check (day between 0 and 100000),
  prompt_id  text    not null check (prompt_id ~ '^q[0-9a-z]{1,12}$'),
  typed      text    not null check (char_length(typed) between 1 and 40),
  player     uuid    not null
);
create index if not exists misses_day on public.misses (day);
create index if not exists misses_prompt on public.misses (prompt_id);

create table if not exists public.scores (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  day        integer not null check (day between 1 and 100000),
  player     uuid    not null,
  total      integer not null check (total between 0 and 20000),
  habitable  integer not null check (habitable between 0 and 7),
  unique (day, player)
);
create index if not exists scores_day on public.scores (day);

create table if not exists public.admins (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- row level security
alter table public.plays  enable row level security;
alter table public.misses enable row level security;
alter table public.scores enable row level security;
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

drop policy if exists "players add plays"  on public.plays;
drop policy if exists "players add misses" on public.misses;
drop policy if exists "players add scores" on public.scores;
drop policy if exists "admins read plays"  on public.plays;
drop policy if exists "admins read misses" on public.misses;
drop policy if exists "admins read scores" on public.scores;
drop policy if exists "admins see admins"  on public.admins;

create policy "players add plays"  on public.plays  for insert to anon, authenticated with check (true);
create policy "players add misses" on public.misses for insert to anon, authenticated with check (true);
create policy "players add scores" on public.scores for insert to anon, authenticated with check (true);
create policy "admins read plays"  on public.plays  for select to authenticated using (public.is_admin());
create policy "admins read misses" on public.misses for select to authenticated using (public.is_admin());
create policy "admins read scores" on public.scores for select to authenticated using (public.is_admin());
create policy "admins see admins"  on public.admins for select to authenticated using (public.is_admin());

revoke all on public.plays, public.misses, public.scores, public.admins from anon, authenticated;
grant insert on public.plays, public.misses, public.scores to anon, authenticated;
grant select on public.plays, public.misses, public.scores, public.admins to authenticated;

-- ---------------------------------------------------------------- public aggregates (used by the game)
-- How many players gave each answer, for up to 20 prompts at once. All days and modes count.
create or replace function public.answer_counts(p_prompts text[])
returns table (prompt_id text, answer text, n bigint)
language sql stable security definer set search_path = public as $$
  select p.prompt_id, p.answer, count(*)::bigint
  from public.plays p
  where cardinality(p_prompts) <= 20 and p.prompt_id = any (p_prompts)
  group by p.prompt_id, p.answer;
$$;

-- Every finished score for one day (no player ids), for the "better than X%" curve.
create or replace function public.day_scores(p_day integer)
returns table (total integer)
language sql stable security definer set search_path = public as $$
  select s.total from public.scores s where s.day = p_day limit 20000;
$$;

-- ---------------------------------------------------------------- admin dashboard
create or replace function public.admin_overview() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not an admin' using errcode = '42501'; end if;
  return json_build_object(
    'players', (select count(distinct player) from public.plays),
    'answers', (select count(*) from public.plays),
    'misses',  (select count(*) from public.misses),
    'days', coalesce((
      select json_agg(d order by d.day desc) from (
        select p.day,
               count(distinct p.player) as players,
               count(*) as answers,
               (select round(avg(s.total)) from public.scores s where s.day = p.day) as avg_score,
               (select count(*) from public.scores s where s.day = p.day) as finished
        from public.plays p where p.day > 0
        group by p.day order by p.day desc limit 90) d), '[]'::json)
  );
end $$;

create or replace function public.admin_day(p_day integer) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not an admin' using errcode = '42501'; end if;
  return json_build_object(
    'day', p_day,
    'players', (select count(distinct player) from public.plays where day = p_day),
    'answers', coalesce((select json_agg(r) from (
        select prompt_id, answer, count(*) as n from public.plays where day = p_day
        group by prompt_id, answer order by prompt_id, n desc) r), '[]'::json),
    'misses', coalesce((select json_agg(r) from (
        select prompt_id, lower(typed) as typed, count(*) as n from public.misses where day = p_day
        group by prompt_id, lower(typed) order by n desc limit 500) r), '[]'::json),
    'scores', coalesce((select json_agg(total) from public.scores where day = p_day), '[]'::json)
  );
end $$;

create or replace function public.admin_prompt(p_prompt text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not an admin' using errcode = '42501'; end if;
  return json_build_object(
    'prompt_id', p_prompt,
    'players', (select count(distinct player) from public.plays where prompt_id = p_prompt),
    'answers', coalesce((select json_agg(r) from (
        select answer, count(*) as n from public.plays where prompt_id = p_prompt
        group by answer order by n desc) r), '[]'::json),
    'misses', coalesce((select json_agg(r) from (
        select lower(typed) as typed, count(*) as n from public.misses where prompt_id = p_prompt
        group by lower(typed) order by n desc limit 200) r), '[]'::json)
  );
end $$;

revoke execute on function public.answer_counts(text[]), public.day_scores(integer),
  public.admin_overview(), public.admin_day(integer), public.admin_prompt(text), public.is_admin() from public;
grant execute on function public.answer_counts(text[]), public.day_scores(integer), public.is_admin() to anon, authenticated;
grant execute on function public.admin_overview(), public.admin_day(integer), public.admin_prompt(text) to authenticated;
