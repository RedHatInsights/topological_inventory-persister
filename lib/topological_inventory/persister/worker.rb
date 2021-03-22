require "inventory_refresh"
require "manageiq-messaging"
require "topological_inventory/persister/exception"
require "topological_inventory/persister/logging"
require "topological_inventory/persister/workflow"
require "topological_inventory/persister/metrics"
require "topological_inventory/persister/clowder_config"
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
        logger.error("#{e.class}:  #{e.message}\n#{e.backtrace.join("\n")}")
      ensure
        client&.close
        metrics&.stop_server
      end

      private

      attr_accessor :messaging_client_opts, :client, :metrics

      def process_message(client, msg)
        payload = msg.payload
        payload = JSON.parse(payload) if payload.is_a?(String)

        # Skip if it's been too long since ingress sent the data and it is a full-refresh
        # i.e. this data is probably stale and theres new data most likely collected
        if skip_message?(payload)
          logger.debug("Skipping full-refresh, message outside of time threshold")
          metrics.record_process(:skipped)
          return
        end

        metrics_status = TopologicalInventory::Persister::Workflow.new(load_persister(payload), client, payload).execute!

        metrics_status, metrics_labels = case metrics_status
                                         when :sweep_limit_error then [:error, {:error_class => 'SweepRetryLimit'}]
                                         when :sweep_start_error then [:error, {:error_class => 'SweepStartError'}]
                                         else [(metrics_status.presence || :success), {}]
                                         end

        metrics.record_process(metrics_status, metrics_labels)
      rescue PG::ConnectionBad, ::Rdkafka::Producer::DeliveryHandle::WaitTimeoutError, ::Rdkafka::RdkafkaError => e
        log_err_and_send_metric(e)
        raise
      rescue ActiveRecord::StatementInvalid => e
        log_err_and_send_metric(e)

        if e.message =~ /^PG::UnableToSend/
          raise
        end
      rescue TopologicalInventory::Persister::Exception::SourceUidNotFound => e
        log_warn(e)
      rescue => e
        log_err_and_send_metric(e)
        nil
      ensure
        touch_heartbeat
      end

      def log_err_and_send_metric(e)
        metrics.record_process(:error, :error_class => e.class.name)
        logger.error("#{e.class}:  #{e.message}\n#{e.backtrace.join("\n")}")
      end

      def log_warn(e)
        logger.warn("#{e.class}:  #{e.message}\n#{e.backtrace.join("\n")}")
      end

      def load_persister(payload)
        source = Source.find_by(:uid => payload["source"])
        raise(TopologicalInventory::Persister::Exception::SourceUidNotFound,
              "Couldn't find source with uid #{payload["source"]}") if source.nil?

        schema_name  = payload.dig("schema", "name")
        schema_klass = schema_klass_name(schema_name).safe_constantize
        raise(TopologicalInventory::Persister::Exception::InvalidSchemaName,
              "Invalid schema #{schema_name}") if schema_klass.nil?

        schema_klass.from_hash(payload, source)
      end

      def schema_klass_name(name)
        "TopologicalInventory::Schema::#{name}"
      end

      def queue_opts
        {
          :service     => TopologicalInventory::Persister::ClowderConfig.kafka_topic("platform.topological-inventory.persister"),
          :persist_ref => "persister_worker"
        }
      end

      def default_messaging_opts
        {
          :protocol   => :Kafka,
          :client_ref => ENV['HOSTNAME'].presence || SecureRandom.hex(4),
          :encoding   => "json",
        }
      end

      def skip_message?(payload)
        payload["refresh_type"] == "full-refresh" && payload["ingress_api_sent_at"].to_time <= timeout
      rescue
        false
      end

      def timeout
        (ENV['PERSISTER_TIMEOUT']&.to_i || 60).minutes.ago
      end

      def touch_heartbeat
        FileUtils.touch("/tmp/healthy")
      end
    end
  end
end
