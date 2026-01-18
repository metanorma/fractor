#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/fractor"
require "net/http"
require "uri"
require "json"
require "time"

# API endpoint configuration
class APIEndpoint
  attr_reader :name, :url, :timeout, :rate_limit_delay

  def initialize(name:, url:, timeout: 5, rate_limit_delay: 0.1)
    @name = name
    @url = url
    @timeout = timeout
    @rate_limit_delay = rate_limit_delay
  end

  def to_s
    "APIEndpoint(#{name}: #{url})"
  end
end

# Mock API responses for demonstration
module MockAPIResponses
  USERS_API = [
    { id: 1, name: "Alice Johnson", email: "alice@example.com", role: "admin" },
    { id: 2, name: "Bob Smith", email: "bob@example.com", role: "user" },
    { id: 3, name: "Carol Williams", email: "carol@example.com", role: "user" }
  ].freeze

  PRODUCTS_API = [
    { id: 101, name: "Laptop", price: 999.99, stock: 15 },
    { id: 102, name: "Mouse", price: 29.99, stock: 50 },
    { id: 103, name: "Keyboard", price: 79.99, stock: 30 }
  ].freeze

  ORDERS_API = [
    { id: 1001, user_id: 1, product_id: 101, quantity: 1, status: "shipped" },
    { id: 1002, user_id: 2, product_id: 102, quantity: 2, status: "pending" },
    { id: 1003, user_id: 3, product_id: 103, quantity: 1, status: "delivered" }
  ].freeze

  ANALYTICS_API = {
    total_users: 3,
    total_products: 3,
    total_orders: 3,
    revenue: 1139.97,
    timestamp: Time.now.iso8601
  }.freeze

  def self.get_response(endpoint_name, simulate_error: false, simulate_slow: false)
    sleep(2) if simulate_slow

    raise "Simulated API error" if simulate_error

    case endpoint_name
    when :users
      { status: "success", data: USERS_API, timestamp: Time.now.iso8601 }
    when :products
      { status: "success", data: PRODUCTS_API, timestamp: Time.now.iso8601 }
    when :orders
      { status: "success", data: ORDERS_API, timestamp: Time.now.iso8601 }
    when :analytics
      { status: "success", data: ANALYTICS_API, timestamp: Time.now.iso8601 }
    else
      raise "Unknown endpoint: #{endpoint_name}"
    end
  end
end

# API aggregator - simplified without workflow for this example
class APIAggregator
  attr_reader :endpoints, :results, :errors

  def initialize
    @endpoints = []
    @results = {}
    @errors = {}
    @request_count = 0
    @mutex = Mutex.new
  end

  def add_endpoint(endpoint)
    @endpoints << endpoint
  end

  def fetch_all(simulate_errors: false, simulate_slow: false)
    return {} if @endpoints.empty?

    puts "Fetching data from #{@endpoints.size} API endpoints..."
    puts "Retry enabled with exponential backoff (max 3 attempts)"
    puts

    @results = {}
    @errors = {}

    # Fetch from each endpoint with retry logic
    @endpoints.each do |endpoint|
      max_attempts = 3
      attempt = 0

      while attempt < max_attempts
        attempt += 1

        begin
          data = fetch_endpoint(
            endpoint,
            {},
            simulate_error: simulate_errors,
            simulate_slow: simulate_slow
          )

          @results[endpoint.name.to_sym] = data
          break
        rescue StandardError => e
          if attempt < max_attempts
            delay = 0.5 * (2 ** (attempt - 1))
            puts "[#{endpoint.name}] Retrying (attempt #{attempt + 1}/#{max_attempts}) after #{delay}s..."
            sleep(delay)
          else
            puts "[#{endpoint.name}] All retry attempts exhausted"
            @errors[endpoint.name.to_sym] = e.message
          end
        end
      end
    end

    puts "\n=== Aggregation Complete ==="
    puts "Successful fetches: #{@results.keys.size}"
    puts "Failed fetches: #{@errors.keys.size}"
    puts "Total API requests: #{@request_count}"
    puts

    aggregate_data(@results)
  end

  private

  def fetch_endpoint(endpoint, context, simulate_error: false, simulate_slow: false)
    @mutex.synchronize { @request_count += 1 }

    puts "[#{endpoint.name}] Fetching from #{endpoint.url}..."

    # Simulate rate limiting
    sleep(endpoint.rate_limit_delay)

    # Use mock API for demonstration
    response = MockAPIResponses.get_response(
      endpoint.name.to_sym,
      simulate_error: simulate_error,
      simulate_slow: simulate_slow
    )

    puts "[#{endpoint.name}] ✓ Success (#{response[:data].size rescue 'N/A'} items)"

    response[:data]
  rescue StandardError => e
    puts "[#{endpoint.name}] ✗ Error: #{e.message}"
    raise e
  end

  def aggregate_data(results)
    aggregated = {
      users: results[:users] || [],
      products: results[:products] || [],
      orders: results[:orders] || [],
      analytics: results[:analytics] || {},
      summary: {}
    }

    # Calculate summary statistics
    aggregated[:summary] = {
      total_users: aggregated[:users].size,
      total_products: aggregated[:products].size,
      total_orders: aggregated[:orders].size,
      endpoints_successful: results.keys.size,
      endpoints_failed: @errors.keys.size,
      timestamp: Time.now.iso8601
    }

    # Enrich orders with user and product information
    if aggregated[:orders].any?
      aggregated[:enriched_orders] = enrich_orders(
        aggregated[:orders],
        aggregated[:users],
        aggregated[:products]
      )
    end

    aggregated
  end

  def enrich_orders(orders, users, products)
    orders.map do |order|
      user = users.find { |u| u[:id] == order[:user_id] }
      product = products.find { |p| p[:id] == order[:product_id] }

      order.merge(
        user_name: user&.dig(:name),
        user_email: user&.dig(:email),
        product_name: product&.dig(:name),
        product_price: product&.dig(:price),
        total_price: (product&.dig(:price) || 0) * order[:quantity]
      )
    end
  end
