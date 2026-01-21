#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/fractor"
require "zlib"
require "zip"
require "json"
require "time"
require "benchmark"

# Work item for log chunk processing
class LogWork < Fractor::Work
  attr_reader :file_path, :chunk_start, :chunk_size, :format

  def initialize(file_path:, chunk_start:, chunk_size:, format: :auto)
    @file_path = file_path
    @chunk_start = chunk_start
    @chunk_size = chunk_size
    @format = format
    # Pass a hash as input to satisfy Fractor::Work's requirement
    super({ file_path: file_path, chunk_start: chunk_start, chunk_size: chunk_size, format: format })
  end

  def to_s
    "LogWork(#{File.basename(file_path)}, #{chunk_start}..#{chunk_start + chunk_size})"
  end
end

# Worker for processing log chunks
class LogAnalyzerWorker < Fractor::Worker
  def process(work)
    return nil unless work.is_a?(LogWork)

    lines = read_chunk(work.file_path, work.chunk_start, work.chunk_size)
    format = detect_format(lines, work.format)

    stats = {
      file: File.basename(work.file_path),
      chunk_start: work.chunk_start,
      chunk_size: work.chunk_size,
      lines_processed: 0,
      errors: 0,
      warnings: 0,
      info: 0,
      debug: 0,
      error_messages: [],
      warning_messages: [],
      timestamps: [],
      status_codes: Hash.new(0),
      response_times: [],
      unique_ips: Set.new,
      format: format
    }

    lines.each do |line|
      next if line.strip.empty?

      stats[:lines_processed] += 1
      parse_line(line, format, stats)
    end

    # Convert Set to Array for serialization
    stats[:unique_ips] = stats[:unique_ips].to_a
    stats
  end

  private

  def read_chunk(file_path, start, size)
    if file_path.end_with?(".gz")
      read_gzip_chunk(file_path, start, size)
    elsif file_path.end_with?(".zip")
      read_zip_chunk(file_path, start, size)
    else
      read_plain_chunk(file_path, start, size)
    end
  end

  def read_plain_chunk(file_path, start, size)
    lines = []
    File.open(file_path, "r") do |f|
      f.seek(start)
      content = f.read(size)
      return [] unless content

      # Split on newlines without using global $/
      lines = content.split("\n")
      # Add back the newline to each line except potentially the last
      lines = lines.map { |line| line + "\n" }
    end
    lines
  rescue EOFError, Errno::EINVAL
    lines
  end

  def read_gzip_chunk(file_path, start, size)
    lines = []
    Zlib::GzipReader.open(file_path) do |gz|
      # For gzip, read the entire content and split
      content = gz.read
      all_lines = content.split("\n").map { |line| line + "\n" }

      # Calculate which lines fall in our chunk range
      current_pos = 0
      start_line = 0
      all_lines.each_with_index do |line, idx|
        if current_pos >= start
          start_line = idx
          break
        end
        current_pos += line.bytesize
      end

      # Collect lines until we reach size limit
      read_size = 0
      all_lines[start_line..-1].each do |line|
        break if read_size >= size
        lines << line
        read_size += line.bytesize
      end
    end
    lines
  rescue EOFError, Zlib::GzipFile::Error
    lines
  end

  def read_zip_chunk(file_path, start, size)
    lines = []
    Zip::File.open(file_path) do |zip_file|
      # Process first entry only
      entry = zip_file.entries.first
      next unless entry

      content = entry.get_input_stream.read
      lines = content.lines[start / 100, size / 100] || []
    end
    lines
  rescue Zip::Error
    lines
  end

  def detect_format(lines, requested_format)
    return requested_format unless requested_format == :auto

    sample = lines.first(5).join("\n")

    if sample.match?(/^\{/)
      :json
    elsif sample.match?(/^\d+\.\d+\.\d+\.\d+ - - \[/)
      :apache
    elsif sample.match?(/\[.*\] "(GET|POST|PUT|DELETE|PATCH)/)
      :nginx
    elsif sample.match?(/\] (ERROR|WARN|INFO|DEBUG|FATAL) -- /)
      :rails
    else
      :generic
    end
  end

  def parse_line(line, format, stats)
    case format
    when :apache
      parse_apache_line(line, stats)
    when :nginx
      parse_nginx_line(line, stats)
    when :rails
      parse_rails_line(line, stats)
    when :json
      parse_json_line(line, stats)
    else
      parse_generic_line(line, stats)
    end
  end

  def parse_apache_line(line, stats)
    # Apache format: 127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] "GET /index.html HTTP/1.0" 200 2326
    if line =~ /^(\S+) \S+ \S+ \[(.*?)\] "(\S+) (\S+) (\S+)" (\d+) (\d+)/
      ip = Regexp.last_match(1)
      timestamp = Regexp.last_match(2)
      method = Regexp.last_match(3)
      path = Regexp.last_match(4)
      status = Regexp.last_match(6).to_i
      bytes = Regexp.last_match(7).to_i

      stats[:unique_ips] << ip
      stats[:status_codes][status] += 1
      stats[:timestamps] << timestamp

      if status >= 500
        stats[:errors] += 1
        stats[:error_messages] << "#{method} #{path} - Status #{status}"
      elsif status >= 400
        stats[:warnings] += 1
        stats[:warning_messages] << "#{method} #{path} - Status #{status}"
      else
        stats[:info] += 1
      end
    end
  end

  def parse_nginx_line(line, stats)
    # Nginx format: 192.168.1.1 [10/Oct/2000:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 1234 0.123
    if line =~ /^(\S+) \[(.*?)\] "(\S+) (\S+) (\S+)" (\d+) (\d+)(?: (\d+\.\d+))?/
      ip = Regexp.last_match(1)
      timestamp = Regexp.last_match(2)
      method = Regexp.last_match(3)
      path = Regexp.last_match(4)
      status = Regexp.last_match(6).to_i
      bytes = Regexp.last_match(7).to_i
      response_time = Regexp.last_match(8)&.to_f

      stats[:unique_ips] << ip
      stats[:status_codes][status] += 1
      stats[:timestamps] << timestamp
      stats[:response_times] << response_time if response_time

      if status >= 500
        stats[:errors] += 1
        stats[:error_messages] << "#{method} #{path} - Status #{status}"
      elsif status >= 400
        stats[:warnings] += 1
        stats[:warning_messages] << "#{method} #{path} - Status #{status}"
      else
        stats[:info] += 1
      end
    end
  end

  def parse_rails_line(line, stats)
    # Rails format: [2024-10-25 12:00:00] ERROR -- : Failed to connect to database
    if line =~ /\[(.*?)\] (ERROR|WARN|INFO|DEBUG|FATAL)/
      timestamp = Regexp.last_match(1)
      level = Regexp.last_match(2)

      stats[:timestamps] << timestamp

      case level
      when "ERROR", "FATAL"
        stats[:errors] += 1
        stats[:error_messages] << line.strip
      when "WARN"
        stats[:warnings] += 1
        stats[:warning_messages] << line.strip
      when "INFO"
        stats[:info] += 1
      when "DEBUG"
        stats[:debug] += 1
      end
    end
  end

  def parse_json_line(line, stats)
    begin
      data = JSON.parse(line)
      level = data["level"] || data["severity"] || "INFO"
      timestamp = data["timestamp"] || data["time"]
      message = data["message"] || data["msg"]

      stats[:timestamps] << timestamp if timestamp

      case level.upcase
      when "ERROR", "FATAL"
        stats[:errors] += 1
        stats[:error_messages] << message if message
      when "WARN", "WARNING"
        stats[:warnings] += 1
        stats[:warning_messages] << message if message
      when "INFO"
        stats[:info] += 1
      when "DEBUG"
        stats[:debug] += 1
      end

      if data["status_code"]
        stats[:status_codes][data["status_code"]] += 1
      end

      if data["response_time"]
        stats[:response_times] << data["response_time"]
      end

      if data["ip"] || data["remote_addr"]
        stats[:unique_ips] << (data["ip"] || data["remote_addr"])
      end
    rescue JSON::ParserError
      # Treat as generic line if JSON parsing fails
      parse_generic_line(line, stats)
    end
  end

  def parse_generic_line(line, stats)
    if line =~ /error|fail|exception/i
      stats[:errors] += 1
      stats[:error_messages] << line.strip
    elsif line =~ /warn|warning/i
      stats[:warnings] += 1
      stats[:warning_messages] << line.strip
    else
      stats[:info] += 1
    end
  end
end

# Log analyzer that processes files in parallel
class LogAnalyzer
  attr_reader :num_workers, :chunk_size

  def initialize(num_workers: 4, chunk_size: 1024 * 1024)
    @num_workers = num_workers
    @chunk_size = chunk_size
  end

  def analyze(file_paths, format: :auto)
    work_items = []

    file_paths.each do |file_path|
      unless File.exist?(file_path)
        warn "File not found: #{file_path}"
        next
      end

      file_size = File.size(file_path)
      num_chunks = (file_size.to_f / chunk_size).ceil

      num_chunks.times do |i|
        chunk_start = i * chunk_size
        current_chunk_size = [chunk_size, file_size - chunk_start].min

        work_items << LogWork.new(
          file_path: file_path,
          chunk_start: chunk_start,
          chunk_size: current_chunk_size,
          format: format
        )
      end
    end

    puts "Processing #{work_items.size} chunks from #{file_paths.size} file(s)..."

    time = Benchmark.realtime do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: LogAnalyzerWorker, num_workers: num_workers }
        ]
      )

      supervisor.add_work_items(work_items)
      supervisor.run

      results = supervisor.results
      @results = results.results + results.errors
    end

    aggregate_results(@results, time)
  end

  private

  def aggregate_results(results, processing_time)
    aggregated = {
      total_lines: 0,
      total_errors: 0,
      total_warnings: 0,
      total_info: 0,
      total_debug: 0,
      error_messages: [],
      warning_messages: [],
      status_codes: Hash.new(0),
      response_times: [],
      unique_ips: Set.new,
      formats_detected: Hash.new(0),
      processing_time: processing_time,
      chunks_processed: 0
    }

    results.each do |work_result|
      next unless work_result

      # Extract actual result from WorkResult object
      result = work_result.respond_to?(:result) ? work_result.result : work_result

      next unless result.is_a?(Hash)

      aggregated[:chunks_processed] += 1
      aggregated[:total_lines] += result[:lines_processed] || 0
      aggregated[:total_errors] += result[:errors] || 0
      aggregated[:total_warnings] += result[:warnings] || 0
      aggregated[:total_info] += result[:info] || 0
      aggregated[:total_debug] += result[:debug] || 0
      aggregated[:error_messages].concat(result[:error_messages] || [])
      aggregated[:warning_messages].concat(result[:warning_messages] || [])
      aggregated[:formats_detected][result[:format]] += 1 if result[:format]

      if result[:status_codes]
        result[:status_codes].each do |code, count|
          aggregated[:status_codes][code] += count
        end
      end

      aggregated[:response_times].concat(result[:response_times] || [])

      if result[:unique_ips]
        aggregated[:unique_ips].merge(result[:unique_ips])
      end
    end

    # Limit message arrays to avoid excessive memory usage
    aggregated[:error_messages] = aggregated[:error_messages].first(100)
    aggregated[:warning_messages] = aggregated[:warning_messages].first(100)

    aggregated
  end
