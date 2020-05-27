module TopologicalInventory
  module Persister
    Docs = ::Insights::API::Common::OpenApi::Docs.new(Dir.glob(Rails.root.join("public", "doc", "openapi*.json")))
  end
end
