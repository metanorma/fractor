# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/image_processor/image_processor"
require "fileutils"
require "tmpdir"

RSpec.describe ImageProcessor do
  let(:temp_dir) { Dir.mktmpdir("image_processor_test") }
  let(:input_dir) { File.join(temp_dir, "input") }
  let(:output_dir) { File.join(temp_dir, "output") }

  before do
    FileUtils.mkdir_p(input_dir)
    FileUtils.mkdir_p(output_dir)
  end

  after do
    FileUtils.rm_rf(temp_dir)
  end

  describe ImageProcessor::ImageWork do
    describe "#initialize" do
      it "creates an ImageWork instance with required parameters" do
        input_path = File.join(input_dir, "test.png")
        output_path = File.join(output_dir, "test_processed.jpg")
        operations = { resize: { width: 800, height: 600 } }

        work = described_class.new(input_path, output_path, operations)

        expect(work.input_path).to eq(input_path)
        expect(work.output_path).to eq(output_path)
        expect(work.operations).to eq(operations)
      end

      it "creates an ImageWork instance with empty operations" do
        input_path = File.join(input_dir, "test.png")
        output_path = File.join(output_dir, "test.jpg")

        work = described_class.new(input_path, output_path)

        expect(work.input_path).to eq(input_path)
        expect(work.output_path).to eq(output_path)
        expect(work.operations).to eq({})
      end

      it "inherits from Fractor::Work" do
        work = described_class.new("input.png", "output.png")
        expect(work).to be_a(Fractor::Work)
      end
    end

    describe "#to_s" do
      it "returns a descriptive string with operations" do
        work = described_class.new(
          "path/to/image.png",
          "output.jpg",
          { resize: { width: 800 }, filter: "grayscale" },
        )

        expect(work.to_s).to include("ImageWork")
        expect(work.to_s).to include("image.png")
        expect(work.to_s).to include("resize")
        expect(work.to_s).to include("filter")
      end

      it "returns a string with no operations" do
        work = described_class.new("image.png", "output.png", {})
        expect(work.to_s).to include("ImageWork")
        expect(work.to_s).to include("image.png")
      end
    end
  end

  describe ImageProcessor::ImageProcessorWorker do
    let(:worker) { described_class.new }

    describe "#process" do
      context "with valid input" do
        let(:input_file) { File.join(input_dir, "test.png") }
        let(:output_file) { File.join(output_dir, "test_processed.jpg") }

        before do
          File.write(input_file, "FAKE_IMAGE_DATA")
        end

        it "processes image with resize operation" do
          work = ImageProcessor::ImageWork.new(
            input_file,
            output_file,
            { resize: { width: 800, height: 600 } },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("success")
          expect(result[:input]).to eq(input_file)
          expect(result[:output]).to eq(output_file)
          expect(result[:operations]).to eq(work.operations)
          expect(result[:file_size]).to be > 0
          expect(result[:processing_time]).to be_a(Float)
        end

        it "processes image with convert operation" do
          work = ImageProcessor::ImageWork.new(
            input_file,
            output_file,
            { convert: "jpg" },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("success")
          expect(result[:operations][:convert]).to eq("jpg")
        end

        it "processes image with filter operation" do
          work = ImageProcessor::ImageWork.new(
            input_file,
            output_file,
            { filter: "grayscale" },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("success")
          expect(result[:operations][:filter]).to eq("grayscale")
        end

        it "processes image with brightness operation" do
          work = ImageProcessor::ImageWork.new(
            input_file,
            output_file,
            { brightness: 20 },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("success")
          expect(result[:operations][:brightness]).to eq(20)
        end

        it "processes image with multiple operations" do
          work = ImageProcessor::ImageWork.new(
            input_file,
            output_file,
            {
              resize: { width: 1024, height: 768 },
              filter: "sepia",
              brightness: -10,
              convert: "png",
            },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("success")
          expect(result[:operations].keys).to contain_exactly(
            :resize, :filter, :brightness, :convert
          )
        end

        it "creates output directory if it doesn't exist" do
          nested_output = File.join(output_dir, "nested", "deep", "output.jpg")
          work = ImageProcessor::ImageWork.new(input_file, nested_output, {})

          result = worker.process(work)

          expect(result[:status]).to eq("success")
          expect(File.directory?(File.dirname(nested_output))).to be true
        end

        it "creates metadata JSON file" do
          work = ImageProcessor::ImageWork.new(
            input_file,
            output_file,
            { resize: { width: 800, height: 600 } },
          )

          worker.process(work)

          metadata_file = "#{output_file}.json"
          expect(File.exist?(metadata_file)).to be true

          metadata = JSON.parse(File.read(metadata_file))
          expect(metadata["original"]).to eq(input_file)
          # JSON parses with string keys, and nested hashes also have string keys
          expected_ops = JSON.parse(work.operations.to_json)
          expect(metadata["operations"]).to eq(expected_ops)
          expect(metadata["processed_at"]).not_to be_nil
        end
      end

      context "with invalid input" do
        it "raises ArgumentError for non-ImageWork object" do
          expect do
            worker.process("not an ImageWork object")
          end.to raise_error(ArgumentError, /Expected ImageWork/)
        end

        it "returns error for non-existent input file" do
          work = ImageProcessor::ImageWork.new(
            File.join(input_dir, "nonexistent.png"),
            File.join(output_dir, "output.jpg"),
            {},
          )

          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("not found")
        end

        it "returns error for invalid resize width" do
          input_file = File.join(input_dir, "test.png")
          File.write(input_file, "FAKE_IMAGE_DATA")

          work = ImageProcessor::ImageWork.new(
            input_file,
            File.join(output_dir, "output.jpg"),
            { resize: { width: -100, height: 600 } },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("Invalid width")
        end

        it "returns error for invalid resize height" do
          input_file = File.join(input_dir, "test.png")
          File.write(input_file, "FAKE_IMAGE_DATA")

          work = ImageProcessor::ImageWork.new(
            input_file,
            File.join(output_dir, "output.jpg"),
            { resize: { width: 800, height: 0 } },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("Invalid height")
        end

        it "returns error for unsupported format" do
          input_file = File.join(input_dir, "test.png")
          File.write(input_file, "FAKE_IMAGE_DATA")

          work = ImageProcessor::ImageWork.new(
            input_file,
            File.join(output_dir, "output.xyz"),
            { convert: "xyz" },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("Unsupported format")
        end

        it "returns error for unknown filter" do
          input_file = File.join(input_dir, "test.png")
          File.write(input_file, "FAKE_IMAGE_DATA")

          work = ImageProcessor::ImageWork.new(
            input_file,
            File.join(output_dir, "output.jpg"),
            { filter: "invalid_filter" },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("Unknown filter")
        end

        it "returns error for brightness out of range (too high)" do
          input_file = File.join(input_dir, "test.png")
          File.write(input_file, "FAKE_IMAGE_DATA")

          work = ImageProcessor::ImageWork.new(
            input_file,
            File.join(output_dir, "output.jpg"),
            { brightness: 150 },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("Brightness must be between")
        end

        it "returns error for brightness out of range (too low)" do
          input_file = File.join(input_dir, "test.png")
          File.write(input_file, "FAKE_IMAGE_DATA")

          work = ImageProcessor::ImageWork.new(
            input_file,
            File.join(output_dir, "output.jpg"),
            { brightness: -150 },
          )

          result = worker.process(work)

          expect(result[:status]).to eq("error")
          expect(result[:error]).to include("Brightness must be between")
        end
      end

      context "with different format conversions" do
        let(:input_file) { File.join(input_dir, "test.png") }

        before do
          File.write(input_file, "FAKE_IMAGE_DATA")
        end

        %w[jpg jpeg png gif bmp webp].each do |format|
          it "successfully converts to #{format}" do
            work = ImageProcessor::ImageWork.new(
              input_file,
              File.join(output_dir, "output.#{format}"),
              { convert: format },
            )

            result = worker.process(work)

            expect(result[:status]).to eq("success")
          end
        end
      end

      context "with different filters" do
        let(:input_file) { File.join(input_dir, "test.png") }

        before do
          File.write(input_file, "FAKE_IMAGE_DATA")
        end

        %w[grayscale sepia blur sharpen].each do |filter|
          it "successfully applies #{filter} filter" do
            work = ImageProcessor::ImageWork.new(
              input_file,
              File.join(output_dir, "output.jpg"),
              { filter: filter },
            )

            result = worker.process(work)

            expect(result[:status]).to eq("success")
          end
        end
      end
    end
  end

  describe ImageProcessor::ProgressTracker do
    describe "#initialize" do
      it "creates a ProgressTracker with total count" do
        tracker = described_class.new(100)

        expect(tracker.total).to eq(100)
        expect(tracker.completed).to eq(0)
        expect(tracker.errors).to eq(0)
      end
    end

    describe "#increment_completed" do
      it "increments completed count" do
        tracker = described_class.new(10)

        tracker.increment_completed
        expect(tracker.completed).to eq(1)

        tracker.increment_completed
        expect(tracker.completed).to eq(2)
      end

      it "is thread-safe" do
        tracker = described_class.new(100)

        threads = Array.new(10) do
          Thread.new do
            10.times { tracker.increment_completed }
          end
        end

        threads.each(&:join)

        expect(tracker.completed).to eq(100)
      end
    end

    describe "#increment_errors" do
      it "increments error count and completed count" do
        tracker = described_class.new(10)

        tracker.increment_errors
        expect(tracker.errors).to eq(1)
        expect(tracker.completed).to eq(1)

        tracker.increment_errors
        expect(tracker.errors).to eq(2)
        expect(tracker.completed).to eq(2)
      end
    end

    describe "#percentage" do
      it "calculates completion percentage" do
        tracker = described_class.new(100)

        expect(tracker.percentage).to eq(0)

        25.times { tracker.increment_completed }
        expect(tracker.percentage).to eq(25.0)

        25.times { tracker.increment_completed }
        expect(tracker.percentage).to eq(50.0)

        50.times { tracker.increment_completed }
        expect(tracker.percentage).to eq(100.0)
      end

      it "returns 0 for zero total" do
        tracker = described_class.new(0)
        expect(tracker.percentage).to eq(0)
      end

      it "rounds to 2 decimal places" do
        tracker = described_class.new(3)

        tracker.increment_completed
        expect(tracker.percentage).to eq(33.33)
      end
    end

    describe "#elapsed_time" do
      it "returns elapsed time since creation" do
        tracker = described_class.new(10)

        sleep(0.1)

        expect(tracker.elapsed_time).to be >= 0.1
        # Use a more lenient upper bound to account for CI system load
        expect(tracker.elapsed_time).to be < 0.5
      end
    end

    describe "#estimated_remaining" do
      it "estimates remaining time based on current rate" do
        tracker = described_class.new(100)

        # Simulate some processing time
        sleep(0.1)
        25.times { tracker.increment_completed }

        estimated = tracker.estimated_remaining
        expect(estimated).to be > 0
        expect(estimated).to be_a(Float)
      end

      it "returns 0 when no items completed yet" do
        tracker = described_class.new(100)
        expect(tracker.estimated_remaining).to eq(0)
      end

      it "returns 0 when all items completed" do
        tracker = described_class.new(10)

        10.times { tracker.increment_completed }

        expect(tracker.estimated_remaining).to eq(0)
      end
    end
  end

  describe "Integration Test" do
    it "processes multiple images in parallel" do
      # Create test input files
      input_files = Array.new(5) do |i|
        file_path = File.join(input_dir, "test_#{i}.png")
        File.write(file_path, "FAKE_IMAGE_DATA_#{i}")
        file_path
      end

      # Define operations
      operations = {
        resize: { width: 800, height: 600 },
        filter: "grayscale",
        convert: "jpg",
      }

      # Create work items
      work_items = input_files.map do |input_file|
        output_file = File.join(
          output_dir,
          "#{File.basename(input_file, '.*')}_processed.jpg",
        )
        ImageProcessor::ImageWork.new(input_file, output_file, operations)
      end

      # Initialize tracker
      tracker = ImageProcessor::ProgressTracker.new(work_items.size)

      # Process with Fractor
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: ImageProcessor::ImageProcessorWorker,
            num_workers: 2 },
        ],
      )

      supervisor.add_work_items(work_items)

      # Start processing
      supervisor.run

      # Collect results
      results = []
      all_results = supervisor.results.results + supervisor.results.errors

      all_results.each do |work_result|
        result = work_result.result || {
          status: "error",
          error: work_result.error&.message || "Unknown error",
        }
        results << result

        if result[:status] == "error"
          tracker.increment_errors
        else
          tracker.increment_completed
        end
      end

      # Verify results
      expect(results.size).to eq(5)
      expect(results.all? { |r| r[:status] == "success" }).to be true
      expect(tracker.completed).to eq(5)
      expect(tracker.errors).to eq(0)
      expect(tracker.percentage).to eq(100.0)
    end

    it "handles mixed success and error results" do
      # Create mix of valid and invalid files
      valid_file = File.join(input_dir, "valid.png")
      File.write(valid_file, "FAKE_IMAGE_DATA")

      work_items = [
        ImageProcessor::ImageWork.new(valid_file,
                                      File.join(output_dir, "out1.jpg"), {}),
        ImageProcessor::ImageWork.new(
          File.join(input_dir, "nonexistent.png"),
          File.join(output_dir, "out2.jpg"),
          {},
        ),
        ImageProcessor::ImageWork.new(
          valid_file,
          File.join(output_dir, "out3.jpg"),
          { filter: "invalid_filter" },
        ),
        ImageProcessor::ImageWork.new(valid_file,
                                      File.join(output_dir, "out4.jpg"), {}),
      ]

      tracker = ImageProcessor::ProgressTracker.new(work_items.size)

      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: ImageProcessor::ImageProcessorWorker,
            num_workers: 2 },
        ],
      )

      supervisor.add_work_items(work_items)

      # Start processing
      supervisor.run

      results = []
      all_results = supervisor.results.results + supervisor.results.errors

      all_results.each do |work_result|
        result = work_result.result || {
          status: "error",
          error: work_result.error&.message || "Unknown error",
        }
        results << result

        if result[:status] == "error"
          tracker.increment_errors
        else
          tracker.increment_completed
        end
      end

      # Verify mixed results
      success_count = results.count { |r| r[:status] == "success" }
      error_count = results.count { |r| r[:status] == "error" }

      expect(success_count).to eq(2)
      expect(error_count).to eq(2)
      expect(tracker.completed).to eq(4)
      expect(tracker.errors).to eq(2)
    end
  end
end
