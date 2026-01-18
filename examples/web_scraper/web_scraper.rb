#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/fractor"
require "net/http"
require "uri"
require "json"
require "fileutils"

module WebScraper
  # Represents a URL to be scraped
  class ScrapeWork < Fractor::Work
  def initialize(url, attempt: 1)
    super({ url: url, attempt: attempt })
  end

  def url
    input[:url]
  end

  def attempt
    input[:attempt]
  end

  def to_s
    "ScrapeWork(url: #{url}, attempt: #{attempt})"
  end
end

# Worker that scrapes URLs with rate limiting and retry logic
  class WebScraperWorker < Fractor::Worker
  MAX_RETRIES = 3
  RETRY_DELAYS = [1, 2, 4].freeze # Exponential backoff in seconds
  RATE_LIMIT_DELAY = 0.5 # 500ms between requests

  def initialize
    super()
    @output_dir = "scraped_data"
    @last_request_time = {}
    @request_count = 0
    @worker_id = "#{object_id}"
    FileUtils.mkdir_p(@output_dir)
  end

  def worker_id
    @worker_id
  end

  def process(work)
    return nil unless work.is_a?(ScrapeWork)

    url = work.url
    attempt = work.attempt

    begin
      # Rate limiting: ensure minimum delay between requests
      enforce_rate_limit(url)

      # Fetch the URL
      puts "[Worker #{worker_id}] Scraping #{url} (attempt #{attempt}/#{MAX_RETRIES})"
      response = fetch_url(url)

      # Parse and save the data
      data = parse_response(response, url)
      save_data(url, data)

      @request_count += 1
      puts "[Worker #{worker_id}] ✓ Successfully scraped #{url}"

      Fractor::WorkResult.new(
        result: { url: url, status: "success", size: data[:content].length },
        work: work
      )
    rescue StandardError => e
      handle_error(work, e)
    end
  end

  private

  def enforce_rate_limit(url)
    domain = extract_domain(url)
    last_time = @last_request_time[domain]

    if last_time
      elapsed = Time.now - last_time
      if elapsed < RATE_LIMIT_DELAY
        sleep_time = RATE_LIMIT_DELAY - elapsed
        puts "[Worker #{worker_id}] Rate limiting: sleeping #{sleep_time.round(2)}s for #{domain}"
        sleep(sleep_time)
      end
    end

    @last_request_time[domain] = Time.now
  end

  def fetch_url(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = "Fractor Web Scraper Example/1.0"

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise "HTTP Error: #{response.code} #{response.message}"
    end

    response
  end

  def parse_response(response, url)
    content = response.body
    content_type = response["content-type"] || "unknown"

    {
      url: url,
      content: content,
      content_type: content_type,
      size: content.length,
      timestamp: Time.now.iso8601,
      headers: response.to_hash
    }
  end

  def save_data(url, data)
    filename = generate_filename(url)
    filepath = File.join(@output_dir, filename)

    File.write("#{filepath}.json", JSON.pretty_generate(data))
    File.write("#{filepath}.html", data[:content])

    puts "[Worker #{worker_id}] Saved to #{filepath}"
  end

  def generate_filename(url)
    uri = URI.parse(url)
    sanitized = "#{uri.host}#{uri.path}".gsub(/[^a-zA-Z0-9_-]/, "_")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    "#{sanitized}_#{timestamp}"
  end

  def extract_domain(url)
    URI.parse(url).host
  rescue StandardError
    "unknown"
  end

  def handle_error(work, error)
    puts "[Worker #{worker_id}] ✗ Error scraping #{work.url}: #{error.message}"

    # Return error with context about retry potential
    Fractor::WorkResult.new(
      error: error,
      work: work,
      error_context: {
        url: work.url,
        attempt: work.attempt,
        max_retries: MAX_RETRIES,
        retriable: work.attempt < MAX_RETRIES
      }
    )
  end
end

# Progress tracker for monitoring scraping progress
  class ProgressTracker
  def initialize(total_urls)
    @total_urls = total_urls
    @completed = 0
    @successful = 0
    @failed = 0
    @start_time = Time.now
    @mutex = Mutex.new
  end

  def update(result)
    @mutex.synchronize do
      @completed += 1
      if result.success?
        @successful += 1
      else
        @failed += 1
      end

      print_progress
    end
  end

  def print_progress
    percentage = (@completed.to_f / @total_urls * 100).round(1)
    elapsed = Time.now - @start_time
    rate = @completed / elapsed

    puts "\n" + "=" * 60
    puts "Progress: #{@completed}/#{@total_urls} (#{percentage}%)"
    puts "Successful: #{@successful} | Failed: #{@failed}"
    puts "Elapsed: #{elapsed.round(1)}s | Rate: #{rate.round(2)} URLs/s"
    puts "=" * 60 + "\n"
  end

  def summary
    elapsed = Time.now - @start_time

    puts "\n" + "=" * 60
    puts "SCRAPING COMPLETE"
    puts "=" * 60
    puts "Total URLs: #{@total_urls}"
    puts "Successful: #{@successful}"
    puts "Failed: #{@failed}"
    puts "Total time: #{elapsed.round(2)}s"
    puts "Average rate: #{(@total_urls / elapsed).round(2)} URLs/s"
    puts "=" * 60 + "\n"
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  # Example URLs to scrape (using httpbin.org for testing)
  urls = [
    "https://httpbin.org/html",
    "https://httpbin.org/json",
    "https://httpbin.org/xml",
    "https://httpbin.org/robots.txt",
    "https://httpbin.org/deny", # Will return 403 to test error handling
    "https://httpbin.org/status/500", # Will return 500 to test retries
    "https://httpbin.org/delay/2", # Slow response
    "https://httpbin.org/user-agent",
    "https://httpbin.org/headers",
    "https://httpbin.org/ip"
  ]

  puts "Starting Web Scraper Example"
  puts "URLs to scrape: #{urls.length}"
  puts "Workers: 3"
  puts "Rate limit: 500ms between requests per domain"
  puts "Max retries: 3 with exponential backoff"
  puts "\n"

  # Create output directory
  output_dir = "scraped_data"
  FileUtils.rm_rf(output_dir) if File.exist?(output_dir)

  # Create progress tracker
  tracker = WebScraper::ProgressTracker.new(urls.length)

  # Create supervisor with 3 workers
  supervisor = Fractor::Supervisor.new(
    worker_pools: [
      { worker_class: WebScraper::WebScraperWorker, num_workers: 3 }
    ]
  )

  # Submit all URLs
  work_items = urls.map { |url| WebScraper::ScrapeWork.new(url) }
  supervisor.add_work_items(work_items)

  # Start the supervisor
  supervisor.run

  # Collect results and update tracker
  results = supervisor.results
  (results.results + results.errors).each do |result|
    tracker.update(result)
  end

  # Print summary
  tracker.summary

  # Print details of failures
  failures = results.errors
  if failures.any?
    puts "\nFailed URLs:"
    failures.each do |result|
      puts "  - #{result.error_context[:url]}: #{result.error.message}"
    end
  end

  puts "\nData saved to: #{output_dir}/"
end
end