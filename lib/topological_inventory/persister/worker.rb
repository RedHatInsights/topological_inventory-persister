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

      def initialize(messaging_client_opts = {})
        self.messaging_client_opts = default_messaging_opts.merge(messaging_client_opts)

        InventoryRefresh.logger = logger
        self.metrics = TopologicalInventory::Persister::Metrics.new
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
        schema_class, source = load_schema_class_and_source(msg.payload)

        TopologicalInventory::Persister::Workflow.new(schema_class, source, client, msg.payload).execute!
      rescue => e
        metrics.record_process(false)
        logger.error(e.message)
        logger.error(e.backtrace.join("\n"))
        nil
      else
        metrics.record_process
      end

      def load_schema_class_and_source(payload)
        source = Source.find_by(:uid => payload["source"])
        raise "Couldn't find source with uid #{payload["source"]}" if source.nil?

        schema_name  = payload.dig("schema", "name")
        schema_klass = schema_klass_name(schema_name).safe_constantize
        raise "Invalid schema #{schema_name}" if schema_klass.nil?

        return schema_klass, source
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
