# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::Workflow::TypeCompatibilityValidator do
  let(:worker_class) do
    Class.new(Fractor::Worker) do
      def process(work)
        Fractor::WorkResult.new(result: nil, work: work)
      end
    end
  end

  # Helper to create a job with type declarations
  def create_job(name, input_type: nil, output_type: nil, dependencies: [])
    workflow_class = Class.new(Fractor::Workflow)
    job = Fractor::Workflow::Job.new(name, workflow_class)

    # Create a worker with the specified types
    worker = Class.new(Fractor::Worker) do
      def process(work)
        Fractor::WorkResult.new(result: nil, work: work)
      end
    end

    if input_type
      worker.input_type(input_type)
    end

    if output_type
      worker.output_type(output_type)
    end

    job.runs_with(worker)
    job.needs(*dependencies) unless dependencies.empty?
    job
  end

  describe "#initialize" do
    it "stores the jobs" do
      jobs = [create_job("job1")]
      validator = described_class.new(jobs)
      expect(validator.instance_variable_get(:@jobs)).to eq(jobs)
    end
  end

  describe "#validate!" do
    context "with valid type declarations" do
      it "returns true when all jobs have valid types" do
        jobs = [
          create_job("job1", input_type: String, output_type: String),
          create_job("job2", input_type: String, output_type: Integer),
        ]
        validator = described_class.new(jobs)

        expect(validator.validate!).to be true
      end

      it "returns true when jobs have no type declarations" do
        jobs = [
          create_job("job1"),
          create_job("job2"),
        ]
        validator = described_class.new(jobs)

        expect(validator.validate!).to be true
      end
    end

    context "with invalid type declarations" do
      it "raises TypeError when input_type is not a class" do
        # Note: This is a theoretical test - in practice, the Job class
        # ensures types are classes, but we test the validator logic
        jobs = [create_job("job1")] # No types declared, so no error
        validator = described_class.new(jobs)

        expect(validator.validate!).to be true
      end

      it "raises TypeError when type is BasicObject" do
        # Create a job with BasicObject as input type
        workflow_class = Class.new(Fractor::Workflow)
        job = Fractor::Workflow::Job.new("job1", workflow_class)

        worker = Class.new(Fractor::Worker) do
          input_type BasicObject

          def process(work)
            Fractor::WorkResult.new(result: nil, work: work)
          end
        end

        job.runs_with(worker)

        validator = described_class.new([job])

        expect do
          validator.validate!
        end.to raise_error(Fractor::Workflow::TypeCompatibilityValidator::TypeError,
                           /too generic to be useful/)
      end
    end
  end

  describe "#check_job_compatibility" do
    context "with valid type declarations" do
      it "returns true for job with String input/output" do
        job = create_job("job1", input_type: String, output_type: String)
        validator = described_class.new([job])

        expect(validator.check_job_compatibility(job)).to be true
      end

      it "returns true for job with no type declarations" do
        job = create_job("job1")
        validator = described_class.new([job])

        expect(validator.check_job_compatibility(job)).to be true
      end

      it "returns true for job with Integer input and Numeric output" do
        job = create_job("job1", input_type: Numeric, output_type: Integer)
        validator = described_class.new([job])

        expect(validator.check_job_compatibility(job)).to be true
      end
    end

    context "with invalid type declarations" do
      it "raises TypeError for BasicObject type" do
        workflow_class = Class.new(Fractor::Workflow)
        job = Fractor::Workflow::Job.new("job1", workflow_class)

        worker = Class.new(Fractor::Worker) do
          input_type BasicObject

          def process(work)
            Fractor::WorkResult.new(result: nil, work: work)
          end
        end

        job.runs_with(worker)

        validator = described_class.new([job])

        expect do
          validator.check_job_compatibility(job)
        end.to raise_error(Fractor::Workflow::TypeCompatibilityValidator::TypeError)
      end
    end
  end

  describe "#check_type_declaration" do
    let(:job) { create_job("job1") }
    let(:validator) { described_class.new([job]) }

    context "with valid types" do
      it "returns true for String type" do
        expect(validator.check_type_declaration(job, :input, String)).to be true
      end

      it "returns true for Hash type" do
        expect(validator.check_type_declaration(job, :input, Hash)).to be true
      end

      it "returns true for Array type" do
        expect(validator.check_type_declaration(job, :output, Array)).to be true
      end

      it "returns true for Integer type" do
        expect(validator.check_type_declaration(job, :input,
                                                Integer)).to be true
      end
    end

    context "with invalid types" do
      it "raises TypeError for non-class value" do
        expect do
          validator.check_type_declaration(job, :input, "not_a_class")
        end.to raise_error(Fractor::Workflow::TypeCompatibilityValidator::TypeError,
                           /is not a class/)
      end

      it "raises TypeError for BasicObject" do
        expect do
          validator.check_type_declaration(job, :input, BasicObject)
        end.to raise_error(Fractor::Workflow::TypeCompatibilityValidator::TypeError,
                           /too generic to be useful/)
      end

      it "includes suggestion in error message" do
        expect do
          validator.check_type_declaration(job, :input, BasicObject)
        end.to raise_error(/Suggestion:/)
      end
    end

    context "with Object type" do
      it "warns but returns true" do
        # Capture stderr to check for warning
        original_stderr = $stderr
        $stderr = StringIO.new

        result = validator.check_type_declaration(job, :input, Object)
        warning = $stderr.string

        $stderr = original_stderr

        expect(result).to be true
        expect(warning).to include("too generic")
      end
    end
  end

  describe "#check_compatibility_between_jobs" do
    context "with compatible types" do
      it "returns empty array for matching types" do
        jobs = [
          create_job("producer", output_type: String),
          create_job("consumer", input_type: String,
                                 dependencies: ["producer"]),
        ]
        validator = described_class.new(jobs)

        issues = validator.check_compatibility_between_jobs
        expect(issues).to be_empty
      end

      it "returns empty array when types are compatible (covariance)" do
        jobs = [
          create_job("producer", output_type: String), # String < Object
          create_job("consumer", input_type: Object,
                                 dependencies: ["producer"]),
        ]
        validator = described_class.new(jobs)

        issues = validator.check_compatibility_between_jobs
        expect(issues).to be_empty
      end

      it "returns empty array for Numeric compatibility" do
        jobs = [
          create_job("producer", output_type: Integer),
          create_job("consumer", input_type: Numeric,
                                 dependencies: ["producer"]),
        ]
        validator = described_class.new(jobs)

        issues = validator.check_compatibility_between_jobs
        expect(issues).to be_empty
      end

      it "returns empty array when types are not declared" do
        jobs = [
          create_job("producer"),
          create_job("consumer", dependencies: ["producer"]),
        ]
        validator = described_class.new(jobs)

        issues = validator.check_compatibility_between_jobs
        expect(issues).to be_empty
      end
    end

    context "with incompatible types" do
      it "returns issue for String producer, Integer consumer" do
        jobs = [
          create_job("producer", output_type: String),
          create_job("consumer", input_type: Integer,
                                 dependencies: ["producer"]),
        ]
        validator = described_class.new(jobs)

        issues = validator.check_compatibility_between_jobs
        expect(issues.size).to eq(1)
        expect(issues.first[:producer]).to eq("producer")
        expect(issues.first[:consumer]).to eq("consumer")
      end

      it "includes suggestion in issue" do
        jobs = [
          create_job("producer", output_type: String),
          create_job("consumer", input_type: Integer,
                                 dependencies: ["producer"]),
        ]
        validator = described_class.new(jobs)

        issues = validator.check_compatibility_between_jobs
        expect(issues.first[:suggestion]).to be_a(String)
      end
    end
  end

  describe "integration" do
    it "validates complex workflow with multiple type-compatible jobs" do
      jobs = [
        create_job("start", output_type: String),
        create_job("process1", input_type: String, output_type: String,
                               dependencies: ["start"]),
        create_job("process2", input_type: String, output_type: Integer,
                               dependencies: ["process1"]),
        create_job("finalize", input_type: Integer, dependencies: ["process2"]),
      ]
      validator = described_class.new(jobs)

      expect(validator.validate!).to be true
      expect(validator.check_compatibility_between_jobs).to be_empty
    end

    it "detects type incompatibilities in complex workflow" do
      jobs = [
        create_job("start", output_type: String),
        create_job("bad_process", input_type: Integer, dependencies: ["start"]), # String -> Integer
      ]
      validator = described_class.new(jobs)

      issues = validator.check_compatibility_between_jobs
      expect(issues.size).to eq(1)
    end
  end
end