end

# Report generator for aggregated data
class AggregationReport
  def self.generate(data, output_file = nil)
    report = build_report(data)

    if output_file
      File.write(output_file, report)
      puts "Report saved to #{output_file}"
    else
      puts report
    end

    report
  end

  def self.build_report(data)
    lines = []
    lines << "=" * 80
    lines << "API AGGREGATION REPORT"
    lines << "=" * 80
    lines << ""

    # Summary
    if data[:summary]
      lines << "SUMMARY"
      lines << "-" * 80
      lines << format("Total Users: %d", data[:summary][:total_users] || 0)
      lines << format("Total Products: %d", data[:summary][:total_products] || 0)
      lines << format("Total Orders: %d", data[:summary][:total_orders] || 0)
      lines << format("Endpoints Successful: %d", data[:summary][:endpoints_successful] || 0)
      lines << format("Endpoints Failed: %d", data[:summary][:endpoints_failed] || 0)
      lines << format("Timestamp: %s", data[:summary][:timestamp] || "N/A")
      lines << ""
    end

    # Users
    if data[:users]&.any?
      lines << "USERS (#{data[:users].size})"
      lines << "-" * 80
      data[:users].first(5).each do |user|
        lines << format("  %d. %s <%s> [%s]",
                       user[:id], user[:name], user[:email], user[:role])
      end
      lines << "  ..." if data[:users].size > 5
      lines << ""
    end

    # Products
    if data[:products]&.any?
      lines << "PRODUCTS (#{data[:products].size})"
      lines << "-" * 80
      data[:products].first(5).each do |product|
        lines << format("  %d. %s - $%.2f (Stock: %d)",
                       product[:id], product[:name], product[:price], product[:stock])
      end
      lines << "  ..." if data[:products].size > 5
      lines << ""
    end

    # Enriched Orders
    if data[:enriched_orders]&.any?
      lines << "ENRICHED ORDERS (#{data[:enriched_orders].size})"
      lines << "-" * 80
      data[:enriched_orders].each do |order|
        lines << format("  Order #%d:", order[:id])
        lines << format("    User: %s <%s>", order[:user_name], order[:user_email])
        lines << format("    Product: %s", order[:product_name])
        lines << format("    Quantity: %d × $%.2f = $%.2f",
                       order[:quantity], order[:product_price], order[:total_price])
        lines << format("    Status: %s", order[:status])
        lines << ""
      end
    end

    # Analytics
    if data[:analytics].is_a?(Hash) && data[:analytics].any?
      lines << "ANALYTICS"
      lines << "-" * 80
      data[:analytics].each do |key, value|
        lines << format("  %s: %s", key.to_s.gsub("_", " ").capitalize, value)
      end
      lines << ""
    end

    lines << "=" * 80

    lines.join("\n")
  end
end

# Run example if executed directly
if __FILE__ == $PROGRAM_NAME
  require "optparse"

  options = {
    simulate_errors: false,
    simulate_slow: false,
    output: nil
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: api_aggregator.rb [options]"

    opts.on("--simulate-errors", "Simulate API errors to test circuit breaker") do
      options[:simulate_errors] = true
    end

    opts.on("--simulate-slow", "Simulate slow API responses") do
      options[:simulate_slow] = true
    end

    opts.on("-o", "--output FILE", "Output report file") do |f|
      options[:output] = f
    end

    opts.on("-h", "--help", "Show this message") do
      puts opts
      exit
    end
  end.parse!

  puts "=== API Data Aggregator with Circuit Breaker ==="
  puts

  # Create aggregator
  aggregator = APIAggregator.new

  # Add API endpoints
  aggregator.add_endpoint(APIEndpoint.new(
    name: "users",
    url: "https://api.example.com/users",
    timeout: 5,
    rate_limit_delay: 0.1
  ))

  aggregator.add_endpoint(APIEndpoint.new(
    name: "products",
    url: "https://api.example.com/products",
    timeout: 5,
    rate_limit_delay: 0.1
  ))

  aggregator.add_endpoint(APIEndpoint.new(
    name: "orders",
    url: "https://api.example.com/orders",
    timeout: 5,
    rate_limit_delay: 0.1
  ))

  aggregator.add_endpoint(APIEndpoint.new(
    name: "analytics",
    url: "https://api.example.com/analytics",
    timeout: 5,
    rate_limit_delay: 0.1
  ))

  # Fetch all data
  data = aggregator.fetch_all(
    simulate_errors: options[:simulate_errors],
    simulate_slow: options[:simulate_slow]
  )

  # Generate report
  AggregationReport.generate(data, options[:output])
end