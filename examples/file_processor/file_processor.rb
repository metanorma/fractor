#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/fractor"
require "csv"
require "json"
require "fileutils"
require "digest"

# File processing work item
class FileWork < Fractor::Work
  def initialize(file_path, output_dir, options = {})
    super({
      file_path: file_path,
      output_dir: output_dir,
      validate: options.fetch(:validate, true),
      transform: options.fetch(:transform, true),
      # Pre-parsed data (for CSV/JSON - must be parsed OUTSIDE ractors)
      pre_parsed_data: options[:pre_parsed_data]
    })
  end

  def file_path
    input[:file_path]
  end

  def output_dir
    input[:output_dir]
  end

  def validate?
    input[:validate]
  end

  def transform?
    input[:transform]
  end

  def pre_parsed_data
    input[:pre_parsed_data]
  end

  def to_s
    "FileWork(#{File.basename(file_path)})"
  end
end

# Worker for processing files
class FileProcessorWorker < Fractor::Worker
  def process(work)
    return nil unless work.is_a?(FileWork)

    file_path = work.file_path

    unless File.exist?(file_path)
      raise "File not found: #{file_path}"
    end

    format = detect_format(file_path)

    # Use pre-parsed data if available (for CSV/JSON), otherwise parse in-place
    # CSV and JSON must be parsed OUTSIDE ractors to avoid segfault
    if work.pre_parsed_data
      data = work.pre_parsed_data
    else
      # Only for XML which is Ractor-safe
      data = parse_file(file_path, format)
    end

    # Validate if requested
    if work.validate?
      validate_data(data, format)
    end

    # Transform if requested
    if work.transform?
      data = transform_data(data, format)
    end

    # Write output
    output_path = write_output(data, file_path, work.output_dir, format)

    {
      file: File.basename(file_path),
      format: format,
      records: data.is_a?(Array) ? data.size : 1,
      output: output_path,
      checksum: calculate_checksum(file_path),
      status: "success"
    }
  rescue StandardError => e
    {
      file: File.basename(work.file_path),
      status: "error",
      error: e.message,
      error_class: e.class.name
    }
  end

  private

  def detect_format(file_path)
    ext = File.extname(file_path).downcase
    case ext
    when ".csv"
      :csv
    when ".json"
      :json
    when ".xml"
      :xml
    else
      raise "Unsupported file format: #{ext}"
    end
  end

  def parse_file(file_path, format)
    case format
    when :csv
      parse_csv(file_path)
    when :json
      parse_json(file_path)
    when :xml
      parse_xml(file_path)
    end
  end

  def parse_csv(file_path)
    # Parse CSV outside of Ractors
    # CSV parsing must be sequential, so we parse before distributing work
    content = File.read(file_path)
    csv_table = CSV.parse(content, headers: true)

    # Convert to array immediately (CSV::Table is not Ractor-safe)
    result = []
    csv_table.each { |row| result << row.to_hash }
    result
  end

  def parse_json(file_path)
    content = File.read(file_path)
    JSON.parse(content)
  end

  def parse_xml(file_path)
    content = File.read(file_path)

    # Simple XML parsing without REXML to avoid Ractor issues
    records = []
    content.scan(/<record>(.*?)<\/record>/m).each do |match|
      record_content = match[0]
      hash = {}

      record_content.scan(/<(\w+)>(.*?)<\/\1>/m).each do |tag, value|
        hash[tag] = value.strip
      end

      records << hash unless hash.empty?
    end
    records
  end

  def validate_data(data, format)
    case format
    when :csv, :xml
      raise "No records found" if data.empty?
      data.each_with_index do |record, idx|
        raise "Record #{idx + 1} is not a hash" unless record.is_a?(Hash)
        raise "Record #{idx + 1} is empty" if record.empty?
      end
    when :json
      if data.is_a?(Array)
        raise "No records found" if data.empty?
      elsif !data.is_a?(Hash)
        raise "Invalid JSON structure"
      end
    end
  end

  def transform_data(data, format)
    case format
    when :csv, :xml
      data.map do |record|
        transform_record(record)
      end
    when :json
      if data.is_a?(Array)
        data.map { |record| transform_record(record) }
      else
        transform_record(data)
      end
    end
  end

  def transform_record(record)
    transformed = {}
    record.each do |key, value|
      # Convert keys to symbols
      sym_key = key.to_sym

      # Transform values
      transformed[sym_key] = case value
                             when /^\d+$/
                               value.to_i
                             when /^\d+\.\d+$/
                               value.to_f
                             when /^(true|false)$/i
                               value.downcase == "true"
                             else
                               value
                             end
    end
    transformed
  end

  def write_output(data, original_path, output_dir, format)
    FileUtils.mkdir_p(output_dir)

    base_name = File.basename(original_path, ".*")
    output_path = File.join(output_dir, "#{base_name}_processed.json")

    output_data = {
      source_file: File.basename(original_path),
      format: format,
      records: data,
      processed_at: Time.now.iso8601,
      record_count: data.is_a?(Array) ? data.size : 1
    }

    File.write(output_path, JSON.pretty_generate(output_data))
    output_path
  end

  def calculate_checksum(file_path)
    Digest::SHA256.file(file_path).hexdigest
  end
