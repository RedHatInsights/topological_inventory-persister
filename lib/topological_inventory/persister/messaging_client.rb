module TopologicalInventory
  module Persister
    module MessagingClient
      extend ActiveSupport::Concern

      included do
        private_class_method :messaging_client,
                             :messaging_client=,
                             :new_messaging_client
      end

      module ClassMethods
        def with_messaging_client
          messaging_client ||= new_messaging_client
          raise if messaging_client.nil?

          begin
            yield messaging_client
          rescue Kafka::MessageSizeTooLarge
            # Don't reset the connection for user-error
            raise
          rescue Kafka::Error
            # If we hit an underlying kafka error then reset the connection
            messaging_client.close
            self.messaging_client = nil

            raise
          end
        end

        def messaging_client
          Thread.current[:messaging_client]
        end

        def messaging_client=(value)
          Thread.current[:messaging_client] = value
        end

        def new_messaging_client(retry_max = 1)
          retry_count = 0
          begin
            ManageIQ::Messaging::Client.open(
              :encoding => "json",
              :host     => ENV["QUEUE_HOST"] || "localhost",
              :port     => ENV["QUEUE_PORT"] || "9092",
              :protocol => :Kafka,
            )
          end
        rescue Kafka::ConnectionError
          retry_count += 1
          retry unless retry_count > retry_max
        end
      end
    end
  end
end
