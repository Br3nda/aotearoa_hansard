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

## The fix - confirmed working, tested end-to-end

Patched `openaustralia/buildstep`'s `Dockerfile.heroku-18` with a second `herokuish buildpack
install` call (same mechanism already used to add the Perl buildpack), overriding the built-in
Ruby buildpack at its confirmed real path, `/tmp/buildpacks/01_buildpack-ruby` (verified live via
`docker run --rm gliderlabs/herokuish:v0.5.36-18 find / -maxdepth 4 -iname "*buildpack*" -type d`
- matches our original crash stack trace exactly).

First attempt (pin to a commit with the lockfile fix, nothing else) turned out to be a dead end,
but a narrower one than it first looked:

- Latest `main` (`14ba6e8b`) fixes the lockfile error, but hard-rejects `heroku-18` outright
  ("the 'heroku-18' stack is no longer supported") - added in `173feef` ("Better errors on
  bootstrap failure", 2025-08-06), confirmed via `git log -S` and reading the actual diff (lists
  `heroku-18 | heroku-20` explicitly).
- An older commit (`9a1729e9`, "Stop bundling bootstrap Ruby", 2024-07-09) gets past the lockfile
  error, but fails downloading its *bootstrap* Ruby from Heroku's own S3 bucket - 403 Forbidden.
  Traced the bootstrap version to `buildpack.toml`'s own `ruby_version` field (read by
  `bin/support/download_ruby`, completely independent of anything in our scraper's own Gemfile).
- Checked every "default" bootstrap version between the S3-download switch and the heroku-18
  rejection (`3.1.6`, `3.3.7`, `3.3.8`, `3.3.9`, via direct `curl -I` against the S3 URLs) -
  **all 403 for heroku-18**. Heroku's S3 bucket for that stack looks pruned down to whatever was
  already cached before it went EOL, not the buildpack's own historical defaults.
- Tested other versions directly: `ruby-3.2.2` - which happens to be exactly what our own
  scraper's `Gemfile` already pins - **200 OK** on that same S3 path.

**The actual fix**: pin to `215828f` (`173feef`'s parent - the last commit before the heroku-18
rejection landed), *and* patch `buildpack.toml` to force `ruby_version = "3.2.2"` instead of
whatever that commit's own default happens to be:

```dockerfile
RUN /bin/herokuish buildpack install https://github.com/heroku/heroku-buildpack-ruby.git 215828f6cab08236e1f90f6935b5982cc3be4643 01_buildpack-ruby && \
    sed -i 's/ruby_version = ".*"/ruby_version = "3.2.2"/' /tmp/buildpacks/01_buildpack-ruby/buildpack.toml
```

**Confirmed end-to-end** against the real `aotearoa_hansard` scraper (`docker run --rm -v
.../aotearoa_hansard:/tmp/app <patched-image> /bin/herokuish buildpack build`): `Using Ruby
version: ruby-3.2.2`, `Bundle complete! 3 Gemfile dependencies, 21 gems now installed.` No
`LockfileError`, no download failure, no stack rejection. Already applied to the local
`buildstep` clone.

Filed as `openaustralia/morph#1530` (buildstep itself has issues disabled) - update that issue
with this working fix rather than the earlier "dead end" framing, which turned out to be too
pessimistic (it correctly ruled out the *naive* fix, but missed that the `buildpack.toml`
override sidesteps the S3 gap entirely).

**Does this force other scrapers onto a different Ruby version?** No - checked this explicitly,
not just assumed it. Tested the stock, *unpatched* `v362` setup against a scraper with an old,
Bundler-1.x-compatible lockfile (one that would never hit the bug this fixes) pinning a different
Ruby version (`3.3.9`) - it already fails the exact same way (`Using Ruby version: ruby-3.2.2` /
`Your Ruby version is 3.2.2, but your Gemfile specified 3.3.9`), with zero changes from us.
`heroku-18` already only supports one Ruby version platform-wide, and it's already `3.2.2` in
production today. This fix pins to that same version - it doesn't change which one is enforced,
only fixes the separate lockfile-reading bug. Opened as `openaustralia/buildstep#10`.

## Next steps, in order

1. ~~Confirm the buildpack install path~~ - done.
2. ~~Find a working buildpack pin~~ - done, see above. Confirmed working locally.
3. Get this actually merged/deployed in `openaustralia/buildstep` (real PR, or however OAF wants
   to land it - the change is one `RUN` line, already drafted and tested locally).
4. Re-run `aotearoa_hansard` via `morph-cli` **against morph.io itself** once the patched image is
   live there (not just the local Docker test), confirm `hansard_records`/`sitting_calendar_events`
   actually populate in `data.sqlite`.
5. Get `aotearoa_hansard` (and `aotearoa_hansard_transcripts`) marked private (internal OAF ask,
   not a cold request - see README).
6. Confirm morph.io's scheduling behaviour (how often it re-runs a connected scraper) is sane
   for our rolling 14-day window.
7. **Not yet tested at all**: pulling this scraper's output back out via morph.io's own
   SQL-query API from the hotair Rails app - the other half of the design. Nothing built for
   this yet.
8. Once the build pipeline is confirmed live, start `aotearoa_hansard_transcripts`: reproduce the
   Capybara/Selenium question (`openaustralia/morph#1337`) against a plain page first, isolated
   from Radware - same "test the narrow thing before building on it" approach that worked here.
   Also worth checking (same method: direct `curl -I` against the S3 bucket) whether
   `heroku-18`'s pinned chromedriver/Chrome (103, June 2022) has the same kind of asset gap, and
   whether `3.2.2`-style version pinning is needed there too.

## Parked, not blocking

- `morph-cli`'s own release (version bump + PR, mechanical, low priority - see that repo's
  `CHANGELOG.md`).
- Qlty coverage tracking for these repos - free open-source tier available
  (qlty.sh/auth/github), no need until there's an actual test suite worth tracking coverage on.
- Sentry - CLI installed, but the auth token's scope is too narrow (`org:ci` only, can't list
  projects) - revisit with a properly-scoped token when there's an actual error-tracking need.
