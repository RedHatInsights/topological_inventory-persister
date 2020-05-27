module TopologicalInventory
  module Persister
    module V1
      class SchemasController < ApplicationController
        def index
          render json: ["Default"]
        end
      end
    end
  end
end