end

# Batch file processor
class BatchFileProcessor
  attr_reader :files, :results, :errors, :dlq_files

  def initialize(output_dir: "processed", dlq_dir: "dlq")
    @output_dir = output_dir
    @dlq_dir = dlq_dir
    @files = []
    @results = []
    @errors = []
    @dlq_files = []
  end

  def add_file(file_path)
    @files << file_path if File.exist?(file_path)
  end

  def add_files(file_paths)
    file_paths.each { |path| add_file(path) }
  end

  def process_all(num_workers: 4, validate: true, transform: true)
    return { processed: [], errors: [], dlq: [] } if @files.empty?

    puts "Processing #{@files.size} files with #{num_workers} workers..."
    puts "Validation: #{validate ? 'enabled' : 'disabled'}"
    puts "Transformation: #{transform ? 'enabled' : 'disabled'}"
    puts

    # Parse CSV/JSON files OUTSIDE ractors to avoid segfault
    # XML can be parsed inside ractors (Ractor-safe)
    work_items = @files.map do |file_path|
      format = detect_format_from_path(file_path)
      pre_parsed_data = nil

      # Parse CSV and JSON outside ractors
      if format == :csv
        pre_parsed_data = parse_csv_outside_ractor(file_path)
      elsif format == :json
        pre_parsed_data = parse_json_outside_ractor(file_path)
      end

      FileWork.new(file_path, @output_dir,
                   validate: validate,
                   transform: transform,
                   pre_parsed_data: pre_parsed_data)
    end

    supervisor = Fractor::Supervisor.new(
      worker_pools: [
        { worker_class: FileProcessorWorker, num_workers: num_workers }
      ]
    )

    supervisor.add_work_items(work_items)
    supervisor.run

    results_obj = supervisor.results
    all_results = results_obj.results + results_obj.errors

    @results = []
    @errors = []
    @dlq_files = []

    all_results.each do |work_result|
      result = work_result.respond_to?(:result) ? work_result.result : work_result

      next unless result.is_a?(Hash)

      if result[:status] == "success"
        @results << result
        puts "[✓] #{result[:file]}: #{result[:records]} records processed"
      else
        @errors << result
        puts "[✗] #{result[:file]}: #{result[:error]}"

        # Move to DLQ if it's a validation or parsing error
        if should_move_to_dlq?(result)
          move_to_dlq(result)
        end
      end
    end

    puts "\n=== Processing Complete ==="
    puts "Successful: #{@results.size}"
    puts "Errors: #{@errors.size}"
    puts "DLQ: #{@dlq_files.size}"
    puts

    {
      processed: @results,
      errors: @errors,
      dlq: @dlq_files
    }
  end

  def inspect_dlq
    return [] unless Dir.exist?(@dlq_dir)

    dlq_files = Dir.glob(File.join(@dlq_dir, "*.json"))

    dlq_files.map do |file_path|
      JSON.parse(File.read(file_path), symbolize_names: true)
    end
  end

  def retry_dlq_file(dlq_file_name)
    dlq_path = File.join(@dlq_dir, dlq_file_name)

    unless File.exist?(dlq_path)
      puts "DLQ file not found: #{dlq_file_name}"
      return false
    end

    dlq_entry = JSON.parse(File.read(dlq_path), symbolize_names: true)
    original_file = dlq_entry[:original_file]

    unless File.exist?(original_file)
      puts "Original file not found: #{original_file}"
      return false
    end

    puts "Retrying #{File.basename(original_file)}..."

    @files = [original_file]
    result = process_all(num_workers: 1)

    if result[:processed].any?
      # Remove from DLQ if successful
      File.delete(dlq_path)
      puts "Successfully processed and removed from DLQ"
      true
    else
      puts "Retry failed, file remains in DLQ"
      false
    end
  end

  private

  def should_move_to_dlq?(result)
    # Move to DLQ for validation errors or parse errors
    error_class = result[:error_class] || ""
    error_msg = result[:error] || ""

    error_class.include?("JSON::ParserError") ||
      error_class.include?("CSV::") ||
      error_msg.include?("No records found") ||
      error_msg.include?("empty") ||
      error_msg.include?("Invalid")
  end

  def move_to_dlq(result)
    FileUtils.mkdir_p(@dlq_dir)

    original_file = @files.find { |f| File.basename(f) == result[:file] }
    return unless original_file

    dlq_entry = {
      file: result[:file],
      original_file: original_file,
      error: result[:error],
      error_class: result[:error_class],
      moved_at: Time.now.iso8601,
      checksum: calculate_file_checksum(original_file)
    }

    dlq_file = File.join(@dlq_dir, "#{File.basename(result[:file], '.*')}_dlq.json")
    File.write(dlq_file, JSON.pretty_generate(dlq_entry))

    @dlq_files << dlq_entry
  end

  def calculate_file_checksum(file_path)
    return nil unless File.exist?(file_path)

    Digest::SHA256.file(file_path).hexdigest
  end

  # Helper methods to parse files OUTSIDE ractors
  # CSV and JSON must be parsed sequentially due to library limitations

  def detect_format_from_path(file_path)
    ext = File.extname(file_path).downcase
    case ext
    when ".csv"
      :csv
    when ".json"
      :json
    when ".xml"
      :xml
    else
      raise "Unsupported file format: #{ext}"
    end
  end

  def parse_csv_outside_ractor(file_path)
    content = File.read(file_path)
    csv_table = CSV.parse(content, headers: true)

    # Convert to array immediately (CSV::Table is not Ractor-safe)
    result = []
    csv_table.each { |row| result << row.to_hash }
    result
  rescue StandardError => e
    raise "Failed to parse CSV #{file_path}: #{e.message}"
  end

  def parse_json_outside_ractor(file_path)
    content = File.read(file_path)
    data = JSON.parse(content)

    # Normalize to array format
    data.is_a?(Array) ? data : [data]
  rescue StandardError => e
    raise "Failed to parse JSON #{file_path}: #{e.message}"
  end
