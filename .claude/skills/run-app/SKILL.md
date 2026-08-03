---
name: run-app
description: How to run and visually verify this Phoenix app — the dev server is managed by the user, never start or stop it; drive headless Chrome against localhost:4000.
---

# Running the secant-service app

## Dev server: already running, hands off

The user keeps `mix phx.server` running in their own terminal while
developing. **Never start, restart, or kill the server or anything
listening on port 4000.**

- Check availability with `curl -sf http://localhost:4000 >/dev/null`.
  If it does not respond, stop and ask the user to start
  `mix phx.server` — do not start it yourself.
- Phoenix live reload is active: after editing `.ex`, `.heex`, CSS, or
  JS files, the running server picks the change up on its own — no
  restart needed, just reload the page in the browser session.

## Auth

None. All pages (`/`, `/dashboard`, `/browse`) are reachable without
logging in.

## Screenshots

`chromium-cli` is not installed on this machine, but system Chrome is
(`/usr/bin/google-chrome`), and Playwright drives it without any
browser download. Use the helper script that lives next to this skill:

```bash
cd <scratchpad> && npm i playwright   # once per session, ~1s
node <repo>/.claude/skills/run-app/screenshot.js \
  http://localhost:4000/dashboard dashboard.png
# options: --wait-gone "<placeholder text>" (default: the plot
#          placeholder; pass "none" to skip), --theme light|dark
```

It shoots at 2560×1440, waits for LiveView's "Waiting for valid Plot
Data..." placeholder to clear so ECharts plots are in the shot
(~4–5 s), and prints any browser console errors. For interactions
(clicking dropdowns, filling forms), write a one-off Playwright script
in the scratchpad using the same launch pattern:
`chromium.launch({ channel: 'chrome', headless: true })`.

Do **not** use plain `google-chrome --headless --screenshot`: it
captures at the page load event, before the websocket pushes charts,
so plots show as a grey "Waiting for valid Plot Data..." box no matter
how large `--timeout` is. (`--virtual-time-budget` is worse — it makes
the LiveView heartbeat time out and a spurious red "Attempting to
reconnect" banner appears.)

Playwright must **never** be added to the project itself — no
`npm i` in the repo root or `assets/`, no entry in any tracked
`package.json`. It is tooling for the agent, not a project dependency;
it lives in the scratchpad (or a global install) only.

## Representative check

`/browse` always renders: tab bar "Active / Archived / Trashed /
Favourites / All" plus a table of nodes with View Node / View JSON
buttons. A screenshot showing that table proves the app is up.

## App-specific notes

- `/dashboard` is where the live SECoP node UI (secop_components:
  module indicators, parameter widgets, dropdowns, charts) renders.
  It needs at least one connected SECoP node; the user usually has sim
  nodes connected (visible as "Active" rows on `/browse`). If none are
  connected, ask the user rather than faking data.
- `/browse/node/:uuid` shows a single node's archived data; uuids come
  from the `/browse` listing.
- LiveView holds a websocket open, so "wait for network idle"
  strategies never settle — wait for a concrete element (or use the
  virtual-time-budget flag) instead.
