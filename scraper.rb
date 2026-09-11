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

  # Default to a recent rolling window for routine scheduled runs, rather than re-fetching the
  # entire multi-decade corpus every time - set HANSARD_DATE_FROM/HANSARD_DATE_TO to widen this
  # for a one-off historical backfill (e.g. via `morph-cli`).
  def self.date_from
    ENV["HANSARD_DATE_FROM"] || (Date.today - 14).iso8601
  end

  def self.date_to
    ENV["HANSARD_DATE_TO"] || Date.today.iso8601
  end

  def self.run
    page = 1
    total_saved = 0

    loop do
      records = post_search(page: page)
      break if records.empty?

      records.each do |record|
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

      total_saved += records.size
      page += 1
    end

    puts "hansard_records: saved/updated #{total_saved} record(s) for #{date_from}..#{date_to}"
  end

  def self.post_search(page:)
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

  def self.fetch_ics
    uri = URI(URL)
    uri.query = URI.encode_www_form(
      "c.hb" => "true",
      "criteria.DateFrom" => "2003-01-01",
      "criteria.DateTo" => (Date.today + 2 * 365).iso8601
    )

    request = Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT)
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    raise "GET #{URL} failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end
end

# TEMPORARY: fetches a trivial, non-Hansard URL so we can smoke-test morph.io's own build/run
# pipeline on heroku-24 in isolation, without Hansard's own quirks (Radware, pagination, etc.)
# in the way. Swap SmokeTest.run back for HansardSearch.run/SittingCalendar.run below once
# we've confirmed this scraper runs cleanly on morph.io.
module SmokeTest
  URL = "https://example.com"

  def self.run
    uri = URI(URL)
    request = Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT)
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    raise "GET #{URL} failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    ScraperWiki.save_sqlite(
      ["id"],
      { "id" => 1, "fetched_at" => Time.now.utc.iso8601, "body_length" => response.body.length },
      "smoke_test"
    )
    puts "smoke_test: fetched #{URL} OK (#{response.body.length} bytes)"
  end
end

if __FILE__ == $PROGRAM_NAME
  SmokeTest.run
  # HansardSearch.run
  # SittingCalendar.run
end