end

# Report generator
class LogReport
  def self.generate(stats, output_file = nil)
    report = build_report(stats)

    if output_file
      File.write(output_file, report)
      puts "Report saved to #{output_file}"
    else
      puts report
    end

    report
  end

  def self.build_report(stats)
    lines = []
    lines << "=" * 80
    lines << "LOG ANALYSIS REPORT"
    lines << "=" * 80
    lines << ""

    # Summary
    lines << "SUMMARY"
    lines << "-" * 80
    lines << format("Total lines processed: %d", stats[:total_lines])
    lines << format("Processing time: %.2f seconds", stats[:processing_time])
    lines << format("Lines per second: %.0f", stats[:total_lines] / stats[:processing_time])
    lines << format("Chunks processed: %d", stats[:chunks_processed])
    lines << ""

    # Log levels
    lines << "LOG LEVELS"
    lines << "-" * 80
    lines << format("Errors: %d (%.1f%%)", stats[:total_errors], percentage(stats[:total_errors], stats[:total_lines]))
    lines << format("Warnings: %d (%.1f%%)", stats[:total_warnings], percentage(stats[:total_warnings], stats[:total_lines]))
    lines << format("Info: %d (%.1f%%)", stats[:total_info], percentage(stats[:total_info], stats[:total_lines]))
    lines << format("Debug: %d (%.1f%%)", stats[:total_debug], percentage(stats[:total_debug], stats[:total_lines]))
    lines << ""

    # HTTP Status codes
    unless stats[:status_codes].empty?
      lines << "HTTP STATUS CODES"
      lines << "-" * 80
      stats[:status_codes].sort.each do |code, count|
        lines << format("  %d: %d requests", code, count)
      end
      lines << ""
    end

    # Response times
    unless stats[:response_times].empty?
      lines << "RESPONSE TIMES"
      lines << "-" * 80
      lines << format("  Average: %.3f seconds", average(stats[:response_times]))
      lines << format("  Min: %.3f seconds", stats[:response_times].min)
      lines << format("  Max: %.3f seconds", stats[:response_times].max)
      lines << ""
    end

    # Unique IPs
    unless stats[:unique_ips].empty?
      lines << "NETWORK"
      lines << "-" * 80
      lines << format("Unique IP addresses: %d", stats[:unique_ips].size)
      lines << ""
    end

    # Formats detected
    lines << "LOG FORMATS DETECTED"
    lines << "-" * 80
    stats[:formats_detected].each do |format, count|
      lines << format("  %s: %d chunks", format, count)
    end
    lines << ""

    # Top errors
    unless stats[:error_messages].empty?
      lines << "TOP ERRORS (up to 10)"
      lines << "-" * 80
      stats[:error_messages].first(10).each_with_index do |msg, i|
        lines << format("%2d. %s", i + 1, msg[0, 100])
      end
      lines << ""
    end

    # Top warnings
    unless stats[:warning_messages].empty?
      lines << "TOP WARNINGS (up to 10)"
      lines << "-" * 80
      stats[:warning_messages].first(10).each_with_index do |msg, i|
        lines << format("%2d. %s", i + 1, msg[0, 100])
      end
      lines << ""
    end

    lines << "=" * 80

    lines.join("\n")
  end

  def self.percentage(part, total)
    return 0.0 if total.zero?

    (part.to_f / total * 100)
  end

  def self.average(numbers)
    return 0.0 if numbers.empty?

    numbers.sum.to_f / numbers.size
  end
