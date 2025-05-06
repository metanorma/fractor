# frozen_string_literal: true

require_relative "../../lib/fractor"

module ScatterGather
  # Specialized work for different search sources
  class SearchWork < Fractor::Work
    attr_reader :source, :query_params

    def initialize(input)
      if input.is_a?(Hash) && input[:query] && input[:source]
        super(input[:query])
        @source = input[:source]
        @query_params = input[:params] || {}
      else
        super(input)
        @source = :default
        @query_params = {}
      end
    end

    def to_s
      "SearchWork: source=#{@source}, params=#{@query_params}, query=#{input}"
    end
  end

  # Worker specialized for different data sources
  class SearchWorker < Fractor::Worker
    def process(work)
      # Simulate database connection setup
      setup_source(work.source)

      # Process based on source type
      result = case work.source
               when :database then search_database(work)
               when :api then search_api(work)
               when :cache then search_cache(work)
               when :filesystem then search_filesystem(work)
               else
                 return Fractor::WorkResult.new(
                   error: "Unknown source: #{work.source}",
                   work: work
                 )
               end

      # Return result with source information for merging
      Fractor::WorkResult.new(
        result: {
          source: work.source,
          query: work.input,
          hits: result[:hits],
          metadata: result[:metadata],
          timing: result[:timing]
        },
        work: work
      )
    end

    private

    def setup_source(_source)
      # Simulate connection/initialization time
      sleep(rand(0.01..0.05))
    end

    def search_database(work)
      # Simulate database query
      sleep(rand(0.05..0.2))

      # Generate simulated records
      record_count = rand(3..10)
      hits = record_count.times.map do |i|
        {
          id: "db-#{i + 1}",
          title: "Database Result #{i + 1} for '#{work.input}'",
          content: "This is database content for #{work.input}",
          relevance: rand(0.1..1.0).round(2)
        }
      end

      {
        hits: hits,
        metadata: {
          source_type: "PostgreSQL Database",
          total_available: record_count + rand(10..50),
          query_type: "Full-text search"
        },
        timing: rand(0.01..0.3).round(3)
      }
    end

    def search_api(work)
      # Simulate API request
      sleep(rand(0.1..0.3))

      # Generate simulated API results
      record_count = rand(2..8)
      hits = record_count.times.map do |i|
        {
          id: "api-#{i + 1}",
          title: "API Result #{i + 1} for '#{work.input}'",
          content: "This is API content for #{work.input}",
          relevance: rand(0.1..1.0).round(2)
        }
      end

      {
        hits: hits,
        metadata: {
          source_type: "External REST API",
          provider: %w[Google Bing DuckDuckGo].sample,
          response_code: 200
        },
        timing: rand(0.1..0.5).round(3)
      }
    end

    def search_cache(work)
      # Simulate cache lookup
      sleep(rand(0.01..0.1))

      # Simulate cache hit or miss
      cache_hit = [true, true, false].sample

      if cache_hit
        # Cache hit - return cached results
        record_count = rand(1..5)
        hits = record_count.times.map do |i|
          {
            id: "cache-#{i + 1}",
            title: "Cached Result #{i + 1} for '#{work.input}'",
            content: "This is cached content for #{work.input}",
            relevance: rand(0.1..1.0).round(2)
          }
        end

        {
          hits: hits,
          metadata: {
            source_type: "In-memory Cache",
            cache_hit: true,
            age: rand(1..3600)
          },
          timing: rand(0.001..0.05).round(3)
        }
      else
        # Cache miss
        {
          hits: [],
          metadata: {
            source_type: "In-memory Cache",
            cache_hit: false
          },
          timing: rand(0.001..0.01).round(3)
        }
      end
    end

    def search_filesystem(work)
      # Simulate file system search
      sleep(rand(0.05..0.2))

      # Generate simulated file results
      record_count = rand(1..12)
      hits = record_count.times.map do |i|
        {
          id: "file-#{i + 1}",
          title: "File Result #{i + 1} for '#{work.input}'",
          path: "/path/to/file_#{i + 1}.txt",
          content: "This is file content matching #{work.input}",
          relevance: rand(0.1..1.0).round(2)
        }
      end

      {
        hits: hits,
        metadata: {
          source_type: "File System",
          directories_searched: rand(5..20),
          files_scanned: rand(50..500)
        },
        timing: rand(0.01..0.2).round(3)
      }
    end
  end

  # Controller for the multi-source search
  class MultiSourceSearch
    attr_reader :merged_results

    def initialize(worker_count = 4)
      @supervisor = Fractor::Supervisor.new(
        worker_class: SearchWorker,
        work_class: SearchWork,
        num_workers: worker_count
      )

      @merged_results = nil
    end

    def search(query, sources = nil)
      # Define search sources with their parameters
      sources ||= [
        { source: :database, params: { max_results: 50, include_archived: false } },
        { source: :api, params: { format: "json", timeout: 5 } },
        { source: :cache, params: { max_age: 3600 } },
        { source: :filesystem, params: { extensions: %w[txt md pdf] } }
      ]

      # Create work items for each source with the same query
      work_items = sources.map do |source|
        {
          query: query,
          source: source[:source],
          params: source[:params]
        }
      end

      start_time = Time.now

      # Run the searches in parallel
      @supervisor.add_work(work_items)
      @supervisor.run

      end_time = Time.now
      total_time = end_time - start_time

      # Merge results with source-specific relevance rules
      @merged_results = merge_results(@supervisor.results, total_time)

      @merged_results
    end

    private

    def merge_results(results_aggregator, total_time)
      # Group results by source using a standard approach
      # This is more reliable than using Ractors for this simple aggregation
      results_by_source = {}
      total_hits = 0

      results_aggregator.results.each do |result|
        source = result.result[:source]
        results_by_source[source] = result.result
        total_hits += result.result[:hits].size
      end

      # Create combined and ranked results
      all_hits = []
      results_by_source.each do |source, result|
        # Add source-specific weight
        source_weight = case source
                        when :database then 1.0
                        when :api then 0.8
                        when :cache then 1.2 # Prioritize cache
                        when :filesystem then 0.9
                        else 0.5
                        end

        # Add weighted hits to combined list
        result[:hits].each do |hit|
          all_hits << {
            id: hit[:id],
            title: hit[:title],
            content: hit[:content],
            source: source,
            original_relevance: hit[:relevance],
            weighted_relevance: hit[:relevance] * source_weight
          }
        end
      end

      # Sort by weighted relevance
      ranked_hits = all_hits.sort_by { |hit| -hit[:weighted_relevance] }

      # Return merged results
      {
        query: results_by_source.values.first&.dig(:query),
        total_hits: total_hits,
        execution_time: total_time,
        sources: results_by_source.keys,
        ranked_results: ranked_hits,
        source_details: results_by_source
      }
    end
  end