end

# Progress report generator
class ProcessingReport
  def self.generate(results, output_file = nil)
    report = build_report(results)

    if output_file
      File.write(output_file, report)
      puts "Report saved to #{output_file}"
    else
      puts report
    end

    report
  end

  def self.build_report(results)
    lines = []
    lines << "=" * 80
    lines << "BATCH FILE PROCESSING REPORT"
    lines << "=" * 80
    lines << ""

    processed = results[:processed] || []
    errors = results[:errors] || []
    dlq = results[:dlq] || []

    # Summary
    lines << "SUMMARY"
    lines << "-" * 80
    lines << format("Total files: %d", processed.size + errors.size)
    lines << format("Successful: %d", processed.size)
    lines << format("Errors: %d", errors.size)
    lines << format("Dead Letter Queue: %d", dlq.size)
    lines << ""

    # Successful files
    if processed.any?
      lines << "SUCCESSFUL PROCESSING (#{processed.size})"
      lines << "-" * 80
      processed.each do |result|
        lines << format("  %s [%s]: %d records",
                       result[:file], result[:format], result[:records])
      end
      lines << ""
    end

    # Errors
    if errors.any?
      lines << "ERRORS (#{errors.size})"
      lines << "-" * 80
      errors.each do |result|
        lines << format("  %s: %s", result[:file], result[:error])
      end
      lines << ""
    end

    # DLQ
    if dlq.any?
      lines << "DEAD LETTER QUEUE (#{dlq.size})"
      lines << "-" * 80
      dlq.each do |entry|
        lines << format("  %s: %s", entry[:file], entry[:error])
      end
      lines << ""
    end

    lines << "=" * 80

    lines.join("\n")
  end
end

# Run example if executed directly
if __FILE__ == $PROGRAM_NAME
  require "optparse"

  options = {
    workers: 4,
    validate: true,
    transform: true,
    output: nil,
    inspect_dlq: false,
    retry_dlq: nil
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: file_processor.rb [options] FILES..."

    opts.on("-w", "--workers NUM", Integer, "Number of worker ractors (default: 4)") do |n|
      options[:workers] = n
    end

    opts.on("--[no-]validate", "Enable/disable validation (default: true)") do |v|
      options[:validate] = v
    end

    opts.on("--[no-]transform", "Enable/disable transformation (default: true)") do |t|
      options[:transform] = t
    end

    opts.on("-o", "--output FILE", "Output report file") do |f|
      options[:output] = f
    end

    opts.on("--inspect-dlq", "Inspect dead letter queue") do
      options[:inspect_dlq] = true
    end

    opts.on("--retry-dlq FILE", "Retry a file from DLQ") do |f|
      options[:retry_dlq] = f
    end

    opts.on("-h", "--help", "Show this message") do
      puts opts
      exit
    end
  end.parse!

  processor = BatchFileProcessor.new

  if options[:inspect_dlq]
    puts "=== Dead Letter Queue Inspection ==="
    puts
    dlq_entries = processor.inspect_dlq

    if dlq_entries.empty?
      puts "DLQ is empty"
    else
      dlq_entries.each do |entry|
        puts "File: #{entry[:file]}"
        puts "  Error: #{entry[:error]}"
        puts "  Moved at: #{entry[:moved_at]}"
        puts "  Checksum: #{entry[:checksum]}"
        puts
      end
    end
    exit
  end

  if options[:retry_dlq]
    processor.retry_dlq_file(options[:retry_dlq])
    exit
  end

  if ARGV.empty?
    puts "Error: No files specified"
    puts "Usage: file_processor.rb [options] FILES..."
    exit 1
  end

  processor.add_files(ARGV)
  results = processor.process_all(
    num_workers: options[:workers],
    validate: options[:validate],
    transform: options[:transform]
  )

  ProcessingReport.generate(results, options[:output])
end