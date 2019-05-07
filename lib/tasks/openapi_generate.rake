class OpenapiGenerator
  require 'json'

  PARAMETERS_PATH = "/components/parameters".freeze
  SCHEMAS_PATH    = "/components/schemas".freeze

  def path_parts(openapi_path)
    openapi_path.split("/")[1..-1]
  end

  # Let's get the latest api version based on the openapi.json routes
  def api_version
    @api_version ||= Rails.application.routes.routes.each_with_object([]) do |route, array|
      matches = ActionDispatch::Routing::RouteWrapper
                .new(route)
                .path.match(/\A.*\/v(\d+.\d+)\/openapi.json.*\z/)
      array << matches[1] if matches
    end.max
  end

  def openapi_file
    # TODO(lsmola) how does topo API loads the version?
    # @openapi_file ||= Pathname.new(__dir__).join("../../public/doc/openapi-3-v#{api_version}.json").to_s
    @openapi_file ||= Pathname.new(__dir__).join("../../../topological_inventory-ingress_api/public/doc/openapi-3-v0.0.2.json").to_s
  end

  def openapi_contents
    @openapi_contents ||= begin
      JSON.parse(File.read(openapi_file))
    end
  end

  def initialize
    # TODO(lsmola) move the instance variable init here
  end

  def schemas
    @schemas ||= {}
  end

  def reference_types
    @reference_types ||= {}
  end

  def build_schema(klass_name)
    schemas[klass_name] = openapi_schema(klass_name)
  end

  # Collects what types of reference_types are there for each inventory collection (e.g. primary, by_name, etc.)
  def build_reference_types(inventory_collection)
    class_name = inventory_collection.model_class.to_s

    reference_types[class_name] ||= []
    reference_types[class_name] << "#{inventory_collection.name.to_s.camelize}Reference"
    inventory_collection.secondary_refs.each do |key, _value|
      reference_types[class_name] << "#{inventory_collection.name.to_s.camelize}Reference#{key.to_s.camelize}"
    end
  end

  def build_references_schema(inventory_collection)
    add_primary_reference_schema(inventory_collection)
    inventory_collection.secondary_refs.each do |key, _value|
      add_secondary_reference_schema(inventory_collection, key)
    end
  end

  def add_primary_reference_schema(inventory_collection)
    class_name                                                     = inventory_collection.model_class.to_s
    schemas["#{inventory_collection.name.to_s.camelize}Reference"] = lazy_find(class_name, inventory_collection)
  end

  def add_secondary_reference_schema(inventory_collection, key)
    class_name = inventory_collection.model_class.to_s

    schemas["#{inventory_collection.name.to_s.camelize}Reference#{key.to_s.camelize}"] = lazy_find(class_name, inventory_collection, key)
  end

  def parameters
    @parameters ||= {}
  end

  def build_parameter(name, value = nil)
    parameters[name] = value
    "##{PARAMETERS_PATH}/#{name}"
  end

  # Required cols are all cols having NOT NULL constraint that are not blacklisted
  def required_cols(model, used_attrs)
    required_cols = model.columns_hash.values.reject(&:null).map(&:name).map do |name|
      (foreign_key_to_association_mapping(model)[name] || name).to_s
    end
    (required_cols & used_attrs).sort
  end

  def openapi_schema(klass_name)
    model      = klass_name.constantize
    properties = openapi_schema_properties(klass_name)

    {
      "allOf" => [
        {
          :"$ref" => "#/components/schemas/InventoryObject"
        },
        {
          "type"       => "object",
          "required"   => required_cols(model, properties.keys),
          "properties" => properties
        }
      ]
    }
  end

  def openapi_schema_properties(klass_name, only_columns = nil)
    model        = klass_name.constantize
    used_columns = model.columns_hash
    used_columns = used_columns.slice(*only_columns) if only_columns

    used_columns.map do |key, value|
      unless (GENERATOR_ALLOW_BLACKLISTED_ATTRIBUTES[key.to_sym] || []).include?(klass_name)
        next if GENERATOR_BLACKLIST_ATTRIBUTES.include?(key.to_sym)
      end
      openapi_schema_properties_value(klass_name, model, key, value)
    end.compact.sort_by(&:first).to_h
  end

  def inventory_collections
    return @inventory_collections_cache if @inventory_collections_cache

    mock_source = Source.new(:uid => "mock", :tenant => Tenant.new(:external_tenant => "mock"))
    schema      = TopologicalInventory::Schema::Default.new(mock_source)

    @inventory_collections_cache = schema.collections
  end

  def lazy_find(klass_name, inventory_collection, ref = :manager_ref)
    {
      "type"       => "object",
      "required"   => [
        "inventory_collection_name",
        "reference",
        "ref"
      ],
      "properties" => {
        "inventory_collection_name" => {
          "type" => "string",
          "enum" => [inventory_collection.name]
        },
        "reference"                 => lazy_find_reference(klass_name, inventory_collection, ref),
        "ref"                       => {
          "type" => "string",
          "enum" => [ref]
        }
      }
    }
  end

  def lazy_find_reference(klass_name, inventory_collection, ref)
    attrs = if ref == :manager_ref
              inventory_collection.manager_ref
            else
              inventory_collection.secondary_refs[ref]
            end

    columns = attrs.map do |col|
      association_to_foreign_key_mapping(inventory_collection.model_class)[col] || col
    end

    {
      "type"       => "object",
      "required"   => attrs.map(&:to_s),
      "properties" => openapi_schema_properties(klass_name, columns.map(&:to_s))
    }
  end

  def openapi_schema_properties_value(klass_name, model, key, value)
    if (foreign_key = foreign_key_mapping(model)[key])
      ref_types = if foreign_key.polymorphic?
                    polymorphic_types(foreign_key.name.to_s).map { |x| reference_types[x] }.flatten
                  else
                    inventory_collection_name      = foreign_key.table_name
                    reference_inventory_collection = inventory_collections[inventory_collection_name.to_sym]

                    reference_types[reference_inventory_collection.model_class.to_s]
                  end

      if GENERATOR_LIMIT_ATTRIBUTE_REFERENCES[foreign_key.name.to_s]
        ref_types = GENERATOR_LIMIT_ATTRIBUTE_REFERENCES[foreign_key.name.to_s]
      end

      ref_types.delete_if do |ref_type|
        GENERATOR_LIMIT_REFERENCE_USAGE[ref_type] && !GENERATOR_LIMIT_REFERENCE_USAGE[ref_type].include?(foreign_key.name.to_s)
      end

      refs = if ref_types.size > 1
               # TODO(lsmola) this should also have
               # "discriminator" => { "propertyName" => "ref"}
               # but also a custom mappings
               # mapping:
               #     by_name: '#/components/schemas/ContainerNodeReferenceByName'
               #     manager_ref: '#/components/schemas/ContainerNodeReference'
               {
                 "oneOf" => ref_types.map { |ref_type| {"$ref" => "##{SCHEMAS_PATH}/#{ref_type}"} }
               }
             else
               raise "Can't find allowed references for #{klass_name}, attribute: #{foreign_key.name}" if ref_types.empty?

               {"$ref" => "##{SCHEMAS_PATH}/#{ref_types.first}"}
             end

      if value.null
        refs["nullable"] = true
      end
      [foreign_key.name.to_s, refs]
    else
      return if (foreign_key = foreign_key_mapping(model)[key.gsub("_type", "_id")]) && foreign_key.polymorphic?

      properties_value = {
        "type" => "string"
      }

      case value.sql_type_metadata.type
      when :datetime
        properties_value["format"] = "date-time"
      when :integer
        properties_value["type"] = "integer"
      when :float
        properties_value["type"] = "number"
      when :boolean
        properties_value["type"] = "boolean"
      when :jsonb
        properties_value["type"] = "object"
        ['type', 'items'].each do |property_key|
          prop                           = openapi_contents.dig(*path_parts(SCHEMAS_PATH), klass_name, "allOf", 1, "properties", key, property_key)
          properties_value[property_key] = prop if prop.present?
        end
      end

      # require 'byebug'; byebug if key.to_s == "cpu_limit"

      # Take existing attrs, that we won't generate
      ['example', 'format', 'readOnly', 'title', 'description'].each do |property_key|
        property_value                 = openapi_contents.dig(*path_parts(SCHEMAS_PATH), klass_name, "allOf", 1, "properties", key, property_key)
        properties_value[property_key] = property_value if property_value
      end

      if value.null
        properties_value["nullable"] = true
      end

      [key, properties_value.sort.to_h]
    end
  end

  # @return [Array<ActiveRecord::Reflection::BelongsToReflection">] All belongs_to associations
  def belongs_to_associations(model_class)
    model_class.reflect_on_all_associations.select { |x| x.kind_of?(ActiveRecord::Reflection::BelongsToReflection) }
  end

  # @return [Hash{String => Hash}] Hash with foreign_key column name mapped to association name
  def foreign_key_to_association_mapping(model_class)
    return {} unless model_class

    (@foreign_key_to_association_mapping ||= {})[model_class] ||= belongs_to_associations(model_class).each_with_object({}) do |x, obj|
      obj[x.foreign_key] = x.name
    end
  end

  # @return [Hash{Symbol => String}] Hash with association name mapped to foreign key column name
  def association_to_foreign_key_mapping(model_class)
    return {} unless model_class

    (@association_to_foreign_key_mapping ||= {})[model_class] ||= belongs_to_associations(model_class).each_with_object({}) do |x, obj|
      obj[x.name] = x.foreign_key.to_s
    end
  end

  # @return [Hash{String => Hash}] Hash with foreign_key column name mapped to association name
  def foreign_key_to_table_name_mapping(model_class)
    return {} unless model_class

    (@foreign_key_to_table_name_mapping ||= {})[model_class] ||= belongs_to_associations(model_class).each_with_object({}) do |x, obj|
      obj[x.foreign_key] = x.table_name
    end
  end

  # @return [Hash{String => Hash}] Hash with foreign_key column name mapped to association name
  def foreign_key_mapping(model_class)
    return {} unless model_class

    (@foreign_key_mapping ||= {})[model_class] ||= belongs_to_associations(model_class).each_with_object({}) do |x, obj|
      obj[x.foreign_key] = x
    end
  end

  def connection
    ApplicationRecord.connection
  end

  def run
    # TODO(lsmola) Split Inventory to Inventory & Sweeping
    schemas["Inventory"] = {
      :type       => "object",
      :required   => ["schema", "source"],
      :properties => {
        :name                    => {
          :type => "string"
        },
        :schema                  => {
          :"$ref" => "#/components/schemas/Schema"
        },
        :source                  => {
          :"$ref" => "#/components/schemas/Source"
        },
        :refresh_state_uuid      => {
          :type   => "string",
          :format => "uuid"
        },
        :refresh_state_part_uuid => {
          :type   => "string",
          :format => "uuid"
        },
        :total_parts             => {
          :type => "integer"
        },
        :sweep_scope             => {
          :type => "object"
        },
        :collections             => {
          :type  => "array",
          :items => {
            :"$ref" => "#/components/schemas/InventoryCollection"
          }
        }
      }
    }

    schemas["InventoryCollection"] = {
      :type       => "object",
      :required   => ["name"],
      :properties => {
        :name         => {
          :type => "string"
        },
        :data         => {
          :type  => "array",
          :items => {
            :"$ref" => "#/components/schemas/InventoryObject"
          }
        },
        :partial_data => {
          :type  => "array",
          :items => {
            :"$ref" => "#/components/schemas/InventoryObject"
          }
        }
      }
    }

    schemas["InventoryObject"] = {
      :type => "object"
    }

    schemas["InventoryObjectLazy"] = {
      :type       => "object",
      :required   => ["inventory_collection_name", "reference", "ref"],
      :properties => {
        :inventory_collection_name => {
          :type => "string"
        },
        :reference                 => {
          :type       => "object",
          :properties => {
          }
        },
        :ref                       => {
          :type => "string"
        }
        # "key":                         {
        #   "type": "string"
        # },
        # "default":                     {
        #   "type":       "object",
        #   "properties": {
        #   }
        # },
        # "transform_nested_lazy_finds": {
        #   "type": "boolean"
        # }
      }
    }

    inventory_collections.each do |_key, inventory_collection|
      build_reference_types(inventory_collection)
    end

    inventory_collections.each do |_key, inventory_collection|
      build_references_schema(inventory_collection)
    end

    inventory_collections.each do |_key, inventory_collection|
      build_schema(inventory_collection.model_class.to_s)
    end

    cleanup_unused_schemas!

    new_content                             = openapi_contents
    new_content["paths"]                    = openapi_contents.dig("paths")
    new_content["components"] ||= {}
    new_content["components"]["schemas"]    = schemas.sort.each_with_object({}) { |(name, val), h| h[name] = val }
    new_content["components"]["parameters"] = parameters.sort.each_with_object({}) { |(name, val), h| h[name] = val || openapi_contents["components"]["parameters"][name] || {} }
    File.write(openapi_file, JSON.pretty_generate(new_content) + "\n")
  end

  # Remove references that are not used. E.g. ContainerNodeTagReference ? That reference is not allowed
  # to be used anywhere.
  def cleanup_unused_schemas!
    schemas_string      = JSON.generate(schemas)
    used_references     = schemas_string.scan(/\{\"\$ref\":\"#\/components\/schemas\/(.*?)\"/).flatten.uniq
    existing_references = schemas.keys.select { |x| x.include?("Reference") }
    unused_references   = existing_references - used_references

    schemas.except!(*unused_references)
  end

  def polymorphic_types(attribute)
    case attribute
    when "lives_on"
      ["Vm"]
    else
      []
    end
  end

  GENERATOR_BLACKLIST_ATTRIBUTES = [
    :id, :resource_timestamps, :resource_timestamps_max, :tenant_id, :source_id, :created_at, :updated_at, :last_seen_at
  ].to_set.freeze

  GENERATOR_ALLOW_BLACKLISTED_ATTRIBUTES = {}.freeze
  # Format is:
  # {
  #   :tenant_id => ['Source', 'Endpoint', 'Authentication', 'Application'].to_set
  # }.freeze

  # Limits reference only for a certain attribute
  GENERATOR_LIMIT_REFERENCE_USAGE = {
    "CrossLinkVmsReference" => ["lives_on"]
  }.freeze

  # Hardcode references for certain attributes
  GENERATOR_LIMIT_ATTRIBUTE_REFERENCES = {
    "lives_on" => ["CrossLinkVmsReference"]
  }.freeze
end

$LOAD_PATH << File.expand_path("../lib", __dir__)
require "bundler/setup"
require "topological_inventory/schema/default"
require "topological_inventory/core/ar_helper"

TopologicalInventory::Core::ArHelper.database_yaml_path = Pathname.new(__dir__).join("../../config/database.yml")
TopologicalInventory::Core::ArHelper.load_environment!

namespace :openapi do
  desc "Generate the openapi.json contents"
  task :generate do
    OpenapiGenerator.new.run
  end
end
