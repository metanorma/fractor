# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../examples/file_processor/file_processor"

RSpec.describe "File Processor Example" do
  let(:sample_files_dir) do
    File.expand_path("../../examples/file_processor/sample_files", __dir__)
  end
  let(:test_output_dir) { File.join(Dir.tmpdir, "file_processor_test_output") }
  let(:test_dlq_dir) { File.join(Dir.tmpdir, "file_processor_test_dlq") }

  before do
    FileUtils.rm_rf(test_output_dir) if Dir.exist?(test_output_dir)
    FileUtils.rm_rf(test_dlq_dir) if Dir.exist?(test_dlq_dir)
  end

  after do
    FileUtils.rm_rf(test_output_dir) if Dir.exist?(test_output_dir)
    FileUtils.rm_rf(test_dlq_dir) if Dir.exist?(test_dlq_dir)
  end

  describe FileWork do
    describe "#initialize" do
      it "creates work item with required parameters" do
        work = described_class.new("/path/to/file.csv", "/output")

        expect(work.file_path).to eq("/path/to/file.csv")
        expect(work.output_dir).to eq("/output")
        expect(work.validate?).to be true
        expect(work.transform?).to be true
      end

      it "accepts custom options" do
        work = described_class.new("/path/to/file.csv", "/output",
                                   validate: false, transform: false)

        expect(work.validate?).to be false
        expect(work.transform?).to be false
      end
    end

    describe "#to_s" do
      it "returns readable string representation" do
        work = described_class.new("/path/to/data.csv", "/output")
        expect(work.to_s).to eq("FileWork(data.csv)")
      end
    end
  end

  describe FileProcessorWorker do
    let(:worker) { described_class.new }

    describe "#process" do
      it "processes CSV file successfully" do
        csv_file = File.join(sample_files_dir, "users.csv")
        work = FileWork.new(csv_file, test_output_dir)

        result = worker.process(work)

        expect(result).to be_a(Hash)
        expect(result[:status]).to eq("success")
        expect(result[:format]).to eq(:csv)
        expect(result[:records]).to eq(5)
        expect(result[:checksum]).to be_a(String)
      end

      it "processes JSON file successfully" do
        json_file = File.join(sample_files_dir, "products.json")
        work = FileWork.new(json_file, test_output_dir)

        result = worker.process(work)

        expect(result[:status]).to eq("success")
        expect(result[:format]).to eq(:json)
        expect(result[:records]).to eq(3)
      end

      it "processes XML file successfully" do
        xml_file = File.join(sample_files_dir, "orders.xml")
        work = FileWork.new(xml_file, test_output_dir)

        result = worker.process(work)

        expect(result[:status]).to eq("success")
        expect(result[:format]).to eq(:xml)
        expect(result[:records]).to eq(3)
      end

      it "returns error for non-existent file" do
        work = FileWork.new("/nonexistent/file.csv", test_output_dir)
        result = worker.process(work)

        expect(result[:status]).to eq("error")
        expect(result[:error]).to include("File not found")
      end

      it "returns error for unsupported format" do
        Dir.mktmpdir do |dir|
          unsupported_file = File.join(dir, "test.txt")
          File.write(unsupported_file, "test content")

          work = FileWork.new(unsupported_file, test_output_dir)
          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("Unsupported file format")
        end
      end

      it "validates data when requested" do
        invalid_csv = File.join(sample_files_dir, "invalid.csv")
        work = FileWork.new(invalid_csv, test_output_dir, validate: true)

        result = worker.process(work)

        expect(result[:status]).to eq("error")
        expect(result[:error]).to include("No records found")
      end

      it "skips validation when disabled" do
        invalid_csv = File.join(sample_files_dir, "invalid.csv")
        work = FileWork.new(invalid_csv, test_output_dir, validate: false,
                                                          transform: false)

        result = worker.process(work)

        # Without validation, empty file is processed successfully (0 records)
        expect(result[:status]).to eq("success")
        expect(result[:records]).to eq(0)
      end

      it "transforms data types correctly" do
        csv_file = File.join(sample_files_dir, "users.csv")
        work = FileWork.new(csv_file, test_output_dir, transform: true)

        result = worker.process(work)

        expect(result[:status]).to eq("success")

        # Check output file for transformed data
        output_file = result[:output]
        output_data = JSON.parse(File.read(output_file), symbolize_names: true)

        first_record = output_data[:records].first
        expect(first_record[:id]).to be_an(Integer)
        expect(first_record[:age]).to be_an(Integer)
        expect(first_record[:active]).to be true
      end

      it "creates output file" do
        csv_file = File.join(sample_files_dir, "users.csv")
        work = FileWork.new(csv_file, test_output_dir)

        result = worker.process(work)

        expect(File.exist?(result[:output])).to be true
      end
    end

    describe "format detection" do
      it "detects CSV format" do
        format = worker.send(:detect_format, "file.csv")
        expect(format).to eq(:csv)
      end

      it "detects JSON format" do
        format = worker.send(:detect_format, "file.json")
        expect(format).to eq(:json)
      end

      it "detects XML format" do
        format = worker.send(:detect_format, "file.xml")
        expect(format).to eq(:xml)
      end

      it "raises error for unknown format" do
        expect do
          worker.send(:detect_format, "file.txt")
        end.to raise_error(/Unsupported file format/)
      end
    end

    describe "data transformation" do
      it "transforms string numbers to integers" do
        record = { "id" => "123", "count" => "456" }
        transformed = worker.send(:transform_record, record)

        expect(transformed[:id]).to eq(123)
        expect(transformed[:count]).to eq(456)
      end

      it "transforms string floats to floats" do
        record = { "price" => "99.99", "tax" => "8.5" }
        transformed = worker.send(:transform_record, record)

        expect(transformed[:price]).to eq(99.99)
        expect(transformed[:tax]).to eq(8.5)
      end

      it "transforms string booleans to booleans" do
        record = { "active" => "true", "deleted" => "false" }
        transformed = worker.send(:transform_record, record)

        expect(transformed[:active]).to be true
        expect(transformed[:deleted]).to be false
      end

      it "keeps other strings as strings" do
        record = { "name" => "Test", "email" => "test@example.com" }
        transformed = worker.send(:transform_record, record)

        expect(transformed[:name]).to eq("Test")
        expect(transformed[:email]).to eq("test@example.com")
      end
    end
  end

  describe BatchFileProcessor do
    let(:processor) do
      described_class.new(output_dir: test_output_dir, dlq_dir: test_dlq_dir)
    end

    describe "#initialize" do
      it "starts with empty file list" do
        expect(processor.files).to be_empty
      end

      it "initializes result arrays" do
        expect(processor.results).to be_empty
        expect(processor.errors).to be_empty
        expect(processor.dlq_files).to be_empty
      end
    end

    describe "#add_file" do
      it "adds existing file to list" do
        csv_file = File.join(sample_files_dir, "users.csv")
        processor.add_file(csv_file)

        expect(processor.files.size).to eq(1)
        expect(processor.files.first).to eq(csv_file)
      end

      it "ignores non-existent files" do
        processor.add_file("/nonexistent/file.csv")
        expect(processor.files).to be_empty
      end
    end

    describe "#add_files" do
      it "adds multiple files" do
        csv_file = File.join(sample_files_dir, "users.csv")
        json_file = File.join(sample_files_dir, "products.json")

        processor.add_files([csv_file, json_file])

        expect(processor.files.size).to eq(2)
      end
    end

    describe "#process_all" do
      it "returns empty result when no files" do
        result = processor.process_all

        expect(result[:processed]).to be_empty
        expect(result[:errors]).to be_empty
        expect(result[:dlq]).to be_empty
      end

      it "processes single file successfully" do
        csv_file = File.join(sample_files_dir, "users.csv")
        processor.add_file(csv_file)

        result = processor.process_all(num_workers: 2)

        expect(result[:processed].size).to eq(1)
        expect(result[:errors]).to be_empty
        expect(result[:dlq]).to be_empty
      end

      it "processes multiple files" do
        csv_file = File.join(sample_files_dir, "users.csv")
        json_file = File.join(sample_files_dir, "products.json")
        xml_file = File.join(sample_files_dir, "orders.xml")

        processor.add_files([csv_file, json_file, xml_file])

        result = processor.process_all(num_workers: 4)

        expect(result[:processed].size).to eq(3)
        expect(result[:errors]).to be_empty
      end

      it "handles validation errors" do
        invalid_csv = File.join(sample_files_dir, "invalid.csv")
        processor.add_file(invalid_csv)

        result = processor.process_all(num_workers: 2, validate: true)

        expect(result[:processed]).to be_empty
        expect(result[:errors].size).to eq(1)
      end

      it "moves failed files to DLQ" do
        invalid_csv = File.join(sample_files_dir, "invalid.csv")
        processor.add_file(invalid_csv)

        result = processor.process_all(num_workers: 2)

        expect(result[:dlq].size).to eq(1)
        expect(Dir.exist?(test_dlq_dir)).to be true
      end

      it "respects validation flag" do
        csv_file = File.join(sample_files_dir, "users.csv")
        processor.add_file(csv_file)

        result = processor.process_all(num_workers: 2, validate: false)

        expect(result[:processed].size).to eq(1)
      end

      it "respects transformation flag" do
        csv_file = File.join(sample_files_dir, "users.csv")
        processor.add_file(csv_file)

        result = processor.process_all(num_workers: 2, transform: false)

        expect(result[:processed].size).to eq(1)
      end
    end

    describe "#inspect_dlq" do
      it "returns empty array when DLQ doesn't exist" do
        dlq_entries = processor.inspect_dlq
        expect(dlq_entries).to be_empty
      end

      it "returns DLQ entries when present" do
        invalid_csv = File.join(sample_files_dir, "invalid.csv")
        processor.add_file(invalid_csv)
        processor.process_all(num_workers: 2)

        dlq_entries = processor.inspect_dlq

        expect(dlq_entries).not_to be_empty
        expect(dlq_entries.first).to have_key(:file)
        expect(dlq_entries.first).to have_key(:error)
        expect(dlq_entries.first).to have_key(:moved_at)
      end
    end

    describe "#retry_dlq_file" do
      it "returns false for non-existent DLQ file" do
        result = processor.retry_dlq_file("nonexistent_dlq.json")
        expect(result).to be false
      end
    end
  end

  describe ProcessingReport do
    let(:sample_results) do
      {
        processed: [
          { file: "users.csv", format: :csv, records: 5 },
          { file: "products.json", format: :json, records: 3 },
        ],
        errors: [
          { file: "invalid.csv", error: "No records found" },
        ],
        dlq: [
          { file: "invalid.csv", error: "No records found" },
        ],
      }
    end

    describe ".generate" do
      it "generates report to console" do
        expect do
          described_class.generate(sample_results)
        end.to output(/BATCH FILE PROCESSING REPORT/).to_stdout
      end

      it "saves report to file" do
        Dir.mktmpdir do |dir|
          output_file = File.join(dir, "test_report.txt")
          described_class.generate(sample_results, output_file)

          expect(File.exist?(output_file)).to be true
          content = File.read(output_file)
          expect(content).to include("BATCH FILE PROCESSING REPORT")
        end
      end
    end

    describe ".build_report" do
      let(:report) { described_class.build_report(sample_results) }

      it "includes summary section" do
        expect(report).to include("SUMMARY")
        expect(report).to include("Total files: 3")
        expect(report).to include("Successful: 2")
        expect(report).to include("Errors: 1")
        expect(report).to include("Dead Letter Queue: 1")
      end

      it "includes successful processing section" do
        expect(report).to include("SUCCESSFUL PROCESSING")
        expect(report).to include("users.csv")
        expect(report).to include("products.json")
      end

      it "includes errors section" do
        expect(report).to include("ERRORS")
        expect(report).to include("invalid.csv")
        expect(report).to include("No records found")
      end

      it "includes DLQ section" do
        expect(report).to include("DEAD LETTER QUEUE")
        expect(report).to include("invalid.csv")
      end

      it "handles empty results" do
        empty_report = described_class.build_report({
                                                      processed: [],
                                                      errors: [],
                                                      dlq: [],
                                                    })

        expect(empty_report).to include("BATCH FILE PROCESSING REPORT")
        expect(empty_report).to include("Total files: 0")
      end
    end
  end

  describe "Integration tests" do
    it "processes all sample files successfully" do
      processor = BatchFileProcessor.new(output_dir: test_output_dir,
                                         dlq_dir: test_dlq_dir)

      csv_file = File.join(sample_files_dir, "users.csv")
      json_file = File.join(sample_files_dir, "products.json")
      xml_file = File.join(sample_files_dir, "orders.xml")

      processor.add_files([csv_file, json_file, xml_file])

      result = processor.process_all(num_workers: 4)

      expect(result[:processed].size).to eq(3)
      expect(result[:errors]).to be_empty
      expect(result[:dlq]).to be_empty
    end

    it "generates complete report for processing results" do
      processor = BatchFileProcessor.new(output_dir: test_output_dir,
                                         dlq_dir: test_dlq_dir)

      csv_file = File.join(sample_files_dir, "users.csv")
      processor.add_file(csv_file)

      result = processor.process_all(num_workers: 2)

      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "integration_report.txt")
        report = ProcessingReport.generate(result, output_file)

        expect(File.exist?(output_file)).to be true
        expect(report).to include("BATCH FILE PROCESSING REPORT")
        expect(report).to include("SUCCESSFUL PROCESSING")
      end
    end

    it "handles mixed success and failure" do
      processor = BatchFileProcessor.new(output_dir: test_output_dir,
                                         dlq_dir: test_dlq_dir)

      csv_file = File.join(sample_files_dir, "users.csv")
      invalid_csv = File.join(sample_files_dir, "invalid.csv")

      processor.add_files([csv_file, invalid_csv])

      result = processor.process_all(num_workers: 2)

      expect(result[:processed].size).to eq(1)
      expect(result[:errors].size).to eq(1)
      expect(result[:dlq].size).to eq(1)
    end
  end
end
