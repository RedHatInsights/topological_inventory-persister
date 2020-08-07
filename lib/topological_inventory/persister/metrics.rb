require "benchmark"
require "prometheus_exporter"
require "prometheus_exporter/server"
require "prometheus_exporter/client"
require 'prometheus_exporter/instrumentation'

module TopologicalInventory
  module Persister
    class Metrics
      def initialize(port = 9394)
        return if port == 0

        configure_server(port)
        configure_metrics
      end

      def record_process(success = true)
        @process_counter&.observe(1, :result => case success
                                                when true
                                                  "success"
                                                when false
                                                  "error"
                                                when :skipped
                                                  "skipped"
                                                end
        )
      end

      def record_process_timing
        time = Benchmark.realtime { yield }
        @process_timer&.observe(time)
      end

      def stop_server
        @server&.stop
      end

      private

      def configure_server(port)
        @server = PrometheusExporter::Server::WebServer.new(:port => port)
        @server.start

        PrometheusExporter::Client.default = PrometheusExporter::LocalClient.new(:collector => @server.collector)
      end

      def configure_metrics
        PrometheusExporter::Instrumentation::Process.start

        PrometheusExporter::Metric::Base.default_prefix = "topological_inventory_persister_"

        @process_counter = PrometheusExporter::Metric::Counter.new("messages_total", "total number of messages processed")
        @process_timer = PrometheusExporter::Metric::Histogram.new("message_process_seconds", "time it took to process messages")
        @server.collector.register_metric(@process_counter)
        @server.collector.register_metric(@process_timer)
      end
    end
  end
end
