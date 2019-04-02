require "benchmark"
require "prometheus_exporter"
require "prometheus_exporter/client"

module TopologicalInventory
  module Persister
    class Metrics
      def initialize
        @client = PrometheusExporter::Client.default
        @process_counter = @client.register(:counter, "messages_total", "total number of messages processed")
        @process_timer = @client.register(:histogram, "message_process_seconds", "time it took to process messages")
      end

      def record_process(success = true)
        @process_counter.observe(1, :result => success ? "success" : "error")
      end

      def record_process_timing
        time = Benchmark.realtime { yield }
        @process_timer.observe(time)
      end
    end
  end
end
