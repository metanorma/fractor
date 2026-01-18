# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/web_scraper/web_scraper"
require "fileutils"
require "webmock/rspec"

RSpec.describe WebScraper do
  let(:output_dir) { "spec/tmp/scraped_data" }

  before do
    FileUtils.rm_rf(output_dir) if File.exist?(output_dir)
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  after do
    FileUtils.rm_rf(output_dir) if File.exist?(output_dir)
    WebMock.allow_net_connect!
  end

  describe WebScraper::ScrapeWork do
    it "creates work with url and default attempt" do
      work = described_class.new("https://example.com")

      expect(work.url).to eq("https://example.com")
      expect(work.attempt).to eq(1)
    end

    it "creates work with custom attempt number" do
      work = described_class.new("https://example.com", attempt: 3)

      expect(work.url).to eq("https://example.com")
      expect(work.attempt).to eq(3)
    end

    it "has a string representation" do
      work = described_class.new("https://example.com", attempt: 2)

      expect(work.to_s).to include("ScrapeWork")
      expect(work.to_s).to include("https://example.com")
      expect(work.to_s).to include("attempt: 2")
    end

    it "inherits from Fractor::Work" do
      work = described_class.new("https://example.com")
      expect(work).to be_a(Fractor::Work)
    end
  end

  describe WebScraper::WebScraperWorker do
    let(:worker) { described_class.new }

    before do
      # Override output_dir for testing
      allow(worker).to receive(:instance_variable_get).with(:@output_dir).and_return(output_dir)
      worker.instance_variable_set(:@output_dir, output_dir)
      FileUtils.mkdir_p(output_dir)
    end

    describe "#process" do
      it "successfully scrapes and saves HTML content" do
        url = "https://example.com/page"
        html_content = "<html><body>Test Page</body></html>"

        stub_request(:get, url)
          .to_return(
            status: 200,
            body: html_content,
            headers: { "Content-Type" => "text/html" },
          )

        work = WebScraper::ScrapeWork.new(url)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:url]).to eq(url)
        expect(result.result[:status]).to eq("success")
        expect(result.result[:size]).to eq(html_content.length)

        # Check files were created
        files = Dir.glob("#{output_dir}/*.json")
        expect(files.length).to eq(1)

        json_file = files.first
        html_file = json_file.sub(".json", ".html")

        expect(File.exist?(json_file)).to be true
        expect(File.exist?(html_file)).to be true

        # Verify content
        saved_data = JSON.parse(File.read(json_file))
        expect(saved_data["url"]).to eq(url)
        expect(saved_data["content"]).to eq(html_content)
        expect(saved_data["content_type"]).to eq("text/html")

        saved_html = File.read(html_file)
        expect(saved_html).to eq(html_content)
      end

      it "successfully scrapes JSON content" do
        url = "https://api.example.com/data"
        json_content = '{"key": "value", "number": 42}'

        stub_request(:get, url)
          .to_return(
            status: 200,
            body: json_content,
            headers: { "Content-Type" => "application/json" },
          )

        work = WebScraper::ScrapeWork.new(url)
        result = worker.process(work)

        expect(result.success?).to be true

        # Verify JSON content saved
        files = Dir.glob("#{output_dir}/*.json")
        saved_data = JSON.parse(File.read(files.first))
        expect(saved_data["content_type"]).to eq("application/json")
      end

      it "handles HTTP errors" do
        url = "https://example.com/error"

        stub_request(:get, url)
          .to_return(status: 500, body: "Internal Server Error")

        work = WebScraper::ScrapeWork.new(url, attempt: 1)
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error.message).to include("HTTP Error")
        expect(result.error_context[:retriable]).to be true
        expect(result.error_context[:url]).to eq(url)
      end

      it "marks error as not retriable after max retries" do
        url = "https://example.com/permanent-error"

        stub_request(:get, url)
          .to_return(status: 404, body: "Not Found")

        work = WebScraper::ScrapeWork.new(url, attempt: 3) # Max retries
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error.message).to include("HTTP Error")
        expect(result.error_context[:retriable]).to be false
      end

      it "handles network timeouts" do
        url = "https://example.com/timeout"

        stub_request(:get, url).to_timeout

        work = WebScraper::ScrapeWork.new(url)
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error_context[:retriable]).to be true
      end

      it "handles connection errors" do
        url = "https://example.com/connection-error"

        stub_request(:get, url).to_raise(SocketError.new("Failed to connect"))

        work = WebScraper::ScrapeWork.new(url)
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error.message).to include("Failed to connect")
      end

      it "sets proper User-Agent header" do
        url = "https://example.com"

        stub = stub_request(:get, url)
          .with(headers: { "User-Agent" => /Fractor Web Scraper/ })
          .to_return(status: 200, body: "OK")

        work = WebScraper::ScrapeWork.new(url)
        worker.process(work)

        expect(stub).to have_been_requested
      end

      it "ignores non-ScrapeWork work types" do
        generic_work = Fractor::Work.new({ value: 1 })

        result = worker.process(generic_work)

        expect(result).to be_nil
      end
    end

    describe "rate limiting" do
      it "enforces minimum delay between requests to same domain" do
        url1 = "https://example.com/page1"
        url2 = "https://example.com/page2"

        stub_request(:get, url1).to_return(status: 200, body: "Page 1")
        stub_request(:get, url2).to_return(status: 200, body: "Page 2")

        work1 = WebScraper::ScrapeWork.new(url1)
        work2 = WebScraper::ScrapeWork.new(url2)

        start_time = Time.now
        worker.process(work1)
        worker.process(work2)
        elapsed = Time.now - start_time

        # Should have rate limit delay between requests
        expect(elapsed).to be >= WebScraper::WebScraperWorker::RATE_LIMIT_DELAY
      end

      it "does not delay requests to different domains" do
        url1 = "https://example1.com/page"
        url2 = "https://example2.com/page"

        stub_request(:get, url1).to_return(status: 200, body: "Page 1")
        stub_request(:get, url2).to_return(status: 200, body: "Page 2")

        work1 = WebScraper::ScrapeWork.new(url1)
        work2 = WebScraper::ScrapeWork.new(url2)

        start_time = Time.now
        worker.process(work1)
        worker.process(work2)
        elapsed = Time.now - start_time

        # Should be faster since different domains
        expect(elapsed).to be < WebScraper::WebScraperWorker::RATE_LIMIT_DELAY
      end
    end

    describe "retry context" do
      it "provides retry information in error context" do
        url = "https://example.com/retry-test"

        stub_request(:get, url)
          .to_return(status: 503, body: "Service Unavailable")

        # First attempt - should be retriable
        work1 = WebScraper::ScrapeWork.new(url, attempt: 1)
        result1 = worker.process(work1)
        expect(result1.error_context[:retriable]).to be true
        expect(result1.error_context[:attempt]).to eq(1)
        expect(result1.error_context[:max_retries]).to eq(3)

        # Last attempt - should not be retriable
        work3 = WebScraper::ScrapeWork.new(url, attempt: 3)
        result3 = worker.process(work3)
        expect(result3.error_context[:retriable]).to be false
        expect(result3.error_context[:attempt]).to eq(3)
      end
    end

    describe "file handling" do
      it "creates output directory on initialization" do
        new_dir = "spec/tmp/new_scraper_dir"
        FileUtils.rm_rf(new_dir) if File.exist?(new_dir)

        # Create a worker which should create the directory
        described_class.new
        # The default directory is "scraped_data", not our custom one
        # So we just check that scraped_data exists
        expect(File.directory?("scraped_data")).to be true
      end

      it "generates unique filenames for same URL" do
        url = "https://example.com/page"

        stub_request(:get, url)
          .to_return(status: 200, body: "Content")

        work1 = WebScraper::ScrapeWork.new(url)
        work2 = WebScraper::ScrapeWork.new(url)

        worker.process(work1)
        sleep(1.1) # Ensure different timestamp
        worker.process(work2)

        files = Dir.glob("#{output_dir}/*.json")
        expect(files.length).to eq(2)
        expect(files[0]).not_to eq(files[1])
      end

      it "sanitizes filenames properly" do
        url = "https://example.com/path/with/special?chars=test&foo=bar"

        stub_request(:get, url)
          .to_return(status: 200, body: "Content")

        work = WebScraper::ScrapeWork.new(url)
        worker.process(work)

        files = Dir.glob("#{output_dir}/*")
        filename = File.basename(files.first)

        # Should only contain safe characters
        expect(filename).to match(/^[a-zA-Z0-9_-]+\.(json|html)$/)
      end
    end
  end

  describe WebScraper::ProgressTracker do
    let(:tracker) { described_class.new(10) }

    it "initializes with total URLs" do
      expect(tracker.instance_variable_get(:@total_urls)).to eq(10)
      expect(tracker.instance_variable_get(:@completed)).to eq(0)
      expect(tracker.instance_variable_get(:@successful)).to eq(0)
      expect(tracker.instance_variable_get(:@failed)).to eq(0)
    end

    it "updates progress for successful result" do
      result = Fractor::WorkResult.new(
        result: { url: "https://example.com" },
        work: WebScraper::ScrapeWork.new("https://example.com"),
      )

      expect { tracker.update(result) }.to output(/Progress/).to_stdout

      expect(tracker.instance_variable_get(:@completed)).to eq(1)
      expect(tracker.instance_variable_get(:@successful)).to eq(1)
      expect(tracker.instance_variable_get(:@failed)).to eq(0)
    end

    it "updates progress for failed result" do
      result = Fractor::WorkResult.new(
        error: StandardError.new("Error message"),
        work: WebScraper::ScrapeWork.new("https://example.com"),
        error_context: { url: "https://example.com" },
      )

      expect { tracker.update(result) }.to output(/Progress/).to_stdout

      expect(tracker.instance_variable_get(:@completed)).to eq(1)
      expect(tracker.instance_variable_get(:@successful)).to eq(0)
      expect(tracker.instance_variable_get(:@failed)).to eq(1)
    end

    it "counts all failures" do
      result = Fractor::WorkResult.new(
        error: StandardError.new("Error"),
        work: WebScraper::ScrapeWork.new("https://example.com"),
        error_context: { url: "https://example.com" },
      )

      tracker.update(result)

      expect(tracker.instance_variable_get(:@failed)).to eq(1)
    end

    it "prints summary with statistics" do
      # Simulate some results
      3.times do
        result = Fractor::WorkResult.new(
          result: {},
          work: WebScraper::ScrapeWork.new("https://example.com"),
        )
        tracker.update(result)
      end

      expect { tracker.summary }.to output(/SCRAPING COMPLETE/).to_stdout
      expect { tracker.summary }.to output(/Total URLs: 10/).to_stdout
      expect { tracker.summary }.to output(/Successful: 3/).to_stdout
    end

    it "is thread-safe" do
      threads = []
      10.times do |_i| # rubocop:disable Lint/UnusedBlockArgument
        threads << Thread.new do
          result = Fractor::WorkResult.new(
            result: {},
            work: WebScraper::ScrapeWork.new("https://example.com"),
          )
          tracker.update(result)
        end
      end

      threads.each(&:join)

      expect(tracker.instance_variable_get(:@completed)).to eq(10)
    end
  end

  describe "Integration" do
    it "components work together" do
      # This test verifies the basic integration without Ractor complexity
      worker = WebScraper::WebScraperWorker.new
      tracker = WebScraper::ProgressTracker.new(2)

      url1 = "https://example.com/test1"
      url2 = "https://example.com/test2"

      stub_request(:get, url1).to_return(status: 200, body: "Test 1")
      stub_request(:get, url2).to_return(status: 404, body: "Not Found")

      work1 = WebScraper::ScrapeWork.new(url1)
      work2 = WebScraper::ScrapeWork.new(url2)

      result1 = worker.process(work1)
      result2 = worker.process(work2)

      expect(result1.success?).to be true
      expect(result2.success?).to be false

      # Verify tracking works
      tracker.update(result1)
      tracker.update(result2)

      expect(tracker.instance_variable_get(:@successful)).to eq(1)
      expect(tracker.instance_variable_get(:@failed)).to eq(1)
    end
  end
end
