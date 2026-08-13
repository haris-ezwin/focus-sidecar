# Focus Sidecar

A tiny native macOS companion that follows the focused window, shows tasks due today, and keeps local countdowns for upcoming events.

## What it does

- Opens as a compact 284 × 620 floating panel and caps manual resizing at 420 × 820.
- Follows the focused macOS window when Accessibility permission is enabled from the app’s Settings menu.
- Includes a pin toggle: pinning captures the panel's exact current position relative to the active window; unpinned stays where you drag its title bar on the current desktop.
- Uses the standard macOS close, minimize, and zoom window controls.
- Appears in the Dock and redirects duplicate launches to the existing app window.
- Uses a custom generated Focus Sidecar icon in Dock, Spotlight, and Finder.
- Shows an “Events looking forward to” countdown section above the task list.
- Adds, edits, and deletes event names and dates/times locally in SQLite.
- Shows the number of calendar days remaining before every event.
- Uses a draggable divider to give more space to events or tasks and remembers the chosen split.
- Keeps Work and Rest count-up timers fixed to the bottom, with play/pause controls and daily accumulated totals.
- Loads rows where `type = 'Task'` and `due_date` is today.
- Shows task title, time, and priority.
- Clicking a task's completion circle updates its Supabase status to `Done`, briefly celebrates the check, then removes the row so the next task slides up.
- Dragging a task left reveals a Delete action; clicking it deletes the task from Supabase after the authenticated API confirms the row.
- Refreshes every minute and stores the Supabase session in macOS Keychain.

The app reads its Supabase URL and publishable client key from local environment configuration. It refuses `sb_secret_…` keys and never stores the user's password.

Countdown events do not use Supabase. They are stored only on this Mac at:

```text
~/Library/Application Support/Focus Sidecar/events.sqlite3
```

## Configure Supabase

Create your local environment file:

```bash
cp .env.example .env
```

Fill in your project URL and **publishable** key. `.env` is ignored by Git. Never place a Supabase secret or service-role key in this desktop app; RLS must protect the exposed `tasks` table.

The build script reads `.env` and places the client configuration in the local app bundle. Like all desktop client configuration, a publishable key is not a secret.

## Run it

```bash
focus-sidecar
```

The launcher opens the installed app at `~/Applications/Focus Sidecar.app`. Do not use `swift run` for normal launches: it creates a different ad-hoc executable identity, so macOS correctly asks for Keychain access again.

After changing the source, rebuild, reinstall, refresh Spotlight, and reopen the latest version with:

```bash
./scripts/update-installed-app.sh
```

macOS cannot safely auto-approve a Keychain request. Enter your Mac login password and choose **Always Allow** once for the installed app. Future launches through `focus-sidecar` reuse that exact app and approval.

The first launch asks for macOS Accessibility permission so the panel can follow other windows. Sign in using an account from your configured Supabase project.

## Build the app bundle

```bash
./scripts/build-app.sh
open "dist/Focus Sidecar.app"
```

The output uses an ad-hoc signature for local use. A distributed build should be signed with an Apple Developer ID and notarized.

## Database contract

The app reads these existing `public.tasks` columns:

- `id uuid`
- `title text`
- `priority text`
- `status text`
- `due_date date`
- `start_time time`
- `end_time time`
- `type text`

RLS must be enabled on the table. The desktop app requires Supabase Auth and performs authenticated `SELECT`, `UPDATE`, and `DELETE` requests.
The separate local countdown database does not require LMS authentication.
