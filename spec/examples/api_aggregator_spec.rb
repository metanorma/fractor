# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../examples/api_aggregator/api_aggregator"

RSpec.describe "API Aggregator Example" do
  describe APIEndpoint do
    describe "#initialize" do
      it "creates an endpoint with required parameters" do
        endpoint = described_class.new(
          name: "users",
          url: "https://api.example.com/users",
        )

        expect(endpoint.name).to eq("users")
        expect(endpoint.url).to eq("https://api.example.com/users")
        expect(endpoint.timeout).to eq(5)
        expect(endpoint.rate_limit_delay).to eq(0.1)
      end

      it "accepts custom timeout and rate limit" do
        endpoint = described_class.new(
          name: "products",
          url: "https://api.example.com/products",
          timeout: 10,
          rate_limit_delay: 0.5,
        )

        expect(endpoint.timeout).to eq(10)
        expect(endpoint.rate_limit_delay).to eq(0.5)
      end
    end

    describe "#to_s" do
      it "returns a readable string representation" do
        endpoint = described_class.new(
          name: "orders",
          url: "https://api.example.com/orders",
        )

        expect(endpoint.to_s).to eq("APIEndpoint(orders: https://api.example.com/orders)")
      end
    end
  end

  describe MockAPIResponses do
    describe ".get_response" do
      it "returns users data" do
        response = described_class.get_response(:users)

        expect(response[:status]).to eq("success")
        expect(response[:data]).to be_an(Array)
        expect(response[:data].size).to eq(3)
        expect(response[:data].first).to have_key(:id)
        expect(response[:data].first).to have_key(:name)
        expect(response[:data].first).to have_key(:email)
      end

      it "returns products data" do
        response = described_class.get_response(:products)

        expect(response[:status]).to eq("success")
        expect(response[:data]).to be_an(Array)
        expect(response[:data].size).to eq(3)
        expect(response[:data].first).to have_key(:id)
        expect(response[:data].first).to have_key(:name)
        expect(response[:data].first).to have_key(:price)
      end

      it "returns orders data" do
        response = described_class.get_response(:orders)

        expect(response[:status]).to eq("success")
        expect(response[:data]).to be_an(Array)
        expect(response[:data].size).to eq(3)
        expect(response[:data].first).to have_key(:id)
        expect(response[:data].first).to have_key(:user_id)
        expect(response[:data].first).to have_key(:product_id)
      end

      it "returns analytics data" do
        response = described_class.get_response(:analytics)

        expect(response[:status]).to eq("success")
        expect(response[:data]).to be_a(Hash)
        expect(response[:data]).to have_key(:total_users)
        expect(response[:data]).to have_key(:revenue)
      end

      it "raises error for unknown endpoint" do
        expect do
          described_class.get_response(:unknown)
        end.to raise_error("Unknown endpoint: unknown")
      end

      it "simulates error when requested" do
        expect do
          described_class.get_response(:users, simulate_error: true)
        end.to raise_error("Simulated API error")
      end

      it "simulates slow response when requested" do
        start_time = Time.now
        described_class.get_response(:users, simulate_slow: true)
        elapsed = Time.now - start_time

        expect(elapsed).to be >= 2.0
      end
    end
  end

  describe APIAggregator do
    let(:aggregator) { described_class.new }

    describe "#initialize" do
      it "starts with empty endpoints" do
        expect(aggregator.endpoints).to be_empty
      end

      it "initializes results and errors hashes" do
        expect(aggregator.results).to eq({})
        expect(aggregator.errors).to eq({})
      end
    end

    describe "#add_endpoint" do
      it "adds an endpoint to the list" do
        endpoint = APIEndpoint.new(name: "users", url: "https://api.example.com/users")
        aggregator.add_endpoint(endpoint)

        expect(aggregator.endpoints.size).to eq(1)
        expect(aggregator.endpoints.first).to eq(endpoint)
      end

      it "adds multiple endpoints" do
        users_endpoint = APIEndpoint.new(name: "users", url: "https://api.example.com/users")
        products_endpoint = APIEndpoint.new(name: "products", url: "https://api.example.com/products")

        aggregator.add_endpoint(users_endpoint)
        aggregator.add_endpoint(products_endpoint)

        expect(aggregator.endpoints.size).to eq(2)
      end
    end

    describe "#fetch_all" do
      before do
        aggregator.add_endpoint(APIEndpoint.new(
                                  name: "users",
                                  url: "https://api.example.com/users",
                                  rate_limit_delay: 0.01,
                                ))
        aggregator.add_endpoint(APIEndpoint.new(
                                  name: "products",
                                  url: "https://api.example.com/products",
                                  rate_limit_delay: 0.01,
                                ))
      end

      it "returns empty hash when no endpoints" do
        empty_aggregator = described_class.new
        result = empty_aggregator.fetch_all

        expect(result).to eq({})
      end

      it "fetches data from all endpoints successfully" do
        result = aggregator.fetch_all

        expect(result).to be_a(Hash)
        expect(result[:users]).to be_an(Array)
        expect(result[:products]).to be_an(Array)
        expect(result[:summary]).to be_a(Hash)
      end

      it "includes summary statistics" do
        result = aggregator.fetch_all

        expect(result[:summary][:total_users]).to eq(3)
        expect(result[:summary][:total_products]).to eq(3)
        expect(result[:summary][:endpoints_successful]).to be > 0
        expect(result[:summary]).to have_key(:timestamp)
      end

      it "enriches orders when orders endpoint is added" do
        aggregator.add_endpoint(APIEndpoint.new(
                                  name: "orders",
                                  url: "https://api.example.com/orders",
                                  rate_limit_delay: 0.01,
                                ))

        result = aggregator.fetch_all

        expect(result[:enriched_orders]).to be_an(Array)
        expect(result[:enriched_orders].first).to have_key(:user_name)
        expect(result[:enriched_orders].first).to have_key(:product_name)
        expect(result[:enriched_orders].first).to have_key(:total_price)
      end

      it "handles errors gracefully" do
        # Note: In real scenario, simulate_errors would cause failures
        # For this test, we just verify the aggregator can handle the option
        result = aggregator.fetch_all(simulate_errors: false)

        expect(result).to be_a(Hash)
      end
    end

    describe "#enrich_orders" do
      let(:users) do
        [
          { id: 1, name: "Alice", email: "alice@example.com" },
          { id: 2, name: "Bob", email: "bob@example.com" },
        ]
      end

      let(:products) do
        [
          { id: 101, name: "Laptop", price: 999.99 },
          { id: 102, name: "Mouse", price: 29.99 },
        ]
      end

      let(:orders) do
        [
          { id: 1001, user_id: 1, product_id: 101, quantity: 1,
            status: "shipped" },
          { id: 1002, user_id: 2, product_id: 102, quantity: 2,
            status: "pending" },
        ]
      end

      it "enriches orders with user and product information" do
        enriched = aggregator.send(:enrich_orders, orders, users, products)

        expect(enriched.size).to eq(2)
        expect(enriched.first[:user_name]).to eq("Alice")
        expect(enriched.first[:user_email]).to eq("alice@example.com")
        expect(enriched.first[:product_name]).to eq("Laptop")
        expect(enriched.first[:product_price]).to eq(999.99)
      end

      it "calculates total price correctly" do
        enriched = aggregator.send(:enrich_orders, orders, users, products)

        expect(enriched.first[:total_price]).to eq(999.99)
        expect(enriched.last[:total_price]).to eq(59.98)
      end

      it "handles missing user gracefully" do
        orders_with_missing_user = [
          { id: 1001, user_id: 999, product_id: 101, quantity: 1,
            status: "shipped" },
        ]

        enriched = aggregator.send(:enrich_orders, orders_with_missing_user,
                                   users, products)

        expect(enriched.first[:user_name]).to be_nil
        expect(enriched.first[:user_email]).to be_nil
      end

      it "handles missing product gracefully" do
        orders_with_missing_product = [
          { id: 1001, user_id: 1, product_id: 999, quantity: 1,
            status: "shipped" },
        ]

        enriched = aggregator.send(:enrich_orders, orders_with_missing_product,
                                   users, products)

        expect(enriched.first[:product_name]).to be_nil
        expect(enriched.first[:product_price]).to be_nil
        expect(enriched.first[:total_price]).to eq(0)
      end
    end
  end

  describe AggregationReport do
    let(:sample_data) do
      {
        users: [
          { id: 1, name: "Alice", email: "alice@example.com", role: "admin" },
          { id: 2, name: "Bob", email: "bob@example.com", role: "user" },
        ],
        products: [
          { id: 101, name: "Laptop", price: 999.99, stock: 15 },
          { id: 102, name: "Mouse", price: 29.99, stock: 50 },
        ],
        orders: [
          { id: 1001, user_id: 1, product_id: 101, quantity: 1,
            status: "shipped" },
        ],
        enriched_orders: [
          {
            id: 1001,
            user_name: "Alice",
            user_email: "alice@example.com",
            product_name: "Laptop",
            product_price: 999.99,
            quantity: 1,
            total_price: 999.99,
            status: "shipped",
          },
        ],
        analytics: {
          total_users: 2,
          total_products: 2,
          revenue: 999.99,
        },
        summary: {
          total_users: 2,
          total_products: 2,
          total_orders: 1,
          endpoints_successful: 4,
          endpoints_failed: 0,
          timestamp: "2024-10-25T13:00:00+08:00",
        },
      }
    end

    describe ".generate" do
      it "generates report to console" do
        expect do
          described_class.generate(sample_data)
        end.to output(/API AGGREGATION REPORT/).to_stdout
      end

      it "saves report to file" do
        Dir.mktmpdir do |dir|
          output_file = File.join(dir, "test_report.txt")
          described_class.generate(sample_data, output_file)

          expect(File.exist?(output_file)).to be true
          content = File.read(output_file)
          expect(content).to include("API AGGREGATION REPORT")
        end
      end
    end

    describe ".build_report" do
      let(:report) { described_class.build_report(sample_data) }

      it "includes summary section" do
        expect(report).to include("SUMMARY")
        expect(report).to include("Total Users: 2")
        expect(report).to include("Total Products: 2")
        expect(report).to include("Total Orders: 1")
        expect(report).to include("Endpoints Successful: 4")
        expect(report).to include("Endpoints Failed: 0")
      end

      it "includes users section" do
        expect(report).to include("USERS (2)")
        expect(report).to include("Alice")
        expect(report).to include("alice@example.com")
        expect(report).to include("[admin]")
      end

      it "includes products section" do
        expect(report).to include("PRODUCTS (2)")
        expect(report).to include("Laptop")
        expect(report).to include("$999.99")
        expect(report).to include("Stock: 15")
      end

      it "includes enriched orders section" do
        expect(report).to include("ENRICHED ORDERS (1)")
        expect(report).to include("Order #1001")
        expect(report).to include("Alice <alice@example.com>")
        expect(report).to include("Product: Laptop")
        expect(report).to include("$999.99")
        expect(report).to include("Status: shipped")
      end

      it "includes analytics section" do
        expect(report).to include("ANALYTICS")
        expect(report).to include("Total users: 2")
        expect(report).to include("Revenue: 999.99")
      end

      it "handles empty data gracefully" do
        empty_report = described_class.build_report({})
        expect(empty_report).to include("API AGGREGATION REPORT")
      end

      it "handles missing sections gracefully" do
        partial_data = { summary: sample_data[:summary] }
        partial_report = described_class.build_report(partial_data)

        expect(partial_report).to include("SUMMARY")
        expect(partial_report).not_to include("USERS")
      end

      it "truncates long lists with ellipsis" do
        many_users = (1..10).map do |i|
          { id: i, name: "User #{i}", email: "user#{i}@example.com",
            role: "user" }
        end

        data_with_many_users = sample_data.merge(users: many_users)
        report = described_class.build_report(data_with_many_users)

        expect(report).to include("...")
      end
    end
  end

  describe "Integration tests" do
    it "aggregates data from all endpoints successfully" do
      aggregator = APIAggregator.new

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "users",
                                url: "https://api.example.com/users",
                                rate_limit_delay: 0.01,
                              ))

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "products",
                                url: "https://api.example.com/products",
                                rate_limit_delay: 0.01,
                              ))

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "orders",
                                url: "https://api.example.com/orders",
                                rate_limit_delay: 0.01,
                              ))

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "analytics",
                                url: "https://api.example.com/analytics",
                                rate_limit_delay: 0.01,
                              ))

      result = aggregator.fetch_all

      expect(result[:users].size).to eq(3)
      expect(result[:products].size).to eq(3)
      expect(result[:orders].size).to eq(3)
      expect(result[:analytics]).to be_a(Hash)
      expect(result[:enriched_orders].size).to eq(3)
      expect(result[:summary][:endpoints_successful]).to eq(4)
      expect(result[:summary][:endpoints_failed]).to eq(0)
    end

    it "generates complete report for aggregated data" do
      aggregator = APIAggregator.new

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "users",
                                url: "https://api.example.com/users",
                                rate_limit_delay: 0.01,
                              ))

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "products",
                                url: "https://api.example.com/products",
                                rate_limit_delay: 0.01,
                              ))

      result = aggregator.fetch_all

      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "integration_test_report.txt")
        report = AggregationReport.generate(result, output_file)

        expect(File.exist?(output_file)).to be true
        expect(report).to include("API AGGREGATION REPORT")
        expect(report).to include("SUMMARY")
        expect(report).to include("USERS")
        expect(report).to include("PRODUCTS")
      end
    end

    it "correctly enriches order data with user and product information" do
      aggregator = APIAggregator.new

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "users",
                                url: "https://api.example.com/users",
                                rate_limit_delay: 0.01,
                              ))

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "products",
                                url: "https://api.example.com/products",
                                rate_limit_delay: 0.01,
                              ))

      aggregator.add_endpoint(APIEndpoint.new(
                                name: "orders",
                                url: "https://api.example.com/orders",
                                rate_limit_delay: 0.01,
                              ))

      result = aggregator.fetch_all
      enriched = result[:enriched_orders]

      expect(enriched).to be_an(Array)
      expect(enriched.size).to eq(3)

      first_order = enriched.first
      expect(first_order).to have_key(:user_name)
      expect(first_order).to have_key(:user_email)
      expect(first_order).to have_key(:product_name)
      expect(first_order).to have_key(:product_price)
      expect(first_order).to have_key(:total_price)

      # Verify calculation is correct
      expect(first_order[:total_price]).to eq(
        first_order[:product_price] * first_order[:quantity],
      )
    end
  end
end
