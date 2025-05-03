# Fractor

Fractor (Function-driven Ractor framework) is a Ruby framework that leverages the power of Ractors for parallel processing. It provides a structured approach to concurrent programming using the actor model.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fractor'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install fractor
```

## Overview

Fractor provides a declarative way to set up parallel processing workflows using Ruby's Ractor feature. The framework consists of several key components:

- **Fractor::Work**: Represents a unit of work to be processed
- **Fractor::WorkResult**: Represents the result of processed work
- **Fractor::Worker**: A Ractor-based worker that processes work items
- **Fractor::Queue**: Holds work items to be processed
- **Fractor::Pool**: Manages a collection of workers
- **Fractor::Supervisor**: Coordinates the assignment of work to workers
- **Fractor::ResultAssembler**: Assembles and finalizes work results

## Usage

### Basic Concepts

1. Define your work types by subclassing `Fractor::Work`
2. Define your result types by subclassing `Fractor::WorkResult`
3. Create workers by subclassing `Fractor::Worker` and implementing the `process_work` method
4. Create a supervisor to manage the workflow
5. Create queues to hold work items
6. Create worker pools to process the work
7. Start the supervisor to begin processing

### Example: Hierarchical Hasher

This example demonstrates a hierarchical file hasher that:
1. Breaks a file into chunks
2. Hashes each chunk in parallel
3. Combines the hashes into a final result

```ruby
require 'fractor'
require 'digest'

# Define work and result classes
class ChunkWork < Fractor::Work
  attr_reader :start, :length, :data

  def initialize(start, length, data)
    super(work_type: :chunk_hash)
    @start = start
    @length = length
    @data = data
  end
end

class ChunkResult < Fractor::WorkResult
  attr_reader :start, :hash_result

  def initialize(work, hash_result)
    super(work)
    @start = work.start
    @hash_result = hash_result
  end
end

# Define worker
class HashWorker < Fractor::Worker
  work_type_accepted :chunk_hash

  def process_work(work)
    hash = Digest::SHA3.hexdigest(work.data)
    ChunkResult.new(work, hash)
  end
end

# Define result assembler
class HashResultAssembler < Fractor::ResultAssembler
  def finalize
    sorted_results = @results.sort_by { |result| result.start }
    combined = sorted_results.map(&:hash_result).join("\n")
    Digest::SHA3.hexdigest(combined)
  end
end

# Set up and run the processing
supervisor = Fractor::Supervisor.new
queue = Fractor::Queue.new(work_types: [:chunk_hash])
pool = Fractor::Pool.new(size: 4)

# Add workers to pool
4.times { pool.add_worker(HashWorker.new) }

# Add queue and pool to supervisor
supervisor.add_queue(queue)
supervisor.add_pool(pool)

# Create work items
File.open('large_file.bin', 'rb') do |file|
  pos = 0
  while chunk = file.read(1024)
    work = ChunkWork.new(pos, chunk.length, chunk)
    queue.push(work)
    pos += chunk.length
  end
end

# Start processing
final_hash = supervisor.start

# Clean up
supervisor.shutdown
```

### Example: Producer-Subscriber Model

This example demonstrates a producer-subscriber model where:
1. Initial work items are processed
2. Processing generates additional work items
3. The system continues until all work is complete

```ruby
# See examples/producer_subscriber.rb for a complete implementation
```

## Advanced Features

### Work Types and Worker Specialization

Workers can be specialized to handle specific types of work:

```ruby
class SpecializedWorker < Fractor::Worker
  work_type_accepted [:type_a, :type_b]

  def process_work(work)
    case work.work_type
    when :type_a
      # Process type A work
    when :type_b
      # Process type B work
    end
  end
end
```

### Error Handling and Retries

Work items can be configured to retry on failure:

```ruby
class RetryableWork < Fractor::Work
  def initialize
    super(work_type: :my_type)
    @retry_count = 0
    @max_retries = 3
  end

  def should_retry?
    @retry_count < @max_retries
  end

  def failed
    @retry_count += 1
  end
end
```

### Custom Message Handling

Workers can handle custom messages:

```ruby
class CustomWorker < Fractor::Worker
  handle_message :custom_command do |params|
    # Handle custom command
  end
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/yourusername/fractor.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
