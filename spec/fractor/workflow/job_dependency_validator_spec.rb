# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::Workflow::JobDependencyValidator do
  let(:worker_class) do
    Class.new(Fractor::Worker) do
      def process(work)
        Fractor::WorkResult.new(result: nil, work: work)
      end
    end
  end

  # Helper to create a job with proper API
  def create_job(name, dependencies: [], worker: nil)
    workflow_class = Class.new(Fractor::Workflow)
    job = Fractor::Workflow::Job.new(name, workflow_class)
    job.runs_with(worker || worker_class)
    job.needs(*dependencies) unless dependencies.empty?
    job
  end

  describe "#initialize" do
    it "stores the jobs" do
      jobs = [create_job("job1")]
      validator = described_class.new(jobs)
      expect(validator.instance_variable_get(:@jobs)).to eq(jobs)
    end

    it "builds an index of jobs by name" do
      jobs = [create_job("job1"), create_job("job2")]
      validator = described_class.new(jobs)
      index = validator.instance_variable_get(:@jobs_by_name)
      expect(index.keys).to contain_exactly("job1", "job2")
    end
  end

  describe "#validate!" do
    context "with valid dependencies" do
      it "returns true" do
        jobs = [
          create_job("job1"),
          create_job("job2", dependencies: ["job1"]),
          create_job("job3", dependencies: ["job2"]),
        ]
        validator = described_class.new(jobs)

        expect(validator.validate!).to be true
      end
    end

    context "with missing dependencies" do
      it "raises DependencyError" do
        jobs = [
          create_job("job1"),
          create_job("job2", dependencies: ["job1", "nonexistent"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.validate!
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /job2 depends on non-existent job 'nonexistent'/)
      end

      it "lists all missing dependencies" do
        jobs = [
          create_job("job1"),
          create_job("job2", dependencies: ["missing1", "missing2"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.validate!
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /job2 depends on non-existent job 'missing1'/)
        expect do
          validator.validate!
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /job2 depends on non-existent job 'missing2'/)
      end
    end

    context "with circular dependencies" do
      it "raises DependencyError for simple cycle" do
        jobs = [
          create_job("job1", dependencies: ["job2"]),
          create_job("job2", dependencies: ["job1"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.validate!
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /Circular dependency detected/)
      end

      it "raises DependencyError for complex cycle" do
        jobs = [
          create_job("job1", dependencies: ["job2"]),
          create_job("job2", dependencies: ["job3"]),
          create_job("job3", dependencies: ["job1"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.validate!
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /Circular dependency detected/)
      end

      it "includes cycle path in error message" do
        jobs = [
          create_job("job1", dependencies: ["job2"]),
          create_job("job2", dependencies: ["job1"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.validate!
        end.to raise_error(/job1.*job2.*job1/m)
      end
    end

    context "with acyclic dependencies" do
      it "returns true for diamond pattern" do
        jobs = [
          create_job("root"),
          create_job("branch1", dependencies: ["root"]),
          create_job("branch2", dependencies: ["root"]),
          create_job("leaf", dependencies: ["branch1", "branch2"]),
        ]
        validator = described_class.new(jobs)

        expect(validator.validate!).to be true
      end

      it "returns true for complex acyclic graph" do
        jobs = [
          create_job("a"),
          create_job("b", dependencies: ["a"]),
          create_job("c", dependencies: ["a"]),
          create_job("d", dependencies: ["b"]),
          create_job("e", dependencies: ["b", "c"]),
          create_job("f", dependencies: ["e", "d"]),
        ]
        validator = described_class.new(jobs)

        expect(validator.validate!).to be true
      end
    end
  end

  describe "#check_circular_dependencies" do
    context "with no circular dependencies" do
      it "returns true" do
        jobs = [
          create_job("job1"),
          create_job("job2", dependencies: ["job1"]),
        ]
        validator = described_class.new(jobs)

        expect(validator.check_circular_dependencies).to be true
      end
    end

    context "with direct circular dependency" do
      it "raises DependencyError" do
        jobs = [
          create_job("job1", dependencies: ["job2"]),
          create_job("job2", dependencies: ["job1"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.check_circular_dependencies
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /Circular dependency detected/)
      end
    end

    context "with indirect circular dependency" do
      it "raises DependencyError" do
        jobs = [
          create_job("a"),
          create_job("b", dependencies: ["a"]),
          create_job("c", dependencies: ["b"]),
          create_job("a", dependencies: ["c"]), # This creates the cycle
        ]
        described_class.new(jobs)

        # Note: The third job would overwrite the first in our simple creation
        # So let's create a proper test
        jobs = [
          create_job("a", dependencies: ["c"]),
          create_job("b", dependencies: ["a"]),
          create_job("c", dependencies: ["b"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.check_circular_dependencies
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /Circular dependency detected/)
      end
    end

    context "with self-referencing job" do
      it "raises DependencyError" do
        # Create a job that references itself
        job = create_job("job1", dependencies: ["job1"])
        jobs = [job]
        validator = described_class.new(jobs)

        expect do
          validator.check_circular_dependencies
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /Circular dependency detected/)
      end
    end
  end

  describe "#check_missing_dependencies" do
    context "with all dependencies present" do
      it "returns true" do
        jobs = [
          create_job("job1"),
          create_job("job2", dependencies: ["job1"]),
        ]
        validator = described_class.new(jobs)

        expect(validator.check_missing_dependencies).to be true
      end
    end

    context "with missing dependency" do
      it "raises DependencyError" do
        jobs = [
          create_job("job1"),
          create_job("job2", dependencies: ["missing"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.check_missing_dependencies
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                           /job2 depends on non-existent job 'missing'/)
      end
    end

    context "with multiple missing dependencies" do
      it "raises DependencyError listing all missing" do
        jobs = [
          create_job("job1"),
          create_job("job2", dependencies: ["missing1", "missing2"]),
        ]
        validator = described_class.new(jobs)

        expect do
          validator.check_missing_dependencies
        end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError) do |error|
          expect(error.message).to include("missing1")
          expect(error.message).to include("missing2")
        end
      end
    end

    context "with no dependencies" do
      it "returns true" do
        jobs = [
          create_job("job1"),
          create_job("job2"),
        ]
        validator = described_class.new(jobs)

        expect(validator.check_missing_dependencies).to be true
      end
    end
  end

  describe "integration" do
    it "validates complex workflow with multiple checks" do
      jobs = [
        create_job("start"),
        create_job("process1", dependencies: ["start"]),
        create_job("process2", dependencies: ["start"]),
        create_job("merge", dependencies: ["process1", "process2"]),
        create_job("finalize", dependencies: ["merge"]),
      ]
      validator = described_class.new(jobs)

      expect(validator.validate!).to be true
    end

    it "catches multiple issues in one workflow" do
      jobs = [
        create_job("good"),
        create_job("bad1", dependencies: ["missing"]), # Missing dep
        create_job("bad2", dependencies: ["bad1"]), # Depends on job with missing dep
      ]
      validator = described_class.new(jobs)

      # Should fail on missing dependency first
      expect do
        validator.validate!
      end.to raise_error(Fractor::Workflow::JobDependencyValidator::DependencyError,
                         /Missing dependencies/)
    end
  end
end
