# GOLDILOCKS backend

GOLDILOCKS runs on GitHub Pages, which only serves files. This folder adds a small
[Supabase](https://supabase.com) backend (a hosted Postgres database with logins) so that:

- **every player's answers are saved**, and rarity (how far each planet lands) is worked out
  from what everyone actually says, not just the built-in sample crowd;
- **the "better than X% of today's crowd" curve** uses real finished scores;
- **you get a password-protected admin dashboard** inside the game showing everyone's answers.

Until it is connected, the game keeps working on its built-in crowd.

## One-time setup (about 5 minutes)

1. **Create a project.** Sign in at supabase.com and create a new project (the free plan is enough).
   Pick any database password and keep it somewhere safe; the game does not need it.
2. **Create the database.** In the project, open **SQL Editor**, paste the whole of
   [`schema.sql`](schema.sql), and press **Run**. It is safe to run again later.
3. **Create your admin login.** Open **Authentication → Users → Add user → Create new user**,
   enter your email and a strong password, and tick **Auto confirm user**.
4. **Make that login an admin.** Back in the SQL Editor, run (with your email):
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'you@example.com';
   ```
5. **Stop strangers from creating accounts** (recommended): **Authentication → Sign In / Providers →
   Email**, turn off **Allow new users to sign up**. Only admins can see data either way, but this
   keeps the user list clean.
6. **Connect the game.** Open **Project Settings → API** (or **Data API**) and copy the
   **Project URL** and the **anon public** key. Put them in the one `BACKEND` line near the
   top of the script in `goldilocks.html`:
   ```js
   const BACKEND = { url: 'https://YOUR-PROJECT.supabase.co', key: 'YOUR-ANON-KEY' };
   ```
   The anon key is designed to be public; the rules in `schema.sql` decide what it can do.
   Never put the `service_role` key in the page.

## Using the dashboard

On the GOLDILOCKS title screen, tap **Admin** (or open `goldilocks.html#admin`) and sign in.

- **Tiles:** players, answers, players today, today's average score, and answers that were not on the list.
- **Daily stars:** step through each day. You get the score spread, then each of the 7 prompts with
  every answer as a bar. Bars are colored by where that answer scores right now (scorched, in the
  green, bullseye, frozen). Answers the game did not recognize are listed underneath; they are the
  best candidates to add to the answer lists.
- **Any prompt:** pick any of the 98 prompts to see all-time answers from daily stars and map levels.
- **Download this day as CSV:** every answer for the selected day, with time, question, answer and
  an anonymous player id.

## How scores follow the crowd

Each prompt starts with a built-in sample crowd worth 500 players (`PRIOR` in the game's settings).
Every real answer is added on top, so as real players arrive their answers take over: an answer
that lots of people give drifts toward the hot zone and scorches, and a rarely given one drifts
out toward the cold. The game fetches fresh counts each time a daily star or level starts.

## What is stored

| Table   | Contents |
|---------|----------|
| `plays` | One row per launched answer: day (0 = map level), prompt, answer, anonymous player id. One answer per prompt per player per day. |
| `misses`| Answers that were not on the list. |
| `scores`| Each player's finished daily score. |
| `admins`| Which logins can open the dashboard. |

Players are identified only by a random id kept in their browser. No names or emails are collected
from players.

## Limits to know about

- The game runs in the browser, so a determined person could send made-up answers with the public
  key. The database limits each player id to one answer per prompt per day and checks sizes, but it
  cannot prove a play was real. If that ever matters, the fix is moving inserts behind a
  Supabase Edge Function with rate limiting.
- The Claude artifact copy of the game cannot reach Supabase (its sandbox blocks other sites), so
  it keeps using its own shared storage. Only the GitHub Pages copy feeds this backend.

## Resetting the data

```sql
truncate public.plays, public.misses, public.scores restart identity;
```