end

# Example usage
if __FILE__ == $PROGRAM_NAME
  puts "Starting Scatter-Gather Search Example"
  puts "======================================"
  puts "This example demonstrates searching multiple data sources concurrently:"
  puts "1. Database - Simulates SQL database searches"
  puts "2. API - Simulates external REST API calls"
  puts "3. Cache - Simulates in-memory cache lookups"
  puts "4. Filesystem - Simulates searching through files"
  puts

  # Sample query
  query = ARGV[0] || "ruby concurrency patterns"
  worker_count = (ARGV[1] || 4).to_i

  puts "Searching for: '#{query}' using #{worker_count} workers..."
  puts

  search = ScatterGather::MultiSourceSearch.new(worker_count)
  results = search.search(query)

  puts "Search Results Summary:"
  puts "----------------------"
  puts "Query: #{results[:query]}"
  puts "Total hits: #{results[:total_hits]}"
  puts "Total execution time: #{results[:execution_time].round(3)} seconds"
  puts "Sources searched: #{results[:sources].join(", ")}"
  puts

  puts "Top 5 Results (by relevance):"
  results[:ranked_results].take(5).each_with_index do |hit, index|
    puts "#{index + 1}. #{hit[:title]} (Source: #{hit[:source]}, Relevance: #{hit[:weighted_relevance].round(2)})"
    puts "   #{hit[:content][0..60]}..."
    puts
  end

  puts "Source Details:"
  results[:source_details].each do |source, details|
    puts "- #{source.to_s.capitalize} (#{details[:hits].size} results, #{details[:timing]} sec)"
    puts "  Metadata: #{details[:metadata]}"
  end
end
