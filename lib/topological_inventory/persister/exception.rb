module TopologicalInventory
  module Persister
    module Exception
      class Error < StandardError; end
      class SourceUidNotFound < Error; end
      class InvalidSchemaName < Error; end
    end
  end
end
