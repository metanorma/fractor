# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/log_analyzer/log_analyzer"
require "tempfile"
require "zlib"
require "zip"

RSpec.describe "Log Analyzer Example" do
  let(:sample_logs_dir) do
    File.expand_path("../../examples/log_analyzer/sample_logs", __dir__)
  end
  let(:reports_dir) do
    File.expand_path("../../examples/log_analyzer/reports", __dir__)
  end

  before do
    FileUtils.mkdir_p(reports_dir)
  end

  after do
    # Clean up test report files
    Dir.glob(File.join(reports_dir, "test_*.txt")).each { |f| File.delete(f) }
  end

  describe LogWork do
    describe "#initialize" do
      it "creates a work item with required parameters" do
        work = described_class.new(
          file_path: "/path/to/file.log",
          chunk_start: 0,
          chunk_size: 1024,
        )

        expect(work.file_path).to eq("/path/to/file.log")
        expect(work.chunk_start).to eq(0)
        expect(work.chunk_size).to eq(1024)
        expect(work.format).to eq(:auto)
      end

      it "accepts optional format parameter" do
        work = described_class.new(
          file_path: "/path/to/file.log",
          chunk_start: 0,
          chunk_size: 1024,
          format: :nginx,
        )

        expect(work.format).to eq(:nginx)
      end
    end

    describe "#to_s" do
      it "returns a readable string representation" do
        work = described_class.new(
          file_path: "/path/to/application.log",
          chunk_start: 1024,
          chunk_size: 2048,
        )

        expect(work.to_s).to eq("LogWork(application.log, 1024..3072)")
      end
    end
  end

  describe LogAnalyzerWorker do
    let(:worker) { described_class.new }

    describe "#detect_format" do
      it "detects JSON format" do
        lines = ['{"level":"INFO","message":"test"}']
        format = worker.send(:detect_format, lines, :auto)
        expect(format).to eq(:json)
      end

      it "detects Nginx format" do
        lines = ['192.168.1.1 [25/Oct/2024:13:55:36 +0800] "GET /api HTTP/1.1" 200 1234']
        format = worker.send(:detect_format, lines, :auto)
        expect(format).to eq(:nginx)
      end

      it "detects Apache format" do
        lines = ['127.0.0.1 - - [25/Oct/2024:13:55:36 +0800] "GET /index.html HTTP/1.1" 200 2326']
        format = worker.send(:detect_format, lines, :auto)
        expect(format).to eq(:apache)
      end

      it "detects Rails format" do
        lines = ["[2024-10-25 13:55:36] INFO -- : Application started"]
        format = worker.send(:detect_format, lines, :auto)
        expect(format).to eq(:rails)
      end

      it "uses generic format as fallback" do
        lines = ["Some random log line without recognized pattern"]
        format = worker.send(:detect_format, lines, :auto)
        expect(format).to eq(:generic)
      end

      it "respects explicitly requested format" do
        lines = ['{"level":"INFO","message":"test"}']
        format = worker.send(:detect_format, lines, :nginx)
        expect(format).to eq(:nginx)
      end
    end

    describe "#parse_apache_line" do
      it "parses valid Apache log line" do
        stats = {
          lines_processed: 0,
          errors: 0,
          warnings: 0,
          info: 0,
          debug: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
          status_codes: Hash.new(0),
          unique_ips: Set.new,
        }

        line = '127.0.0.1 - - [25/Oct/2024:13:55:36 +0800] "GET /index.html HTTP/1.1" 200 2326'
        worker.send(:parse_apache_line, line, stats)

        expect(stats[:unique_ips]).to include("127.0.0.1")
        expect(stats[:status_codes][200]).to eq(1)
        expect(stats[:info]).to eq(1)
      end

      it "identifies errors from 5xx status codes" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
          status_codes: Hash.new(0),
          unique_ips: Set.new,
        }

        line = '10.0.0.1 - - [25/Oct/2024:13:55:36 +0800] "POST /api/orders HTTP/1.1" 500 1024'
        worker.send(:parse_apache_line, line, stats)

        expect(stats[:errors]).to eq(1)
        expect(stats[:status_codes][500]).to eq(1)
        expect(stats[:error_messages]).not_to be_empty
      end

      it "identifies warnings from 4xx status codes" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
          status_codes: Hash.new(0),
          unique_ips: Set.new,
        }

        line = '192.168.1.1 - - [25/Oct/2024:13:55:36 +0800] "GET /admin HTTP/1.1" 403 128'
        worker.send(:parse_apache_line, line, stats)

        expect(stats[:warnings]).to eq(1)
        expect(stats[:status_codes][403]).to eq(1)
        expect(stats[:warning_messages]).not_to be_empty
      end
    end

    describe "#parse_nginx_line" do
      it "parses valid Nginx log line with response time" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
          status_codes: Hash.new(0),
          response_times: [],
          unique_ips: Set.new,
        }

        line = '192.168.1.1 [25/Oct/2024:13:55:36 +0800] "GET /api/users HTTP/1.1" 200 1234 0.123'
        worker.send(:parse_nginx_line, line, stats)

        expect(stats[:unique_ips]).to include("192.168.1.1")
        expect(stats[:status_codes][200]).to eq(1)
        expect(stats[:response_times]).to include(0.123)
        expect(stats[:info]).to eq(1)
      end

      it "handles missing response time" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
          status_codes: Hash.new(0),
          response_times: [],
          unique_ips: Set.new,
        }

        line = '192.168.1.1 [25/Oct/2024:13:55:36 +0800] "GET /api/users HTTP/1.1" 200 1234'
        worker.send(:parse_nginx_line, line, stats)

        expect(stats[:response_times]).to be_empty
      end
    end

    describe "#parse_rails_line" do
      it "parses Rails ERROR level" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          debug: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
        }

        line = "[2024-10-25 13:55:36] ERROR -- : Database connection failed"
        worker.send(:parse_rails_line, line, stats)

        expect(stats[:errors]).to eq(1)
        expect(stats[:error_messages]).not_to be_empty
        expect(stats[:timestamps]).not_to be_empty
      end

      it "parses Rails WARN level" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          debug: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
        }

        line = "[2024-10-25 13:55:36] WARN -- : High memory usage detected"
        worker.send(:parse_rails_line, line, stats)

        expect(stats[:warnings]).to eq(1)
        expect(stats[:warning_messages]).not_to be_empty
      end

      it "parses Rails INFO level" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          debug: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
        }

        line = "[2024-10-25 13:55:36] INFO -- : Request received"
        worker.send(:parse_rails_line, line, stats)

        expect(stats[:info]).to eq(1)
      end

      it "parses Rails DEBUG level" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          debug: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
        }

        line = "[2024-10-25 13:55:36] DEBUG -- : Processing parameters"
        worker.send(:parse_rails_line, line, stats)

        expect(stats[:debug]).to eq(1)
      end

      it "parses Rails FATAL level as error" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          debug: 0,
          error_messages: [],
          warning_messages: [],
          timestamps: [],
        }

        line = "[2024-10-25 13:55:36] FATAL -- : System crash"
        worker.send(:parse_rails_line, line, stats)

        expect(stats[:errors]).to eq(1)
      end
    end

    describe "#parse_json_line" do
      it "parses valid JSON log line" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          debug: 0,
          error_messages: [],
          warning_messages: [],
          status_codes: Hash.new(0),
          response_times: [],
          unique_ips: Set.new,
          timestamps: [],
        }

        line = '{"timestamp":"2024-10-25T13:55:36+08:00","level":"INFO","message":"Request received","status_code":200,"response_time":0.045,"ip":"192.168.1.1"}'
        worker.send(:parse_json_line, line, stats)

        expect(stats[:info]).to eq(1)
        expect(stats[:status_codes][200]).to eq(1)
        expect(stats[:response_times]).to include(0.045)
        expect(stats[:unique_ips]).to include("192.168.1.1")
      end

      it "handles ERROR level in JSON" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          error_messages: [],
          warning_messages: [],
          status_codes: Hash.new(0),
          response_times: [],
          unique_ips: Set.new,
          timestamps: [],
        }

        line = '{"level":"ERROR","message":"Database connection failed"}'
        worker.send(:parse_json_line, line, stats)

        expect(stats[:errors]).to eq(1)
        expect(stats[:error_messages]).to include("Database connection failed")
      end

      it "falls back to generic parsing for invalid JSON" do
        stats = {
          errors: 0,
          warnings: 0,
          info: 0,
          error_messages: [],
          warning_messages: [],
        }

        line = "This is not valid JSON but contains error keyword"
        worker.send(:parse_json_line, line, stats)

        expect(stats[:errors]).to eq(1)
      end
    end

    describe "#parse_generic_line" do
      it "detects error keywords" do
        stats = { errors: 0, warnings: 0, info: 0, error_messages: [],
                  warning_messages: [] }
        worker.send(:parse_generic_line, "An error occurred in the system",
                    stats)
        expect(stats[:errors]).to eq(1)
      end

      it "detects fail keywords" do
        stats = { errors: 0, warnings: 0, info: 0, error_messages: [],
                  warning_messages: [] }
        worker.send(:parse_generic_line, "Operation failed", stats)
        expect(stats[:errors]).to eq(1)
      end

      it "detects exception keywords" do
        stats = { errors: 0, warnings: 0, info: 0, error_messages: [],
                  warning_messages: [] }
        worker.send(:parse_generic_line, "NullPointerException thrown", stats)
        expect(stats[:errors]).to eq(1)
      end

      it "detects warning keywords" do
        stats = { errors: 0, warnings: 0, info: 0, error_messages: [],
                  warning_messages: [] }
        worker.send(:parse_generic_line, "Warning: disk space low", stats)
        expect(stats[:warnings]).to eq(1)
      end

      it "treats other lines as info" do
        stats = { errors: 0, warnings: 0, info: 0, error_messages: [],
                  warning_messages: [] }
        worker.send(:parse_generic_line, "Normal log message", stats)
        expect(stats[:info]).to eq(1)
      end
    end

    describe "#process" do
      it "processes LogWork and returns statistics" do
        apache_log = File.join(sample_logs_dir, "apache.log")
        work = LogWork.new(
          file_path: apache_log,
          chunk_start: 0,
          chunk_size: File.size(apache_log),
        )

        result = worker.process(work)

        expect(result).to be_a(Hash)
        expect(result[:lines_processed]).to be > 0
        expect(result[:format]).to eq(:apache)
        expect(result[:file]).to eq("apache.log")
      end

      it "returns nil for non-LogWork items" do
        result = worker.process("not a LogWork object")
        expect(result).to be_nil
      end
    end

    describe "file reading" do
      it "reads plain text chunks" do
        Tempfile.create(["test", ".log"]) do |f|
          f.write("Line 1\nLine 2\nLine 3\n")
          f.flush

          lines = worker.send(:read_plain_chunk, f.path, 0, 100)
          expect(lines.size).to eq(3)
        end
      end

      it "reads gzip chunks" do
        Tempfile.create(["test", ".log.gz"]) do |f|
          gz = Zlib::GzipWriter.new(f)
          gz.write("Line 1\nLine 2\nLine 3\n")
          gz.close

          lines = worker.send(:read_gzip_chunk, f.path, 0, 100)
          expect(lines.size).to be > 0
        end
      end

      it "handles EOFError gracefully" do
        Tempfile.create(["test", ".log"]) do |f|
          f.write("Short file")
          f.flush

          # Try to read beyond file size
          lines = worker.send(:read_plain_chunk, f.path, 0, 10000)
          expect(lines).not_to be_empty
        end
      end
    end
  end

  describe LogAnalyzer do
    let(:analyzer) { described_class.new(num_workers: 2, chunk_size: 512) }

    describe "#initialize" do
      it "sets default parameters" do
        default_analyzer = described_class.new
        expect(default_analyzer.num_workers).to eq(4)
        expect(default_analyzer.chunk_size).to eq(1024 * 1024)
      end

      it "accepts custom parameters" do
        custom_analyzer = described_class.new(num_workers: 8, chunk_size: 2048)
        expect(custom_analyzer.num_workers).to eq(8)
        expect(custom_analyzer.chunk_size).to eq(2048)
      end
    end

    describe "#analyze" do
      it "processes single file" do
        apache_log = File.join(sample_logs_dir, "apache.log")
        stats = analyzer.analyze([apache_log])

        expect(stats[:total_lines]).to be > 0
        expect(stats[:chunks_processed]).to be > 0
        expect(stats[:processing_time]).to be > 0
      end

      it "processes multiple files" do
        apache_log = File.join(sample_logs_dir, "apache.log")
        nginx_log = File.join(sample_logs_dir, "nginx.log")

        stats = analyzer.analyze([apache_log, nginx_log])

        expect(stats[:total_lines]).to be > 0
        expect(stats[:chunks_processed]).to be >= 2
      end

      it "skips non-existent files with warning" do
        expect do
          analyzer.analyze(["/path/to/nonexistent.log"])
        end.to output(/File not found/).to_stderr
      end

      it "detects multiple formats" do
        apache_log = File.join(sample_logs_dir, "apache.log")
        rails_log = File.join(sample_logs_dir, "rails.log")

        stats = analyzer.analyze([apache_log, rails_log])

        expect(stats[:formats_detected].keys).to include(:apache, :rails)
      end

      it "aggregates statistics correctly" do
        apache_log = File.join(sample_logs_dir, "apache.log")
        stats = analyzer.analyze([apache_log])

        expect(stats).to have_key(:total_lines)
        expect(stats).to have_key(:total_errors)
        expect(stats).to have_key(:total_warnings)
        expect(stats).to have_key(:total_info)
        expect(stats).to have_key(:status_codes)
        expect(stats).to have_key(:unique_ips)
      end

      it "uses specified format" do
        nginx_log = File.join(sample_logs_dir, "nginx.log")
        stats = analyzer.analyze([nginx_log], format: :nginx)

        expect(stats[:formats_detected][:nginx]).to be > 0
      end

      it "limits error messages to 100" do
        # Create a file with many errors
        Tempfile.create(["many_errors", ".log"]) do |f|
          200.times { |i| f.puts "ERROR: Error message #{i}" }
          f.flush

          stats = analyzer.analyze([f.path], format: :generic)
          expect(stats[:error_messages].size).to eq(100)
        end
      end
    end
  end

  describe LogReport do
    let(:sample_stats) do
      {
        total_lines: 1000,
        total_errors: 50,
        total_warnings: 100,
        total_info: 800,
        total_debug: 50,
        error_messages: ["Error 1", "Error 2"],
        warning_messages: ["Warning 1"],
        status_codes: { 200 => 700, 404 => 50, 500 => 50 },
        response_times: [0.1, 0.2, 0.3, 0.4, 0.5],
        unique_ips: ["192.168.1.1", "192.168.1.2"],
        formats_detected: { apache: 5, nginx: 3 },
        processing_time: 2.5,
        chunks_processed: 8,
      }
    end

    describe ".generate" do
      it "generates report to console" do
        expect do
          described_class.generate(sample_stats)
        end.to output(/LOG ANALYSIS REPORT/).to_stdout
      end

      it "saves report to file" do
        output_file = File.join(reports_dir, "test_report.txt")
        described_class.generate(sample_stats, output_file)

        expect(File.exist?(output_file)).to be true
        content = File.read(output_file)
        expect(content).to include("LOG ANALYSIS REPORT")
        expect(content).to include("Total lines processed: 1000")
      end
    end

    describe ".build_report" do
      let(:report) { described_class.build_report(sample_stats) }

      it "includes summary section" do
        expect(report).to include("SUMMARY")
        expect(report).to include("Total lines processed: 1000")
        expect(report).to include("Processing time: 2.50 seconds")
        expect(report).to include("Chunks processed: 8")
      end

      it "includes log levels section" do
        expect(report).to include("LOG LEVELS")
        expect(report).to include("Errors: 50 (5.0%)")
        expect(report).to include("Warnings: 100 (10.0%)")
        expect(report).to include("Info: 800 (80.0%)")
      end

      it "includes HTTP status codes section" do
        expect(report).to include("HTTP STATUS CODES")
        expect(report).to include("200: 700 requests")
        expect(report).to include("404: 50 requests")
        expect(report).to include("500: 50 requests")
      end

      it "includes response times section" do
        expect(report).to include("RESPONSE TIMES")
        expect(report).to include("Average:")
        expect(report).to include("Min:")
        expect(report).to include("Max:")
      end

      it "includes network section" do
        expect(report).to include("NETWORK")
        expect(report).to include("Unique IP addresses: 2")
      end

      it "includes formats detected section" do
        expect(report).to include("LOG FORMATS DETECTED")
        expect(report).to include("apache: 5 chunks")
        expect(report).to include("nginx: 3 chunks")
      end

      it "includes top errors section" do
        expect(report).to include("TOP ERRORS")
        expect(report).to include("Error 1")
        expect(report).to include("Error 2")
      end

      it "includes top warnings section" do
        expect(report).to include("TOP WARNINGS")
        expect(report).to include("Warning 1")
      end

      it "calculates lines per second" do
        expect(report).to include("Lines per second: 400")
      end
    end

    describe ".percentage" do
      it "calculates percentage correctly" do
        pct = described_class.percentage(25, 100)
        expect(pct).to eq(25.0)
      end

      it "handles zero total" do
        pct = described_class.percentage(10, 0)
        expect(pct).to eq(0.0)
      end
    end

    describe ".average" do
      it "calculates average correctly" do
        avg = described_class.average([1, 2, 3, 4, 5])
        expect(avg).to eq(3.0)
      end

      it "handles empty array" do
        avg = described_class.average([])
        expect(avg).to eq(0.0)
      end
    end
  end

  describe "Integration tests" do
    it "analyzes Apache log file end-to-end" do
      apache_log = File.join(sample_logs_dir, "apache.log")
      analyzer = LogAnalyzer.new(num_workers: 2)

      stats = analyzer.analyze([apache_log])

      expect(stats[:total_lines]).to be > 0
      expect(stats[:total_errors]).to be > 0
      expect(stats[:total_warnings]).to be > 0
      expect(stats[:status_codes].keys).to include(200, 500)
      expect(stats[:unique_ips]).not_to be_empty
    end

    it "analyzes Nginx log file end-to-end" do
      nginx_log = File.join(sample_logs_dir, "nginx.log")
      analyzer = LogAnalyzer.new(num_workers: 2)

      stats = analyzer.analyze([nginx_log])

      expect(stats[:total_lines]).to be > 0
      expect(stats[:response_times]).not_to be_empty
      expect(stats[:formats_detected][:nginx]).to be > 0
    end

    it "analyzes Rails log file end-to-end" do
      rails_log = File.join(sample_logs_dir, "rails.log")
      analyzer = LogAnalyzer.new(num_workers: 2)

      stats = analyzer.analyze([rails_log])

      expect(stats[:total_lines]).to be > 0
      expect(stats[:total_errors]).to be > 0
      expect(stats[:total_warnings]).to be > 0
      expect(stats[:formats_detected][:rails]).to be > 0
    end

    it "analyzes JSON log file end-to-end" do
      json_log = File.join(sample_logs_dir, "json.log")
      analyzer = LogAnalyzer.new(num_workers: 2)

      stats = analyzer.analyze([json_log])

      expect(stats[:total_lines]).to be > 0
      expect(stats[:formats_detected][:json]).to be > 0
    end

    it "generates complete report for real log file" do
      apache_log = File.join(sample_logs_dir, "apache.log")
      analyzer = LogAnalyzer.new(num_workers: 2)
      stats = analyzer.analyze([apache_log])

      output_file = File.join(reports_dir, "test_integration_report.txt")
      report = LogReport.generate(stats, output_file)

      expect(File.exist?(output_file)).to be true
      expect(report).to include("LOG ANALYSIS REPORT")
      expect(report).to include("SUMMARY")
      expect(report).to include("LOG LEVELS")
    end
  end
end
