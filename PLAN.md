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

## The fix

Two independent, non-competing options:

1. **Patch `openaustralia/buildstep`'s `Dockerfile.heroku-18` directly** - add a second
   `herokuish buildpack install` call (same mechanism already used to add the Perl buildpack)
   pointing at a current `heroku-buildpack-ruby` ref, named to land at the same path as the
   built-in one so it overrides rather than duplicates. Fully within OAF's control, doesn't wait
   on anyone else.
   - **Confirmed live** (`docker run --rm gliderlabs/herokuish:v0.5.36-18 find / -maxdepth 4
     -iname "*buildpack*" -type d`): the built-in Ruby buildpack lives at
     `/tmp/buildpacks/01_buildpack-ruby` - matches the path in our original crash stack trace
     exactly. So the override call is:
     ```dockerfile
     RUN /bin/herokuish buildpack install https://github.com/heroku/heroku-buildpack-ruby.git <ref> 01_buildpack-ruby
     ```
     `<ref>` = a current `heroku-buildpack-ruby` tag/commit (need to pick one - HEAD of `main`,
     or their latest tagged release, whichever OAF would rather pin to for stability).
2. **File the pin bump upstream in `gliderlabs/herokuish` itself** - benefits everyone using
   herokuish, not just us, and the project looks responsive enough that this is worth doing as a
   courtesy alongside (1), not instead of it.

## Next steps, in order

1. ~~Confirm the buildpack install path~~ - done, see above.
2. Patch and rebuild `buildstep`'s `heroku-18` image with the ruby buildpack override.
3. Re-run `aotearoa_hansard` via `morph-cli` against the patched image, confirm
   `hansard_records`/`sitting_calendar_events` actually populate in `data.sqlite` this time.
4. Get `aotearoa_hansard` (and `aotearoa_hansard_transcripts`) marked private (internal OAF ask,
   not a cold request - see README).
5. Confirm morph.io's scheduling behaviour (how often it re-runs a connected scraper) is sane
   for our rolling 14-day window.
6. **Not yet tested at all**: pulling this scraper's output back out via morph.io's own
   SQL-query API from the hotair Rails app - the other half of the design. Nothing built for
   this yet.
7. Once (1)-(3) prove the build pipeline actually works, start `aotearoa_hansard_transcripts`:
   reproduce the Capybara/Selenium question (`openaustralia/morph#1337`) against a plain page
   first, isolated from Radware - see that repo once it exists. Also worth checking whether
   `heroku-18`'s pinned Chrome (103, June 2022) is even new enough to get past Radware's
   bot-check on the real transcript pages, independent of the Selenium question.

## Parked, not blocking

- `morph-cli`'s own release (version bump + PR, mechanical, low priority - see that repo's
  `CHANGELOG.md`).
- Qlty coverage tracking for these repos - free open-source tier available
  (qlty.sh/auth/github), no need until there's an actual test suite worth tracking coverage on.
- Sentry - CLI installed, but the auth token's scope is too narrow (`org:ci` only, can't list
  projects) - revisit with a properly-scoped token when there's an actual error-tracking need.