end

# Run example if executed directly
if __FILE__ == $PROGRAM_NAME
  require "optparse"

  options = {
    workers: 4,
    chunk_size: 1024 * 1024,
    format: :auto,
    output: nil
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: log_analyzer.rb [options] FILE..."

    opts.on("-w", "--workers NUM", Integer, "Number of worker ractors (default: 4)") do |n|
      options[:workers] = n
    end

    opts.on("-c", "--chunk-size SIZE", Integer, "Chunk size in bytes (default: 1MB)") do |s|
      options[:chunk_size] = s
    end

    opts.on("-f", "--format FORMAT", [:auto, :apache, :nginx, :rails, :json, :generic],
            "Log format (auto, apache, nginx, rails, json, generic)") do |f|
      options[:format] = f
    end

    opts.on("-o", "--output FILE", "Output report file") do |f|
      options[:output] = f
    end

    opts.on("-h", "--help", "Show this message") do
      puts opts
      exit
    end
  end.parse!

  if ARGV.empty?
    puts "Error: No log files specified"
    puts "Usage: log_analyzer.rb [options] FILE..."
    exit 1
  end

  analyzer = LogAnalyzer.new(
    num_workers: options[:workers],
    chunk_size: options[:chunk_size]
  )

  stats = analyzer.analyze(ARGV, format: options[:format])
  LogReport.generate(stats, options[:output])
end