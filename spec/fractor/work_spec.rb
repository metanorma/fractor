# frozen_string_literal: true

RSpec.describe Fractor::Work do
  describe "#initialize" do
    it "stores the input data" do
      input_data = "test data"
      work = Fractor::Work.new(input_data)

      expect(work.input).to eq(input_data)
    end

    it "works with various input types" do
      # Test with a number
      work1 = Fractor::Work.new(42)
      expect(work1.input).to eq(42)

      # Test with an array
      work2 = Fractor::Work.new([1, 2, 3])
      expect(work2.input).to eq([1, 2, 3])

      # Test with a hash
      work3 = Fractor::Work.new({ key: "value" })
      expect(work3.input).to eq({ key: "value" })

      # Test with nil
      work4 = Fractor::Work.new(nil)
      expect(work4.input).to be_nil
    end
  end

  describe "#to_s" do
    it "returns a string representation including the input" do
      work = Fractor::Work.new("test data")
      expect(work.to_s).to eq("Work: test data")
    end

    it "handles various input types for to_s" do
      # Test with a number
      work1 = Fractor::Work.new(42)
      expect(work1.to_s).to eq("Work: 42")

      # Test with an array
      work2 = Fractor::Work.new([1, 2, 3])
      expect(work2.to_s).to eq("Work: [1, 2, 3]")

      # Test with a hash
      work3 = Fractor::Work.new({ key: "value" })
      expect(work3.to_s).to include("Work:")
      expect(work3.to_s).to include("key")
      expect(work3.to_s).to include("value")
    end
  end

  describe "subclassing" do
    it "allows customization through subclassing" do
      # Define a test subclass
      class CustomWork < Fractor::Work
        attr_reader :extra_data

        def initialize(input, extra_data = nil)
          super(input)
          @extra_data = extra_data
        end

        def to_s
          "CustomWork: #{@input} (#{@extra_data})"
        end
      end

      # Create a custom work instance
      custom_work = CustomWork.new("primary data", "extra info")

      # Verify inheritance
      expect(custom_work).to be_a(Fractor::Work)
      expect(custom_work.input).to eq("primary data")
      expect(custom_work.extra_data).to eq("extra info")
      expect(custom_work.to_s).to eq("CustomWork: primary data (extra info)")
    end
  end
end
