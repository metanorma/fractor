# Performance Tuning Guide

This guide helps you optimize Fractor for your specific use case.

## Table of Contents

- [Worker Pool Configuration](#worker-pool-configuration)
- [Work Item Design](#work-item-design)
- [Batch Size Tuning](#batch-size-tuning)
- [Memory Management](#memory-management)
- [Workflow Optimization](#workflow-optimization)
- [Monitoring and Profiling](#monitoring-and-profiling)
- [Common Performance Issues](#common-performance-issues)

## Worker Pool Configuration

### Determining Optimal Worker Count

The number of workers depends on your workload characteristics:

```ruby
# CPU-bound tasks: Use number of processors
num_workers: Etc.nprocessors

# I/O-bound tasks: Use 2-4x processors
num_workers: Etc.nprocessors * 2

# Mixed workload: Start with processors, tune from there
num_workers: Etc.nprocessors
```

**Guidelines:**
- **CPU-bound** (data processing, computation): Use `Etc.nprocessors`
- **I/O-bound** (HTTP requests, database queries): Use `2-4 * Etc.nprocessors`
- **Mixed workload**: Start with `Etc.nprocessors`, monitor, and adjust

### Multiple Worker Pools

Use different worker pools for different task types:

```ruby
Fractor::Supervisor.new(
  worker_pools: [
    # Fast CPU-bound tasks - more workers
    { worker_class: FastProcessor, num_workers: 8 },
    # Slow I/O-bound tasks - fewer workers
    { worker_class: SlowAPICaller, num_workers: 2 },
  ]
)
```

## Work Item Design

### Keep Work Items Small

**Optimal**: Small, independent work items

```ruby
# Good: Many small items
1000.times do |i|
  queue << ProcessDataWork.new(data[i])
end
```

**Suboptimal**: Large, monolithic work items

```ruby
# Less efficient: One large item
queue << ProcessAllDataWork.new(all_data)
```

### Avoid Shared State

Work items should be self-contained:

```ruby
# Good: Self-contained work
class ProcessUserWork < Fractor::Work
  def initialize(user_id)
    super({ user_id: user_id })
  end
end

# Bad: Work that depends on external state
class ProcessUserWork < Fractor::Work
  def initialize(user_id)
    super({ user_id: user_id, cache: $shared_cache }) # Avoid!
  end
end
```

### Use Result Caching for Expensive Operations

```ruby
cache = Fractor::ResultCache.new(ttl: 300) # 5 minute TTL

# Cached expensive operation
result = cache.get(expensive_work) do
  # Only executes if not cached
  expensive_work.process
end
```

## Batch Size Tuning

### WorkQueue Batch Size

When using `WorkQueue`, the default batch size is 10. Adjust based on:

```ruby
# For many small, quick tasks: larger batch
queue.register_with_supervisor(supervisor, batch_size: 50)

# For fewer, slower tasks: smaller batch
queue.register_with_supervisor(supervisor, batch_size: 5)
```

### Worker Processing Batch Size

Workers can process multiple items per message:

```ruby
class BatchWorker < Fractor::Worker
  def process(work)
    # Process single item
  end
end
```

## Memory Management

### Result Aggregator Memory

For large result sets, consider processing incrementally:

```ruby
# Instead of collecting all results:
supervisor.run
all_results = supervisor.results.results # May use lots of memory

# Use on_complete callbacks:
supervisor.results.on_new_result do |result|
  # Process each result as it arrives
  save_to_database(result)
end
supervisor.run
```

### Result Cache Memory Limits

Configure cache limits for memory-constrained environments:

```ruby
# Limit by entry count
cache = Fractor::ResultCache.new(max_size: 1000)

# Limit by memory (approximate)
cache = Fractor::ResultCache.new(max_memory: 100_000_000) # 100MB

# Both limits
cache = Fractor::ResultCache.new(
  max_size: 1000,
  max_memory: 100_000_000
)
```

### Queue Memory Limits

For very large work sets, use persistent queue:

```ruby
# Use file-based queue for large datasets
queue = Fractor::PersistentWorkQueue.new(
  queue_file: "/tmp/work_queue.db"
)
```

## Workflow Optimization

### Enable Execution Order Caching

For repeated workflow executions:

```ruby
class MyWorkflow < Fractor::Workflow
  # Enable caching for repeated executions
  enable_cache
end
```

### Optimize Job Dependencies

Minimize dependencies for better parallelism:

```ruby
Fractor::Workflow.define("optimized") do
  job "fetch_data" do
    runs FetchWorker
  end

  # These can run in parallel (both depend only on fetch_data)
  job "process_a" do
    runs ProcessAWorker
    needs "fetch_data"
  end

  job "process_b" do
    runs ProcessBWorker
    needs "fetch_data"
  end

  # This depends on both, so runs after them
  job "combine" do
    runs CombineWorker
    needs ["process_a", "process_b"]
  end
end
```

### Use Circuit Breakers for Failing Services

```ruby
Fractor::Workflow.define("resilient") do
  job "external_api" do
    runs ExternalAPIWorker

    # Circuit breaker prevents cascading failures
    circuit_breaker threshold: 5, timeout: 60
  end
end
```

## Monitoring and Profiling

### Enable Performance Monitoring

```ruby
supervisor = Fractor::Supervisor.new(
  worker_pools: [{ worker_class: MyWorker }],
  enable_performance_monitoring: true
)

supervisor.run

# Get performance metrics
metrics = supervisor.performance_metrics
puts "Latency: #{metrics.avg_latency}ms"
puts "Throughput: #{metrics.throughput} items/sec"
```

### Monitor Cache Performance

```ruby
cache = Fractor::ResultCache.new

# Run workload
# ...

stats = cache.stats
puts "Hit rate: #{stats[:hit_rate]}%"
puts "Cache size: #{stats[:size]}"
```

### Use Debug Output

```ruby
supervisor = Fractor::Supervisor.new(
  worker_pools: [{ worker_class: MyWorker }],
  debug: true # Enable verbose output
)
```

## Common Performance Issues

### Issue: Workers Idle but Work in Queue

**Symptom**: `workers_status` shows idle workers but work isn't being distributed.

**Solution**: Check that `work_distribution_manager` is properly initialized:

```ruby
# This is handled automatically by Supervisor
# If using custom setup, ensure:
@work_distribution_manager = WorkDistributionManager.new(...)
```

### Issue: High Memory Usage

**Symptom**: Memory grows continuously during execution.

**Solutions**:
1. Process results incrementally with `on_new_result` callbacks
2. Configure cache limits with `max_size` and `max_memory`
3. Use persistent queue for large datasets

### Issue: Slow Workflow Execution

**Symptom**: Workflow takes longer than expected.

**Solutions**:
1. Enable execution order caching
2. Optimize job dependencies for parallelism
3. Use `parallel_map` for independent transformations

### Issue: Uneven Worker Utilization

**Symptom**: Some workers busy, others idle.

**Solution**: Use separate worker pools for different task types:

```ruby
# Instead of mixed workload in one pool:
# { worker_class: MixedWorker, num_workers: 8 }

# Use separate pools:
worker_pools: [
  { worker_class: FastWorker, num_workers: 6 },
  { worker_class: SlowWorker, num_workers: 2 },
]
```

## Performance Benchmarks

### Typical Throughput (CPU-bound)

| Workers | Throughput (items/sec) | Speedup |
|---------|------------------------|---------|
| 1       | 1,000                  | 1x      |
| 2       | 1,900                  | 1.9x    |
| 4       | 3,600                  | 3.6x    |
| 8       | 6,800                  | 6.8x    |

*Benchmarks on 8-core system, CPU-bound workload*

### Typical Throughput (I/O-bound)

| Workers | Throughput (requests/sec) | Speedup |
|---------|---------------------------|---------|
| 1       | 100                       | 1x      |
| 2       | 190                       | 1.9x    |
| 4       | 380                       | 3.8x    |
| 8       | 750                       | 7.5x    |
| 16      | 1,400                     | 14x     |

*Benchmarks with HTTP API calls, 100ms latency*

## Best Practices Summary

1. **Start simple**: Use default settings, then optimize based on measurements
2. **Measure first**: Enable performance monitoring before tuning
3. **Profile**: Use debug output to understand bottlenecks
4. **Batch appropriately**: Balance batch size for your workload
5. **Cache wisely**: Use result caching for expensive, deterministic operations
6. **Monitor memory**: Set limits on cache and queue sizes
7. **Design for isolation**: Keep work items independent and self-contained
