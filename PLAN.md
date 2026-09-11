# Plan: getting the hotair Hansard scrapers actually running on morph.io

Supersedes the earlier plan in `hotair-hansard-scraper` (that repo is now just scratch history -
the real work lives here and in `aotearoa_hansard_transcripts`).

## Where things actually stand

**Done:**
- `aotearoa_hansard` scraper written and pushed: fetches the Hansard search API (paginated,
  rolling 14-day window, real User-Agent) and the sitting calendar (.ics), both stored raw via
  `ScraperWiki.save_sqlite`. Clean rubocop, syntax-checked.
- `morph-cli` (the tool for running scrapers against morph.io from the command line): the
  published gem (0.2.5) is broken on modern Ruby (`File.exists?`, removed in 3.2). Already fixed
  on `openaustralia/morph-cli`'s `main` branch, just never released - built and installed it
  locally from source as a working interim fix.
- Triggered a real run with a real API key. Upload and auth worked. The **build itself failed
  server-side** - not our code.

**The actual blocker, fully root-caused:**

`aotearoa_hansard/platform` says `heroku-18` → `openaustralia/buildstep`'s
`Dockerfile.heroku-18` → `FROM gliderlabs/herokuish:v0.5.36-18` → herokuish pins its Ruby
buildpack to `heroku/heroku-buildpack-ruby` at tag `v362`. At that tag, the buildpack's own
bootstrap step reads `Gemfile.lock` using a hardcoded old Bundler (1.15.2) - before it ever gets
to the part that would read and honour the scraper's own `Gemfile`-declared Ruby version. Any
scraper whose lockfile was written by a modern Bundler (2.x - i.e. written with current tooling,
like ours) fails immediately with `Bundler::LockfileError: You must use Bundler 2 or greater
with this lockfile.`

Confirmed:
- `heroku-buildpack-ruby`'s own `main` branch has already fixed this (bootstrap default is now
  Bundler `2.5.23`) - the fix exists upstream, just not in the old pinned tag.
- `heroku-24` (buildstep's newer platform option) is **not** a viable workaround right now -
  already tried and reverted upstream (`openaustralia/morph#1456`, "nothing works on heroku-24").
- `gliderlabs/herokuish` is actively maintained (pushed yesterday, 9 open issues) - the stale
  `v362` pin looks like an oversight specific to Ruby, not general neglect.
- This does **not** require any other scraper on the platform to upgrade anything - the bug only
  triggers for lockfiles written by modern Bundler, and doesn't touch the mechanism that reads a
  scraper's own declared Ruby version at all.

## The fix attempt that didn't pan out

Tried patching `openaustralia/buildstep`'s `Dockerfile.heroku-18` with a second
`herokuish buildpack install` call (same mechanism already used to add the Perl buildpack),
overriding the built-in Ruby buildpack at its confirmed real path,
`/tmp/buildpacks/01_buildpack-ruby` (verified live via `docker run --rm
gliderlabs/herokuish:v0.5.36-18 find / -maxdepth 4 -iname "*buildpack*" -type d` - matches our
original crash stack trace exactly).

Built and tested this locally against our real scraper before proposing it anywhere. Result:
**dead end**, for a reason deeper than expected.

- Pinning to `heroku-buildpack-ruby`'s latest `main` (`14ba6e8b`) fixes the lockfile error, but
  that same commit now hard-rejects the `heroku-18` stack outright ("the 'heroku-18' stack is no
  longer supported") - Heroku dropped it upstream.
- Pinning to an older commit from before that rejection was added (`9a1729e9`, "Stop bundling
  bootstrap Ruby", 2024-07-09) gets past the lockfile error too, but now fails trying to
  *download* a bootstrap Ruby from Heroku's own S3 bucket
  (`heroku-buildpack-ruby.s3.us-east-1.amazonaws.com/heroku-18/ruby-3.1.6.tgz`) - **403
  Forbidden**, confirmed not a network issue on our end (plain `curl` to google.com from the same
  container returns 200 fine).
- Checked the actual commit history of `lib/language_pack/helpers/bundler_wrapper.rb`: the
  commit that set the modern Bundler bootstrap default (`a88fe815`, "Default bundler to 2.5.23",
  **2026-02-02**) landed over a year *after* the switch to S3-downloaded bootstrap Ruby
  (`9a1729e9`, **2024-07-09**). Every commit with the fix already depends on the S3 download.
  There is no commit in this repo's history that has both "modern Bundler" and "no S3
  dependency" - they're structurally coupled.

**Conclusion: `heroku-18` is broken at the level of Heroku's own backing infrastructure, not
just an out-of-date pin in `buildstep`.** They've cut off `heroku-18`-specific S3 assets,
consistent with the stack being officially EOL. No Dockerfile patch on our side can route around
that - there's nothing left to pin to that both works and stays on `heroku-18`.

## What that means for the actual path forward

This isn't "patch `heroku-18`" vs "do nothing" anymore - it's "`heroku-18` is a dead end, so
`heroku-24` (the actually-current, actually-supported stack) is the only real path", which means
someone needs to go back and actually diagnose *why* `heroku-24` broke everything when it was
tried before (`openaustralia/morph#1456`/`#1440`, "nothing works on heroku-24") - that revert
was for reasons unrelated to this Bundler issue, and hasn't been investigated by us at all yet.

Worth filing the S3/heroku-18-EOL finding upstream regardless (in `heroku-buildpack-ruby` and/or
`gliderlabs/herokuish`) as a courtesy - it's useful, precise information even if it doesn't
unblock us directly.

## Next steps, in order

1. ~~Confirm the buildpack install path~~ - done.
2. ~~Try patching `buildstep`'s `heroku-18` image~~ - done, dead end (see above). Don't propose
   this Dockerfile change for real - it doesn't work.
3. **Diagnose why `heroku-24` failed** in `openaustralia/morph#1440`/`#1456` - read what actually
   broke, check if it's since been fixed independently, or root-cause it the same way we did
   here. This is now the actual blocking work.
4. Once something builds successfully: re-run `aotearoa_hansard` via `morph-cli`, confirm
   `hansard_records`/`sitting_calendar_events` actually populate in `data.sqlite`.
5. Get `aotearoa_hansard` (and `aotearoa_hansard_transcripts`) marked private (internal OAF ask,
   not a cold request - see README).
6. Confirm morph.io's scheduling behaviour (how often it re-runs a connected scraper) is sane
   for our rolling 14-day window.
7. **Not yet tested at all**: pulling this scraper's output back out via morph.io's own
   SQL-query API from the hotair Rails app - the other half of the design. Nothing built for
   this yet.
8. Once the build pipeline actually works, start `aotearoa_hansard_transcripts`: reproduce the
   Capybara/Selenium question (`openaustralia/morph#1337`) against a plain page first, isolated
   from Radware. Also worth checking whether whatever Chrome version `heroku-24` ships (136 as of
   last check, vs `heroku-18`'s 103) is new enough to get past Radware's bot-check on the real
   transcript pages, independent of the Selenium question.

## Parked, not blocking

- `morph-cli`'s own release (version bump + PR, mechanical, low priority - see that repo's
  `CHANGELOG.md`).
- Qlty coverage tracking for these repos - free open-source tier available
  (qlty.sh/auth/github), no need until there's an actual test suite worth tracking coverage on.
- Sentry - CLI installed, but the auth token's scope is too narrow (`org:ci` only, can't list
  projects) - revisit with a properly-scoped token when there's an actual error-tracking need.
