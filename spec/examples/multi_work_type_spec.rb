# frozen_string_literal: true

require_relative "../../examples/multi_work_type/multi_work_type"

RSpec.describe MultiWorkType do
  describe MultiWorkType::TextWork do
    it "stores text data and format" do
      work = described_class.new("Hello World", :markdown, { pretty: true })
      expect(work.data).to eq("Hello World")
      expect(work.format).to eq(:markdown)
      expect(work.options).to eq({ pretty: true })
    end

    it "defaults to plain format" do
      work = described_class.new("Test")
      expect(work.format).to eq(:plain)
    end

    it "provides a string representation" do
      work = described_class.new("Some long text here", :html)
      expect(work.to_s).to include("TextWork", "html")
    end
  end

  describe MultiWorkType::ImageWork do
    it "stores image data, dimensions, and format" do
      work = described_class.new("image_data", [800, 600], :jpeg)
      expect(work.data).to eq("image_data")
      expect(work.dimensions).to eq([800, 600])
      expect(work.format).to eq(:jpeg)
    end

    it "defaults to png format" do
      work = described_class.new("data", [100, 100])
      expect(work.format).to eq(:png)
    end

    it "provides a string representation" do
      work = described_class.new("data", [1024, 768], :gif)
      expect(work.to_s).to include("ImageWork", "1024x768", "gif")
    end
  end

  describe MultiWorkType::MultiFormatWorker do
    let(:worker) { described_class.new }

    context "processing TextWork" do
      it "processes plain text" do
        work = MultiWorkType::TextWork.new("hello world", :plain)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:work_type]).to eq(:text)
        expect(result.result[:original_format]).to eq(:plain)
        expect(result.result[:transformed_data]).to eq("HELLO WORLD")
      end

      it "processes markdown text" do
        work = MultiWorkType::TextWork.new('# Header\n\n[link](url)', :markdown)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:work_type]).to eq(:text)
        expect(result.result[:original_format]).to eq(:markdown)
        expect(result.result[:transformed_data]).to include("Header")
      end

      it "processes HTML text" do
        work = MultiWorkType::TextWork.new("<p>Text</p>", :html)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:work_type]).to eq(:text)
        expect(result.result[:original_format]).to eq(:html)
      end

      it "includes metadata for text processing" do
        work = MultiWorkType::TextWork.new("one two three", :plain)
        result = worker.process(work)

        expect(result.result[:metadata]).to include(:word_count, :char_count)
        expect(result.result[:metadata][:word_count]).to be > 0
      end
    end

    context "processing ImageWork" do
      it "processes image data" do
        work = MultiWorkType::ImageWork.new("image_data", [800, 600], :jpeg)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:work_type]).to eq(:image)
        expect(result.result[:dimensions]).to eq([800, 600])
        expect(result.result[:format]).to eq(:jpeg)
      end

      it "includes processing metadata" do
        work = MultiWorkType::ImageWork.new("data", [1024, 768], :png)
        result = worker.process(work)

        expect(result.result[:processing_metadata]).to include(:original_size,
                                                               :processed_size)
        expect(result.result[:applied_filters]).to be_an(Array)
      end
    end

    context "unsupported work types" do
      it "returns an error for unsupported work" do
        work = Fractor::Work.new({ value: 1 })
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error).to be_a(TypeError)
      end
    end
  end

  describe MultiWorkType::ContentProcessor do
    let(:processor) { described_class.new(2) }

    let(:text_items) do
      [
        { data: "Plain text", format: :plain },
        { data: "# Markdown", format: :markdown },
      ]
    end

    let(:image_items) do
      [
        { data: "image1", dimensions: [800, 600], format: :jpeg },
        { data: "image2", dimensions: [1024, 768], format: :png },
      ]
    end

    it "processes mixed content successfully" do
      result = processor.process_mixed_content(text_items, image_items)

      expect(result[:total_items]).to eq(4)
      expect(result[:processed][:text]).to eq(2)
      expect(result[:processed][:image]).to eq(2)
      expect(result[:errors]).to eq(0)
    end

    it "separates results by work type" do
      result = processor.process_mixed_content(text_items, image_items)

      expect(result[:results][:text]).to be_an(Array)
      expect(result[:results][:image]).to be_an(Array)
      expect(result[:results][:text].size).to eq(2)
      expect(result[:results][:image].size).to eq(2)
    end

    it "handles text-only processing" do
      result = processor.process_mixed_content(text_items, [])

      expect(result[:processed][:text]).to eq(2)
      expect(result[:processed][:image]).to eq(0)
    end

    it "handles image-only processing" do
      result = processor.process_mixed_content([], image_items)

      expect(result[:processed][:text]).to eq(0)
      expect(result[:processed][:image]).to eq(2)
    end
  end
end
