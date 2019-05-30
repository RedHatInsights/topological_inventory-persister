require "manageiq/loggers"

module TopologicalInventory
  module Persister
    class << self
      attr_writer :logger
    end

    def self.logger
      @logger ||= ManageIQ::Loggers::CloudWatch.new
    end

    module Logging
      def logger
        TopologicalInventory::Persister.logger
      end
    end
  end
end
