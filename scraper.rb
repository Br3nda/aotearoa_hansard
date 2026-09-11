#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetches raw data from two NZ Parliament Hansard sources that don't need a browser:
#
# - The official Hansard search API (POST /api/data/search) - every Daily/Debate/DebateItem
#   record Hansard has indexed, paginated. Ruby's Net::HTTP defaults to "User-Agent: Ruby",
#   which this endpoint's bot protection blocks outright even though it otherwise has none at
#   all - send a real one.
# - parliament.nz's official House sitting calendar (.ics export) - a schedule of which days the
#   House sits, independent of whether Hansard has published anything for a given day yet.
#
# This scraper only stores *raw* content (upserted by whichever ID each source already gives
# us) - it does not parse it into structured records. That happens downstream, in the hotair
# Rails app itself, which pulls this data back out via morph.io's API.
#
# Headless-Chrome transcript fetching (needed to get past Radware on the actual per-day
# transcript pages) lives in a separate scraper - see aotearoa_hansard_transcripts - kept apart
# so a Selenium problem there can't take down these two working, browser-free fetches.

Bundler.require

require "scraperwiki"
require "net/http"
require "json"
require "date"

USER_AGENT = "aotearoa_hansard/1.0 (+https://github.com/Br3nda/aotearoa_hansard)"

# Fetches every Daily/Debate/DebateItem record Hansard's search API has indexed, paginated.
module HansardSearch
  URL = "https://hansard.parliament.nz/api/data/search"
  PAGE_SIZE = 50

  # Be gentle: cap how many pages either fetch below can take in a single run, spaced out
  # rather than fired in a burst. Raise HANSARD_MAX_PAGES for a deliberate one-off backfill.
  MAX_PAGES_PER_RUN = (ENV["HANSARD_MAX_PAGES"] || 5).to_i
  DELAY_BETWEEN_REQUESTS = 1 # seconds

  # How many days further back the historical backfill walks on each run - small and steady,
  # rather than requesting decades of history in one go. Raise HANSARD_BACKFILL_DAYS to speed
  # up a deliberate one-off backfill.
  BACKFILL_DAYS_PER_RUN = (ENV["HANSARD_BACKFILL_DAYS"] || 2).to_i

  # Recent rolling window, to stay current with newly-published/updated content - independent
  # of the backfill below, which only ever moves backwards through history.
  def self.recent_date_from
    ENV["HANSARD_DATE_FROM"] || (Date.today - 14).iso8601
  end

  def self.recent_date_to
    ENV["HANSARD_DATE_TO"] || Date.today.iso8601
  end

  # Where the backfill has reached, tracked explicitly rather than inferred from
  # MIN(sittingDate) - a fetch can be cut short by MAX_PAGES_PER_RUN, so what we've actually
  # saved isn't reliable evidence of what's been *fully* covered. On a brand new database,
  # start right where the recent window's own lower bound is, so the two don't overlap.
  def self.backfill_frontier
    rows = ScraperWiki.select("value AS d FROM scraper_state WHERE key = 'backfill_frontier'")
    date = rows.first && rows.first["d"]
    Date.parse(date || recent_date_from)
  rescue SqliteMagic::NoSuchTable
    Date.parse(recent_date_from)
  end

  def self.backfill_frontier=(date)
    ScraperWiki.save_sqlite(["key"], { "key" => "backfill_frontier", "value" => date.iso8601 }, "scraper_state")
  end

  def self.run
    fetch_range(date_from: recent_date_from, date_to: recent_date_to, label: "recent window")

    frontier = backfill_frontier
    backfill_to = frontier - 1
    backfill_from = backfill_to - BACKFILL_DAYS_PER_RUN + 1
    complete = fetch_range(date_from: backfill_from.iso8601, date_to: backfill_to.iso8601, label: "backfill")

    # Only move the frontier back if we're confident we actually got everything in this slice -
    # otherwise retry the same range next run rather than silently skip past ungrabbed data.
    self.backfill_frontier = backfill_from if complete
  end

  # Returns true if the whole range was fetched (didn't get cut short by MAX_PAGES_PER_RUN).
  def self.fetch_range(date_from:, date_to:, label:)
    page = 1
    total_saved = 0

    loop do
      records = post_search(date_from: date_from, date_to: date_to, page: page)
      break if records.empty?

      records.each { |record| save_record(record) }
      total_saved += records.size
      page += 1
      if page > MAX_PAGES_PER_RUN
        puts "hansard_records (#{label}): saved/updated #{total_saved} record(s) for " \
          "#{date_from}..#{date_to} (hit the #{MAX_PAGES_PER_RUN}-page cap, not fully covered yet)"
        return false
      end

      sleep DELAY_BETWEEN_REQUESTS
    end

    puts "hansard_records (#{label}): saved/updated #{total_saved} record(s) for #{date_from}..#{date_to}"
    true
  end

  def self.save_record(record)
    ScraperWiki.save_sqlite(
      ["id"],
      {
        "id" => record["id"],
        "documentType" => record["documentType"],
        "documentSubtype" => record["documentSubtype"],
        "sittingDate" => record["sittingDate"],
        "parentId" => record["parentId"],
        "raw_json" => record.to_json,
      },
      "hansard_records"
    )
  end

  def self.post_search(date_from:, date_to:, page:)
    uri = URI(URL)
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "User-Agent" => USER_AGENT)
    request.body = JSON.generate(dateFrom: date_from, dateTo: date_to, page: page, pageSize: PAGE_SIZE)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    raise "POST #{URL} failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).fetch("value")
  end
end

# Fetches parliament.nz's official House sitting calendar (.ics export).
module SittingCalendar
  URL = "https://www3.parliament.nz/en/calendar/icals"

  def self.run
    ics = fetch_ics
    unless ics.lstrip.start_with?("BEGIN:VCALENDAR")
      raise "GET #{URL} returned something that isn't an ICS file - " \
        "likely a bot-check page rather than real calendar data"
    end

    events = ics.split("BEGIN:VEVENT").drop(1).map { |block| block[0, block.index("END:VEVENT") || block.length] }

    saved = 0
    events.each do |block|
      uid = field(block, "UID")
      next unless uid

      ScraperWiki.save_sqlite(["uid"], { "uid" => uid, "raw_vevent" => block.strip }, "sitting_calendar_events")
      saved += 1
    end

    puts "sitting_calendar_events: saved/updated #{saved} event(s)"
  end

  def self.field(block, name)
    line = block.lines.find { |l| l.start_with?("#{name}:") || l.start_with?("#{name};") }
    line&.split(":", 2)&.last&.strip
  end

  # Past sitting dates don't change, so there's no need to re-fetch two decades of them every
  # routine run - just enough of a look-back to catch anything recently added/amended. Set
  # SITTING_CALENDAR_DATE_FROM to widen this for a one-off historical backfill.
  def self.date_from
    ENV["SITTING_CALENDAR_DATE_FROM"] || (Date.today - 90).iso8601
  end

  def self.fetch_ics
    uri = URI(URL)
    uri.query = URI.encode_www_form(
      "c.hb" => "true",
      "criteria.DateFrom" => date_from,
      "criteria.DateTo" => (Date.today + 2 * 365).iso8601
    )

    request = Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT)
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    raise "GET #{URL} failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end
end

if __FILE__ == $PROGRAM_NAME
  HansardSearch.run
  # SittingCalendar.run - deferred for now, not needed yet
end
