# frozen_string_literal: true

# Syncs podcast feeds to disk. Generated for the fidelity harness.
require "json"
require_relative "feed"

module Feeds
  DEFAULT_RETRIES = 3

  class Syncer
    attr_reader :feeds, :errors

    def initialize(feeds, retries: DEFAULT_RETRIES, verbose: false)
      @feeds = feeds
      @retries = retries
      @verbose = verbose
      @errors = []
    end

    def run!
      feeds.each_with_index do |feed, index|
        log "#{index + 1}/#{feeds.size} #{feed.title}"
        sync(feed)
      rescue IOError => e
        @errors << e.message
      end
      self
    end

    def summary
      { synced: feeds.count - errors.count, failed: errors.count, at: Time.now.utc }
    end

    private

    def sync(feed)
      attempts = 0
      begin
        attempts += 1
        episodes = feed.fetch.select { |ep| ep[:url] && !ep[:hidden] }
        File.write("cache/#{feed.slug}.json", JSON.pretty_generate(episodes))
      rescue Timeout::Error
        retry if attempts < @retries
        raise IOError, "gave up on #{feed.slug} after #{attempts} tries"
      end
    end

    def log(message)
      puts message if @verbose
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  syncer = Feeds::Syncer.new(Feed.all, verbose: true).run!
  puts syncer.summary.to_json
  exit(syncer.errors.empty? ? 0 : 1)
end
