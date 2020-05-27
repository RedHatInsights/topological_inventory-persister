require "topological_inventory/persister/docs"
require "topological_inventory/persister/messaging_client"

module TopologicalInventory
  module Persister
    module V1
      class InventoryController < ::ApplicationController
        include TopologicalInventory::Persister::MessagingClient

        # before_action :add_timestamp_to_payload, :only => %i[save_inventory]
        before_action :validate_request

        def add_timestamp_to_payload
          body_params['ingress_api_sent_at'] = Time.now.utc.to_s
        end

        # TODO: add rescue blocks
        def save_inventory
          self.class.with_messaging_client do |client|
            payload = body_params
            TopologicalInventory::Persister::Workflow.new(load_persister(payload), client, payload).execute!
          end

          # metrics.message_on_queue
          render status: 200, :json => {
            :message => "ok",
          }.to_json
        rescue => e
          # metrics.error_processing_payload
          render :status => 500, :json => {
            :message    => e.message,
            :error_code => e.class.to_s,
          }.to_json

          raise e
        end

        private

        def metrics
          Insights::API::Common::Metrics
        end
      end
    end
  end
end
