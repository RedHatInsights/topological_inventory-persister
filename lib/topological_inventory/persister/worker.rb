require "inventory_refresh"
require "manageiq-messaging"
require "topological_inventory/persister/logging"
require "topological_inventory/persister/workflow"
require "topological_inventory/persister/metrics"
require "topological_inventory/schema"

module TopologicalInventory
  module Persister
    class Worker
      include Logging

      def initialize(opts = {})
        messaging_client_opts = opts.select { |k, _| %i[host port].include?(k) }
        self.messaging_client_opts = default_messaging_opts.merge(messaging_client_opts)

        InventoryRefresh.logger = logger
        self.metrics = TopologicalInventory::Persister::Metrics.new(opts[:metrics_port])
      end

      def run
        # Open a connection to the messaging service
        self.client = ManageIQ::Messaging::Client.open(messaging_client_opts)

        logger.info("Topological Inventory Persister started...")

        client.subscribe_topic(queue_opts) do |msg|
          metrics.record_process_timing { process_message(client, msg) }
        end
      rescue => e
        logger.error(e.message)
        logger.error(e.backtrace.join("\n"))
      ensure
        client&.close
        metrics&.stop_server
      end

      private

      attr_accessor :messaging_client_opts, :client, :metrics

      def process_message(client, msg)
        TopologicalInventory::Persister::Workflow.new(load_persister(msg.payload), client, msg.payload).execute!
      rescue PG::ConnectionBad, Kafka::DeliveryFailed, Kafka::ConnectionError => e
        log_err_and_send_metric(e)
        raise
      rescue ActiveRecord::StatementInvalid => e
        log_err_and_send_metric(e)

        if e.message =~ /^PG::UnableToSend/
          raise
        end
      rescue => e
        log_err_and_send_metric(e)
        nil
      else
        metrics.record_process
      end

      def log_err_and_send_metric(e)
        metrics.record_process(false)
        logger.error("#{e.class}:  #{e.message}")
        logger.error(e.backtrace.join("\n"))
      end

      def load_persister(payload)
        source = Source.find_by(:uid => payload["source"])
        raise "Couldn't find source with uid #{payload["source"]}" if source.nil?

        schema_name  = payload.dig("schema", "name")
        schema_klass = schema_klass_name(schema_name).safe_constantize
        raise "Invalid schema #{schema_name}" if schema_klass.nil?

        schema_klass.from_hash(payload, source)
      end

      def schema_klass_name(name)
        "TopologicalInventory::Schema::#{name}"
      end

      def queue_opts
        {
          :service     => "platform.topological-inventory.persister",
          :persist_ref => "persister_worker"
        }
      end

      def default_messaging_opts
        {
          :protocol   => :Kafka,
          :client_ref => "persister-worker",
          :group_ref  => "persister-worker",
          :encoding   => "json",
        }
      end
    end
  end
end
