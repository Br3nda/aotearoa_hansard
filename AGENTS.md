# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, GitHub Copilot, and others) when
working with code in this repository.

## What this scraper does

A [morph.io](https://morph.io) scraper that fetches raw data from two NZ Parliament Hansard
sources that don't need a browser: the official Hansard search API (paginated JSON) and
parliament.nz's House sitting calendar (.ics). It only stores *raw* content, upserted by
whichever ID each source already provides - it does not parse anything into structured records.
That parsing happens downstream, in the [hotair](https://github.com/Br3nda/hotair) Rails app,
which pulls this scraper's output back out via morph.io's own SQL-query API.

Headless-Chrome transcript fetching (a separate concern - getting past Radware bot protection on
the actual per-day transcript pages) lives in a sibling scraper,
[aotearoa_hansard_transcripts](https://github.com/Br3nda/aotearoa_hansard_transcripts), kept
apart so a Selenium problem there can't take down these two already-working, browser-free
fetches.

**Read `PLAN.md` before doing anything else here** - it has the full, current status of what's
blocking this scraper from actually running on morph.io, what's been tried and ruled out, and
what's confirmed working.

## Layout

- `scraper.rb` - the whole thing. Two independent modules, `HansardSearch` and
  `SittingCalendar`, each with its own `run`. No shared state between them.
- `platform` - which morph.io build stack this scraper runs on (`heroku-18`). Don't change this
  without reading `PLAN.md` first - `heroku-24` was tried and reverted upstream for unrelated
  reasons (see the plan and `openaustralia/morph#1440`/`#1456`).
- `Gemfile`/`Gemfile.lock` - deliberately minimal (`scraperwiki`, `sqlite3`, `rubocop` only). If
  you add a gem, regenerate the lock with `bundle install` or `bundle lock` - don't hand-edit it,
  and don't forget to actually do it (a stale lock that doesn't match the Gemfile got committed
  here once already).

## Things that will catch you out

- **morph.io's build pipeline for `heroku-18` was broken for scrapers with a modern
  (Bundler 2.x) `Gemfile.lock`** - the bootstrap step that reads the lockfile used a hardcoded
  ancient Bundler (1.15.2). This has been fixed - see `PLAN.md` and
  `openaustralia/morph#1530`/`openaustralia/buildstep#10` for the full diagnosis and the actual
  patch - but if you see `Bundler::LockfileError` again, that's where to look, and check whether
  the fix actually landed/deployed before assuming it's a new problem.
- **The published `morph-cli` gem (0.2.5) is broken on Ruby >= 3.2** (`File.exists?`, removed in
  3.2). Already fixed on that project's own `main` branch, just never released to RubyGems as of
  writing. Build it from source rather than `gem install morph-cli` if it crashes on load.
- **This repo isn't marked private on morph.io yet** (or may or may not be, depending on when
  you're reading this) - private-scraper access there is admin-gated, not self-serve
  (`openaustralia/morph#1342`). Brenda works for OAF, so this is an internal ask, not a cold
  request to a stranger - don't assume it needs external outreach.
- **Rolling date window, not a full backfill.** `HansardSearch` defaults to the last 14 days
  (`HANSARD_DATE_FROM`/`HANSARD_DATE_TO` env vars widen this) - this is meant for routine
  scheduled runs, not re-fetching the entire multi-decade corpus every time. Use a wider range
  explicitly (e.g. via `morph-cli`) for a one-off historical backfill.
- **The sitting calendar fetch validates its own response shape** (`BEGIN:VCALENDAR` at the
  start) before trusting it - `www3.parliament.nz`'s calendar export can serve a Radware bot-check
  page with a `200 OK`, not just an error status.

## Commands

- Syntax check: `ruby -c scraper.rb`
- Lint: `bundle exec rubocop` (or `rubocop scraper.rb` if gems aren't installed locally)
- Run against morph.io directly (uploads and streams output back, doesn't run locally):
  `morph` (needs an API key in `~/.morph` - see morph.io/settings)
