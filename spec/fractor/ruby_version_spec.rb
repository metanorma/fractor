# frozen_string_literal: true

RSpec.describe "Ruby version-specific behavior" do
  describe "Fractor::RUBY_4_0_OR_HIGHER constant" do
    it "is true on Ruby 4.0+" do
      if RUBY_VERSION >= "4.0.0"
        expect(Fractor::RUBY_4_0_OR_HIGHER).to be true
      else
        expect(Fractor::RUBY_4_0_OR_HIGHER).to be false
      end
    end
  end

  describe "Fractor::WINDOWS_RUBY_34 constant" do
    it "is true only on Windows with Ruby 3.4.x" do
      expected = RUBY_PLATFORM.match?(/mswin|mingw|cygwin/) &&
        RUBY_VERSION >= "3.4.0" && RUBY_VERSION < "3.5.0"
      expect(Fractor::WINDOWS_RUBY_34).to eq(expected)
    end
  end

  describe "WrappedRactor factory method" do
    it "creates WrappedRactor4 on Ruby 4.0+", :ruby4 do
      wrapped_ractor = Fractor::WrappedRactor.create(
        "test_worker",
        Fractor::Worker,
      )
      expect(wrapped_ractor).to be_a(Fractor::WrappedRactor4)
    end

    it "creates WrappedRactor3 on Ruby 3.x", :ruby3 do
      wrapped_ractor = Fractor::WrappedRactor.create(
        "test_worker",
        Fractor::Worker,
      )
      expect(wrapped_ractor).to be_a(Fractor::WrappedRactor3)
    end
  end

  describe "MainLoopHandler factory method" do
    it "creates MainLoopHandler4 on Ruby 4.0+", :ruby4 do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [],
        continuous_mode: true,
      )
      handler = Fractor::MainLoopHandler.create(supervisor)
      expect(handler).to be_a(Fractor::MainLoopHandler4)
    end

    it "creates MainLoopHandler3 on Ruby 3.x", :ruby3 do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [],
        continuous_mode: true,
      )
      handler = Fractor::MainLoopHandler.create(supervisor)
      expect(handler).to be_a(Fractor::MainLoopHandler3)
    end
  end
end
