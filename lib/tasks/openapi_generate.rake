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

  # def rails_routes
  #   Rails.application.routes.routes.each_with_object([]) do |route, array|
  #     r = ActionDispatch::Routing::RouteWrapper.new(route)
  #     next if r.internal? # Don't display rails routes
  #     next if r.engine? # Don't care right now...
  #
  #     array << r
  #   end
  # end

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
    # TODO(lsmola) what should be the format here?
    # app_prefix, app_name = base_path.match(/\A(.*)\/(.*)\/v\d+.\d+\z/).captures
    # ENV['APP_NAME'] = app_name
    # ENV['PATH_PREFIX'] = app_prefix
    # Rails.application.reload_routes!
  end

  def base_path
    openapi_contents["servers"].first["variables"]["basePath"]["default"]
  end

  def applicable_rails_routes
    rails_routes.select { |i| i.path.start_with?(base_path) }
  end

  def build_paths
    applicable_rails_routes.each_with_object({}) do |route, expected_paths|
      without_format     = route.path.split("(.:format)").first
      sub_path           = without_format.split(base_path).last.sub(/:[_a-z]*id/, "{id}")
      klass_name         = route.controller.split("/").last.camelize.singularize
      verb               = route.verb.downcase
      primary_collection = sub_path.split("/")[1].camelize.singularize

      expected_paths[sub_path]       ||= {}
      expected_paths[sub_path][verb] =
        case route.action
        when "index" then
          openapi_list_description(klass_name, primary_collection)
        when "show" then
          openapi_show_description(klass_name)
        when "destroy" then
          openapi_destroy_description(klass_name)
        when "create" then
          openapi_create_description(klass_name)
        when "update" then
          openapi_update_description(klass_name, verb)
        else
          if verb == "get" && GENERATOR_IMAGE_MEDIA_TYPE_DEFINITIONS.include?(route.action.camelize)
            openapi_show_image_media_type_description(route.action.camelize, primary_collection)
          end
        end

      unless expected_paths[sub_path][verb]
        # If it's not generic action but a custom method like e.g. `post "order", :to => "service_plans#order"`, we will
        # try to take existing schema, because the description, summary, etc. are likely to be custom.
        expected_paths[sub_path][verb] =
          case verb
          when "post"
            openapi_contents.dig("paths", sub_path, verb) || openapi_create_description(klass_name)
          when "get"
            openapi_contents.dig("paths", sub_path, verb) || openapi_show_description(klass_name)
          else
            openapi_contents.dig("paths", sub_path, verb)
          end
      end
    end
  end

  def schemas
    @schemas ||= {}
  end

  def references
    @references ||= {}
  end

  def build_schema(klass_name)
    schemas[klass_name] = openapi_schema(klass_name)
    "##{SCHEMAS_PATH}/#{klass_name}"
  end

  def build_references_schema(inventory_collection)
    references[inventory_collection.model_class.to_s] ||= []

    references[inventory_collection.model_class.to_s] << add_primary_reference_schema(inventory_collection)
    inventory_collection.secondary_refs.each do |key, value|
      references[inventory_collection.model_class.to_s] << add_secondary_reference_schema(inventory_collection, key, value)
    end
  end

  def add_primary_reference_schema(inventory_collection)
    class_name = inventory_collection.model_class.to_s
    schemas["#{class_name}Reference"] = lazy_find(class_name, inventory_collection)
  end

  def add_secondary_reference_schema(inventory_collection, key, value)
    class_name = inventory_collection.model_class.to_s

    schemas["#{inventory_collection.model_class.to_s}Reference#{key.to_s.camelize}"] = lazy_find(class_name, inventory_collection)
  end

  def parameters
    @parameters ||= {}
  end

  def build_parameter(name, value = nil)
    parameters[name] = value
    "##{PARAMETERS_PATH}/#{name}"
  end

  def openapi_list_description(klass_name, primary_collection)
    primary_collection = nil if primary_collection == klass_name
    {
      "summary"     => "List #{klass_name.pluralize}#{" for #{primary_collection}" if primary_collection}",
      "operationId" => "list#{primary_collection}#{klass_name.pluralize}",
      "description" => "Returns an array of #{klass_name} objects",
      "parameters"  => [
        {"$ref" => "##{PARAMETERS_PATH}/QueryLimit"},
        {"$ref" => "##{PARAMETERS_PATH}/QueryOffset"},
        {"$ref" => "##{PARAMETERS_PATH}/QueryFilter"}
      ],
      "responses"   => {
        "200" => {
          "description" => "#{klass_name.pluralize} collection",
          "content"     => {
            "application/json" => {
              "schema" => {"$ref" => build_collection_schema(klass_name)}
            }
          }
        }
      }
    }.tap do |h|
      h["parameters"] << {"$ref" => build_parameter("ID")} if primary_collection
    end
  end

  def build_collection_schema(klass_name)
    collection_name          = "#{klass_name.pluralize}Collection"
    schemas[collection_name] = {
      "type"       => "object",
      "properties" => {
        "meta"  => {"$ref" => "##{SCHEMAS_PATH}/CollectionMetadata"},
        "links" => {"$ref" => "##{SCHEMAS_PATH}/CollectionLinks"},
        "data"  => {
          "type"  => "array",
          "items" => {"$ref" => build_schema(klass_name)}
        }
      }
    }

    "##{SCHEMAS_PATH}/#{collection_name}"
  end

  def openapi_schema(klass_name)
    {
      "type"       => "object",
      "properties" => openapi_schema_properties(klass_name),
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

  def lazy_find(klass_name, inventory_collection, ref=:manager_ref)
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
    columns = if ref == :manager_ref
                inventory_collection.manager_ref_to_cols.map(&:to_s)
              else
                inventory_collection.secondary_refs[ref].map do |ref|
                  association_to_foreign_key_mapping(klass_name)[ref] || ref
                end
              end

    {
      "type"       => "object",
      "required"   => inventory_collection.manager_ref,
      "properties" => openapi_schema_properties(klass_name, columns)
    }
  end

  def openapi_schema_properties_value(klass_name, model, key, value)
    if key == model.primary_key
      [key, {"$ref" => "##{SCHEMAS_PATH}/ID"}]
    elsif (foreign_key = foreign_key_mapping(model)[key])

      # TODO(lsmola) deal with polymorphic relations, then we can allow all types of lazy_references?
      # require 'byebug'; byebug if foreign_key.polymorphic?
      # TODO(lsmola) ignore also the _type column
      return if foreign_key.polymorphic?
      inventory_collection_name      = foreign_key.table_name
      reference_inventory_collection = inventory_collections[inventory_collection_name.to_sym]

      [foreign_key.name.to_s, {"$ref" => "##{SCHEMAS_PATH}/#{reference_inventory_collection.model_class.to_s}Reference"}]
    else
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
          prop                           = openapi_contents.dig(*path_parts(SCHEMAS_PATH), klass_name, "properties", key, property_key)
          properties_value[property_key] = prop if prop.present?
        end
      end

      # Take existing attrs, that we won't generate
      ['example', 'format', 'readOnly', 'title', 'description'].each do |property_key|
        property_value                 = openapi_contents.dig(*path_parts(SCHEMAS_PATH), klass_name, "properties", key, property_key)
        properties_value[property_key] = property_value if property_value
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
    # TODO(lsmola) remove?
    # parameters["QueryOffset"] = {
    #   "in"          => "query",
    #   "name"        => "offset",
    #   "description" => "The number of items to skip before starting to collect the result set.",
    #   "required"    => false,
    #   "schema"      => {
    #     "type"    => "integer",
    #     "minimum" => 0,
    #     "default" => 0
    #   }
    # }
    #
    # parameters["QueryLimit"] = {
    #   "in"          => "query",
    #   "name"        => "limit",
    #   "description" => "The numbers of items to return per page.",
    #   "required"    => false,
    #   "schema"      => {
    #     "type"    => "integer",
    #     "minimum" => 1,
    #     "maximum" => 1000,
    #     "default" => 100
    #   }
    # }
    #
    # parameters["QueryFilter"] = {
    #   "in"          => "query",
    #   "name"        => "filter",
    #   "description" => "Filter for querying collections.",
    #   "required"    => false,
    #   "style"       => "deepObject",
    #   "explode"     => true,
    #   "schema"      => {
    #     "type" => "object"
    #   }
    # }
    #
    # schemas["CollectionLinks"] = {
    #   "type" => "object",
    #   "properties" => {
    #     "first" => {
    #       "type" => "string"
    #     },
    #     "last"  => {
    #       "type" => "string"
    #     },
    #     "prev"  => {
    #       "type" => "string"
    #     },
    #     "next"  => {
    #       "type" => "string"
    #     }
    #   }
    # }
    #
    # schemas["CollectionMetadata"] = {
    #   "type" => "object",
    #   "properties" => {
    #     "count" => {
    #       "type" => "integer"
    #     }
    #   }
    # }
    #
    # schemas["OrderParameters"] = {
    #   "type" => "object",
    #   "properties" => {
    #     "service_parameters" => {
    #       "type" => "object",
    #       "description" => "JSON object with provisioning parameters"
    #     },
    #     "provider_control_parameters" => {
    #       "type" => "object",
    #       "description" => "The provider specific parameters needed to provision this service. This might include namespaces, special keys"
    #     }
    #   }
    # }
    #
    # schemas["Tagging"] = {
    #   "type"       => "object",
    #   "properties" => {
    #     "tag_id" => {"$ref" => "##{SCHEMAS_PATH}/ID"},
    #     "name"   => {"type" => "string", "readOnly" => true, "example" => "architecture"},
    #     "value"  => {"type" => "string", "readOnly" => true, "example" => "x86_64"}
    #   }
    # }
    #
    # schemas["ID"] = {
    #   "type"=>"string", "description"=>"ID of the resource", "pattern"=>"/^\\d+$/", "readOnly"=>true
    # }

    schemas["Inventory"] = {
      "type":       "object",
      "required":   [
                      "schema",
                      "source"
                    ],
      "properties": {
        "name":                    {
          "type": "string"
        },
        "schema":                  {
          "$ref": "#/components/schemas/Schema"
        },
        "source":                  {
          "$ref": "#/components/schemas/Source"
        },
        "refresh_state_uuid":      {
          "type":   "string",
          "format": "uuid"
        },
        "refresh_state_part_uuid": {
          "type":   "string",
          "format": "uuid"
        },
        "total_parts":             {
          "type": "integer"
        },
        "sweep_scope":             {
          "type": "object"
        },
        "collections":             {
          "type":  "array",
          "items": {
            "$ref": "#/components/schemas/InventoryCollection"
          }
        }
      },
      "example":    {
        "schema":                  {
          "name": "name"
        },
        "collections":             [
                                     {
                                       "data":              [
                                                              {
                                                              },
                                                              {
                                                              }
                                                            ],
                                       "name":              "name",
                                       "all_manager_uuids": [
                                                              "all_manager_uuids",
                                                              "all_manager_uuids"
                                                            ],
                                       "partial_data":      [
                                                              nil,
                                                              nil
                                                            ],
                                       "manager_uuids":     [
                                                              "manager_uuids",
                                                              "manager_uuids"
                                                            ]
                                     },
                                     {
                                       "data":              [
                                                              {
                                                              },
                                                              {
                                                              }
                                                            ],
                                       "name":              "name",
                                       "all_manager_uuids": [
                                                              "all_manager_uuids",
                                                              "all_manager_uuids"
                                                            ],
                                       "partial_data":      [
                                                              nil,
                                                              nil
                                                            ],
                                       "manager_uuids":     [
                                                              "manager_uuids",
                                                              "manager_uuids"
                                                            ]
                                     }
                                   ],
        "total_parts":             0,
        "name":                    "name",
        "refresh_state_uuid":      "046b6c7f-0b8a-43b9-b35d-6489e6daee91",
        "refresh_state_part_uuid": "046b6c7f-0b8a-43b9-b35d-6489e6daee91",
        "source":                  {
          "name": "Widget Adapter",
          "id":   "d290f1ee-6c54-4b01-90e6-d701748f0851"
        },
        "sweep_scope":             [
                                     "sweep_scope",
                                     "sweep_scope"
                                   ]
      }
    }

    schemas["InventoryCollection"] = {
      "type":       "object",
      "required":   [
                      "name"
                    ],
      "properties": {
        "name":              {
          "type": "string"
        },
        "manager_uuids":     {
          "type":  "array",
          "items": {
            "type": "string"
          }
        },
        "all_manager_uuids": {
          "type":  "array",
          "items": {
            "type": "string"
          }
        },
        "data":              {
          "type":  "array",
          "items": {
            "$ref": "#/components/schemas/InventoryObject"
          }
        },
        "partial_data":      {
          "type":  "array",
          "items": {
            "$ref": "#/components/schemas/InventoryObject"
          }
        }
      },
      "example":    {
        "data":              [
                               {
                               },
                               {
                               }
                             ],
        "name":              "name",
        "all_manager_uuids": [
                               "all_manager_uuids",
                               "all_manager_uuids"
                             ],
        "partial_data":      [
                               nil,
                               nil
                             ],
        "manager_uuids":     [
                               "manager_uuids",
                               "manager_uuids"
                             ]
      }
    }

    schemas["InventoryObject"] = {
      "type": "object"
    }

    schemas["InventoryObjectLazy"] = {
      "type":       "object",
      "required":   [
                      "inventory_collection_name"
                    ],
      "properties": {
        "inventory_collection_name":   {
          "type": "string"
        },
        "reference":                   {
          "type":       "object",
          "properties": {
          }
        },
        "ref":                         {
          "type": "string"
        },
        "key":                         {
          "type": "string"
        },
        "default":                     {
          "type":       "object",
          "properties": {
          }
        },
        "transform_nested_lazy_finds": {
          "type": "boolean"
        }
      }
    }

    inventory_collections.each do |_key, inventory_collection|
      build_references_schema(inventory_collection)
    end

    (connection.tables - INTERNAL_TABLES).each do |table_name|
      build_schema(table_name.singularize.camelize)
    end

    new_content               = openapi_contents
    new_content["paths"]      = openapi_contents.dig("paths") #build_paths.sort.to_h
    new_content["components"] ||= {}
    # new_content["components"]["schemas"]    = schemas.sort.each_with_object({})    { |(name, val), h| h[name] = val || openapi_contents["components"]["schemas"][name]    || {} }
    new_content["components"]["schemas"] = schemas.sort.each_with_object({}) { |(name, val), h| h[name] = val || openapi_contents["components"]["schemas"][name] || {} }
    # new_content["components"]["schemas"]    = openapi_contents.dig("components", "schemas")
    new_content["components"]["parameters"] = parameters.sort.each_with_object({}) { |(name, val), h| h[name] = val || openapi_contents["components"]["parameters"][name] || {} }
    File.write(openapi_file, JSON.pretty_generate(new_content) + "\n")
  end

  INTERNAL_TABLES = [
    "tenants", "source_types", "schema_migrations", "ar_internal_metadata", "availabilities",
    "application_types", "authentications", "refresh_states", "refresh_state_parts", "endpoints", "sources", "tasks",
    "applications"
  ]

  GENERATOR_BLACKLIST_ATTRIBUTES         = [
    :id, :resource_timestamps, :resource_timestamps_max, :tenant_id, :source_id, :created_at, :updated_at, :last_seen_at
  ].to_set.freeze
  GENERATOR_ALLOW_BLACKLISTED_ATTRIBUTES = {
    :tenant_id => ['Source', 'Endpoint', 'Authentication', 'Application'].to_set.freeze
  }
end

GENERATOR_ALLOWED_MODELS               = [
  'Container', 'ContainerGroup', 'ContainerImage', 'ContainerNode', 'ContainerProject', 'ContainerTemplate', 'Flavor',
  'OrchestrationStack', 'ServiceInstance', 'ServiceOffering', 'ServiceOfferingIcon', 'ServicePlan', 'Tag',
  'Vm', 'Volume', 'VolumeAttachment', 'VolumeType', 'ContainerResourceQuota'
].to_set.freeze
GENERATOR_READ_ONLY_ATTRIBUTES         = [
  :created_at, :updated_at, :archived_at, :last_seen_at
].to_set.freeze
GENERATOR_IMAGE_MEDIA_TYPE_DEFINITIONS = [
  'IconData'
].to_set.freeze


$LOAD_PATH << File.expand_path("../lib", __dir__)
require "bundler/setup"
require "topological_inventory/schema/default"
require "topological_inventory/core/ar_helper"

queue_host = ENV["QUEUE_HOST"] || "localhost"
queue_port = ENV["QUEUE_PORT"] || 9092

TopologicalInventory::Core::ArHelper.database_yaml_path = Pathname.new(__dir__).join("../../config/database.yml")
TopologicalInventory::Core::ArHelper.load_environment!

namespace :openapi do
  desc "Generate the openapi.json contents"
  task :generate do
    OpenapiGenerator.new.run
  end
end
