# frozen_string_literal: true

require_relative "../../examples/pipeline_processing/pipeline_processing"

RSpec.describe PipelineProcessing do
  describe PipelineProcessing::MediaWork do
    it "stores data, stage, and metadata" do
      work = described_class.new("test.jpg", :resize, { key: "value" })
      expect(work.data).to eq("test.jpg")
      expect(work.stage).to eq(:resize)
      expect(work.metadata).to eq({ key: "value" })
    end

    it "defaults to resize stage" do
      work = described_class.new("image.png")
      expect(work.stage).to eq(:resize)
    end

    it "defaults to empty metadata" do
      work = described_class.new("image.png", :filter)
      expect(work.metadata).to eq({})
    end

    it "provides a string representation" do
      work = described_class.new("test.jpg", :compress)
      expect(work.to_s).to include("MediaWork", "compress")
    end
  end

  describe PipelineProcessing::PipelineWorker do
    let(:worker) { described_class.new }

    context "processing resize stage" do
      it "resizes the image" do
        work = PipelineProcessing::MediaWork.new("image.jpg", :resize)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:current_stage]).to eq(:resize)
        expect(result.result[:next_stage]).to eq(:filter)
        expect(result.result[:processed_data]).to include("Resized")
      end

      it "updates metadata with completion status" do
        work = PipelineProcessing::MediaWork.new("image.jpg", :resize)
        result = worker.process(work)

        expect(result.result[:metadata][:resize_completed]).to be true
        expect(result.result[:metadata]).to have_key(:resize_time)
      end
    end

    context "processing filter stage" do
      it "applies filters to the image" do
        work = PipelineProcessing::MediaWork.new("resized image", :filter)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:current_stage]).to eq(:filter)
        expect(result.result[:next_stage]).to eq(:compress)
        expect(result.result[:processed_data]).to include("Applied", "filter")
      end
    end

    context "processing compress stage" do
      it "compresses the image" do
        work = PipelineProcessing::MediaWork.new("filtered image", :compress)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:current_stage]).to eq(:compress)
        expect(result.result[:next_stage]).to eq(:tag)
        expect(result.result[:processed_data]).to include("Compressed")
      end
    end

    context "processing tag stage" do
      it "tags the image" do
        work = PipelineProcessing::MediaWork.new("compressed image", :tag)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:current_stage]).to eq(:tag)
        expect(result.result[:next_stage]).to be_nil
        expect(result.result[:processed_data]).to include("Tagged", "tags:")
      end
    end

    context "unknown stage" do
      it "returns an error for unknown stage" do
        work = PipelineProcessing::MediaWork.new("image", :unknown)
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error).to include("Unknown stage")
      end
    end
  end

  describe PipelineProcessing::MediaPipeline do
    let(:pipeline) { described_class.new(2) }

    it "processes images through the pipeline" do
      images = ["image1.jpg", "image2.png"]
      result = pipeline.process_images(images)

      expect(result[:total_images]).to eq(2)
      expect(result[:completed]).to be >= 0
      expect(result[:results]).to be_an(Array)
    end

    it "tracks completed images" do
      images = ["test.jpg"]
      result = pipeline.process_images(images)

      expect(result).to have_key(:completed)
      expect(result).to have_key(:in_progress)
    end

    it "handles empty image list" do
      result = pipeline.process_images([])

      expect(result[:total_images]).to eq(0)
      expect(result[:completed]).to eq(0)
    end

    it "includes metadata in completed results" do
      images = ["image.jpg"]
      result = pipeline.process_images(images)

      if result[:completed] > 0
        completed_result = result[:results].first
        expect(completed_result[:metadata]).to be_a(Hash)
        expect(completed_result).to have_key(:processed_data)
      end
    end
  end
end
