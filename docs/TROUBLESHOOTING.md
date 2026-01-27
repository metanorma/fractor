# Troubleshooting Guide

This guide helps you diagnose and fix common issues with Fractor.

## Table of Contents

- [Installation Issues](#installation-issues)
- [Worker Issues](#worker-issues)
- [Workflow Issues](#workflow-issues)
- [Performance Issues](#performance-issues)
- [Memory Issues](#memory-issues)
- [Ruby Version Issues](#ruby-version-issues)
- [Debugging Tips](#debugging-tips)

## Installation Issues

### Error: `uninitialized constant Fractor`

**Symptom**:
```
NameError: uninitialized constant Fractor
```

**Cause**: Fractor is not required or gem is not installed.

**Solution**:
```ruby
# Add to your Gemfile
gem "fractor"

# Then require in your code
require "fractor"
```

### Error: `Ractor not available`

**Symptom**:
```
ArgumentError: Ractor is not available on this Ruby interpreter
```

**Cause**: Ruby version is too old. Ractor was introduced in Ruby 3.0.

**Solution**: Upgrade to Ruby 3.0 or later:
```bash
ruby --version  # Should be 3.0+
```

## Worker Issues

### Error: `worker_class must be a Class`

**Symptom**:
```
ArgumentError: worker_class must be a Class (got Symbol), in worker_pools[0]
```

**Cause**: Passing a symbol or string instead of the class.

**Solution**:
```ruby
# Wrong
worker_pools: [{ worker_class: :MyWorker }]

# Correct
worker_pools: [{ worker_class: MyWorker }]
```

### Error: `must inherit from Fractor::Worker`

**Symptom**:
```
ArgumentError: MyWorker must inherit from Fractor::Worker
```

**Cause**: Worker class doesn't inherit from `Fractor::Worker`.

**Solution**:
```ruby
# Add inheritance
class MyWorker < Fractor::Worker
  def process(work)
    # ...
  end
end
```

### Workers Not Processing Work

**Symptom**: Work is added but workers don't process it.

**Possible Causes**:

1. **Supervisor not started**:
```ruby
supervisor.add_work_items(items)

# Don't forget to start!
supervisor.run  # For batch mode
```

2. **Work items not valid Fractor::Work**:
```ruby
# Ensure work inherits from Fractor::Work
class MyWork < Fractor::Work
  def initialize(data)
    super({ value: data })
  end
end
```

3. **Worker's `process` method raises error**:
```ruby
# Enable debug to see errors
supervisor = Fractor::Supervisor.new(
  worker_pools: [{ worker_class: MyWorker }],
  debug: true
)
```

## Workflow Issues

### Error: `Circular dependency detected`

**Symptom**:
```
Fractor::CircularDependencyError: Circular dependency detected: a -> b -> a
```

**Cause**: Jobs have circular dependencies.

**Solution**: Reorganize jobs to remove circular dependencies:
```ruby
# Wrong:
job "a" do
  runs WorkerA
  needs "b"
end

job "b" do
  runs WorkerB
  needs "a"  # Creates circular dependency
end

# Solution: Refactor to eliminate circular dependency
# or extract shared logic into a separate job
```

### Error: `Unknown job in dependency`

**Symptom**:
```
ArgumentError: Unknown job in dependency: 'nonexistent'
```

**Cause**: Job references a non-existent dependency.

**Solution**: Ensure all referenced jobs are defined:
```ruby
job "process" do
  runs ProcessWorker
  needs "prepare"  # Ensure "prepare" job exists
end

job "prepare" do
  runs PrepareWorker
end
```

### Workflow Hangs

**Symptom**: Workflow execution never completes.

**Possible Causes**:

1. **Job with no dependencies that's not a start job**:
```ruby
# Check for jobs without 'needs' that should have them
job "orphan" do
  runs OrphanWorker
  # Missing: needs "some_job"
end
```

2. **Circuit breaker open preventing execution**:
```ruby
# Check circuit breaker status
# Disable temporarily to debug
job "external_api" do
  runs ExternalAPIWorker
  # Comment out circuit breaker to test
  # circuit_breaker threshold: 5, timeout: 60
end
```

## Performance Issues

### Slow Execution

**Symptom**: Jobs take longer than expected.

**Diagnosis**:
```ruby
# Enable performance monitoring
supervisor = Fractor::Supervisor.new(
  worker_pools: [{ worker_class: MyWorker }],
  enable_performance_monitoring: true
)

supervisor.run

# Check metrics
metrics = supervisor.performance_metrics
puts "Average latency: #{metrics.avg_latency}ms"
puts "Throughput: #{metrics.throughput} items/sec"
```

**Solutions**:
1. Increase worker count for CPU-bound work
2. Use batch processing for many small items
3. Enable workflow execution caching

### Uneven Worker Utilization

**Symptom**: Some workers busy, others idle.

**Diagnosis**:
```ruby
# Check worker status
status = supervisor.workers_status
puts "Total: #{status[:total]}"
puts "Idle: #{status[:idle]}"
puts "Busy: #{status[:busy]}"
```

**Solution**: Use separate worker pools for different task types:
```ruby
worker_pools: [
  { worker_class: FastWorker, num_workers: 6 },
  { worker_class: SlowWorker, num_workers: 2 },
]
```

## Memory Issues

### Out of Memory

**Symptom**: Process crashes with `NoMemoryError` or system OOM killer.

**Solutions**:

1. **Process results incrementally**:
```ruby
# Instead of collecting all results
supervisor.run
all_results = supervisor.results.results  # Uses lots of memory

# Use callbacks
supervisor.results.on_new_result do |result|
  save_to_disk(result)  # Process and discard
end
supervisor.run
```

2. **Configure cache limits**:
```ruby
cache = Fractor::ResultCache.new(
  max_size: 1000,  # Max entries
  max_memory: 100_000_000  # 100MB max
)
```

3. **Use persistent queue**:
```ruby
queue = Fractor::PersistentWorkQueue.new(
  queue_file: "/tmp/work_queue.db"
)
```

### Memory Leak

**Symptom**: Memory grows continuously during execution.

**Diagnosis**:
```ruby
# Monitor memory during execution
require "memory_profiler"

report = MemoryProfiler.report do
  supervisor.run
end

report.pretty_print
```

**Possible Causes**:
1. Accumulating results without processing
2. Cache growing without limits
3. Workers retaining references to processed work

## Ruby Version Issues

### Ruby 3.x vs 4.0 Differences

**Symptom**: Code works differently on Ruby 3.x vs 4.0.

**Key Differences**:

1. **Ractor communication**:
```ruby
# Ruby 3.x uses Ractor.yield / Ractor.receive
# Ruby 4.0 uses Ractor::Port / Ractor.select
# Fractor handles this automatically via WrappedRactor
```

2. **Main loop handler**:
```ruby
# Ruby 3.x: MainLoopHandler
# Ruby 4.0: MainLoopHandler4
# Fractor selects the correct one automatically
```

**Solution**: Ensure you're using the latest Fractor version which handles version differences automatically.

## Debugging Tips

### Enable Debug Output

```ruby
supervisor = Fractor::Supervisor.new(
  worker_pools: [{ worker_class: MyWorker }],
  debug: true  # Verbose output
)
```

### Use Execution Tracer

```ruby
# Enable tracing
supervisor = Fractor::Supervisor.new(
  worker_pools: [{ worker_class: MyWorker }],
  tracer_enabled: true
)

supervisor.run

# Get trace
trace = supervisor.execution_tracer
trace.each do |event|
  puts "#{event.type}: #{event.work_id}"
end
```

### Check Error Statistics

```ruby
supervisor.run

# Get error report
error_reporter = supervisor.error_reporter
puts "Total errors: #{error_reporter.total_errors}"
puts "Error types: #{error_reporter.error_types}"

# Generate formatted report
formatter = Fractor::ErrorFormatter.new
puts formatter.format_summary(error_reporter)
```

### Inspect Worker State

```ruby
# Check which workers are idle/busy
status = supervisor.workers_status
status[:pools].each do |pool|
  puts "#{pool[:worker_class]}:"
  pool[:workers].each do |worker|
    state = worker[:idle] ? "idle" : "busy"
    puts "  #{worker[:name]}: #{state}"
  end
end
```

### Test Workers in Isolation

```ruby
# Test your worker directly
class TestWorker < Fractor::Worker
  def process(work)
    result = expensive_operation(work.input)
    Fractor::WorkResult.new(result: result, work: work)
  end
end

# Test without Fractor overhead
work = MyWork.new(test_data)
result = TestWorker.new.process(work)
puts result
```

## Common Error Messages

### `No live workers left`

**Cause**: All workers have terminated due to errors.

**Solution**:
1. Check error messages with `error_reporter`
2. Fix worker errors
3. Consider using circuit breakers for failing services

### `Timeout::Error`

**Cause**: Worker exceeded timeout limit.

**Solution**:
```ruby
# Increase timeout
class MyWork < Fractor::Work
  def initialize(data)
    super({ value: data }, timeout: 300)  # 5 minutes
  end
end
```

### `ClosedError`

**Cause**: Attempting to send work to a closed ractor.

**Solution**: This is usually handled automatically by Fractor. If you see this error, it may indicate a bug in Fractor itself.

## Getting Help

If you're still stuck:

1. **Check the examples**: See `examples/` directory for working code
2. **Enable debug mode**: Set `debug: true` for verbose output
3. **Check GitHub issues**: Search for similar problems
4. **Create minimal reproduction**: Create a simple test case that demonstrates the issue

## Useful Debugging Commands

```ruby
# Check Ruby version
puts RUBY_VERSION  # Should be 3.0+

# Check Ractor availability
puts Ractor.current  # Should return current Ractor

# Check Fractor version
puts Fractor::VERSION

# Enable all debug output
ENV["FRACTOR_DEBUG"] = "1"

# Test basic functionality
supervisor = Fractor::Supervisor.new(
  worker_pools: [{ worker_class: TestWorker }],
  debug: true
)
supervisor.add_work_item(TestWork.new("test"))
supervisor.run
puts supervisor.results.results
```
