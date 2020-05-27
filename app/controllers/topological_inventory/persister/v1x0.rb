module TopologicalInventory
  module Persister
    module V1x0
      class RootController < ApplicationController
        def openapi
          render :json => TopologicalInventory::IngressApi::Docs["1.0"].to_json
        end
      end
      class InventoryController < PersisterApi::V0::InventoryController; end
    end
  end
end
