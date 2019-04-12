require "topological_inventory/persister/logging"

module TopologicalInventory
  module Persister
    class Workflow
      include Logging

      def initialize(schema_class, source, messaging_client, payload)
        @persister        = schema_class.from_hash(payload, source)
        @schema_class     = schema_class
        @source           = source
        @messaging_client = messaging_client
        # TODO(lsmola) we should be able to reconstruct the payload out of persistor? E.g. to just repeat the sweep phase
        @payload = payload
      end

      def execute!
        if total_parts
          sweep_inactive_records!
        else
          persist_collections!
        end
      end

      private

      attr_reader :persister, :messaging_client, :payload, :schema_class, :source
      delegate :inventory_collections,
               :manager,
               :persist!,
               :refresh_state_uuid,
               :refresh_state_part_uuid,
               :total_parts,
               :sweep_scope,
               :to => :persister

      def define_refresh_state_ics
        refresh_states_inventory_collection = ::InventoryRefresh::InventoryCollection.new(
          :manager_ref                 => [:uuid],
          :parent                      => manager,
          :association                 => :refresh_states,
          :create_only                 => true,
          :model_class                 => RefreshState,
          :inventory_object_attributes => %i(ems_id uuid status source_id tenant_id),
          :default_values              => {
            :source_id => manager.id,
            :tenant_id => manager.tenant_id,
          }
        )

        refresh_state_parts_inventory_collection = ::InventoryRefresh::InventoryCollection.new(
          :manager_ref                 => %i(refresh_state uuid),
          :parent                      => manager,
          :association                 => :refresh_state_parts,
          :create_only                 => true,
          :model_class                 => RefreshStatePart,
          :inventory_object_attributes => %i(refresh_state uuid status error_message),
          :default_values              => {
            :tenant_id => manager.tenant_id,
          }
        )

        return refresh_states_inventory_collection, refresh_state_parts_inventory_collection
      end

      def upsert_refresh_state_records(status: nil, refresh_state_status: nil, error_message: nil)
        refresh_states_inventory_collection, refresh_state_parts_inventory_collection = define_refresh_state_ics

        return unless refresh_state_uuid

        build_refresh_state(refresh_states_inventory_collection, refresh_state_status)
        build_refresh_state_part(refresh_states_inventory_collection, refresh_state_parts_inventory_collection,
                                 status, error_message)

        InventoryRefresh::SaveInventory.save_inventory(
          manager, [refresh_states_inventory_collection, refresh_state_parts_inventory_collection]
        )
      end

      def build_refresh_state(refresh_states_inventory_collection, refresh_state_status)
        return unless refresh_state_status

        refresh_states_inventory_collection.build(
          :uuid   => refresh_state_uuid,
          :status => refresh_state_status,
        )
      end

      def build_refresh_state_part(refresh_states_ic, refresh_state_parts_ic, status, error_message)
        return unless status

        refresh_state_part_data = {
          :uuid          => refresh_state_part_uuid,
          :refresh_state => refresh_states_ic.lazy_find(:uuid => refresh_state_uuid),
          :status        => status
        }
        refresh_state_part_data[:error_message] = error_message if error_message

        refresh_state_parts_ic.build(refresh_state_part_data)
      end

      # Persists InventoryCollection objects into the DB
      def persist_collections!
        upsert_refresh_state_records(:status => :started, :refresh_state_status => :started)

        persist!
        send_changes_to_queue!
        reconnect_unconnected_edges!(persister)

        upsert_refresh_state_records(:status => :finished)
      rescue StandardError => e
        upsert_refresh_state_records(:status => :error, :error_message => e.message.truncate(150))

        raise(e)
      end

      def send_changes_to_queue!
        message = {
          :external_tenant => manager.tenant.external_tenant,
          :source          => manager.uid
        }

        message[:payload] = persister.inventory_collections.select { |x| x.name }.index_by(&:name).transform_values! do |x|
          hash = {}
          hash[:created] = x.created_records unless x.created_records.empty?
          hash[:updated] = x.updated_records unless x.updated_records.empty?
          hash[:deleted] = x.deleted_records unless x.deleted_records.empty?
          hash.empty? ? nil : hash
        end.compact

        messaging_client.publish_message(
          :service => "platform.topological-inventory.persister-output-stream",
          :message => "event",
          :payload => message
        )
      end

      def update(record, data)
        # Using this instead of record.update or record.update_attributes, because the queries are firing several Exists
        # queries on Source, for some reason. We don't need to check for exists. If it doesn't exist the foreign
        # key constraint will be fired.
        record.class.where(:id => record.id).update_all(data)
      end

      def reconnect_unconnected_edges!(persister)
        new_persister = new_persister(persister, reconnect_unconnected_edges_retry_count_limit)
        unconnected_edges = false

        persister.inventory_collections.each do |inventory_collection|
          next if inventory_collection.unconnected_edges.blank?
          unconnected_edges = true

          inventory_collection.unconnected_edges.each do |unconnected_edge|
            data = unconnected_edge.inventory_object.uuid
            data[unconnected_edge.inventory_object_key] = unconnected_edge.inventory_object_lazy
            data[:resource_timestamp] = unconnected_edge.inventory_object.data[:resource_timestamp]
            data.symbolize_keys!

            new_persister.send(inventory_collection.name).build_partial(data)
          end
        end

        reconnect_unconnected_edges_loop!(new_persister) if unconnected_edges
      end

      def reconnect_unconnected_edges_loop!(new_persister)
        if new_persister.retry_count > new_persister.retry_max
          logger.warn("Re-queuing unconnected edges :retry_max reached.")
        else
          requeue_unconnected_edges(new_persister)
        end
      end

      # Sweeps inactive records based on :last_seen_at attribute
      def sweep_inactive_records!
        refresh_state = set_sweeping_started!

        sweep_scope_refresh_state = if sweep_scope.kind_of?(Array)
                                      sweep_scope
                                    elsif sweep_scope.kind_of?(Hash)
                                      sweep_scope.map {|k, v| [k, v.size]}
                                    end
        update(
          refresh_state,
          :status      => :waiting_for_refresh_state_parts,
          :total_parts => total_parts,
          :sweep_scope => sweep_scope_refresh_state
        )

        if total_parts == refresh_state.refresh_state_parts.count
          start_sweeping!(refresh_state)
        else
          wait_for_sweeping!(refresh_state)
        end
      rescue StandardError => e
        update(refresh_state, :status => :error, :error_message => "Error while sweeping: #{e.message.truncate(150)}")

        raise(e)
      end

      def set_sweeping_started!
        refresh_state = manager.refresh_states.find_by(:uuid => refresh_state_uuid)
        unless refresh_state
          upsert_refresh_state_records(:refresh_state_status => :started)

          refresh_state = manager.refresh_states.find_by!(:uuid => refresh_state_uuid)
        end

        refresh_state
      end

      def start_sweeping!(refresh_state)
        error_count = refresh_state.refresh_state_parts.where(:status => :error).count

        if error_count.positive?
          update(refresh_state, :status => :error, :error_message => "Error when saving one or more parts, sweeping can't be done.")
        else
          update(refresh_state, :status => :sweeping)
          InventoryRefresh::SaveInventory.sweep_inactive_records(manager, inventory_collections, sweep_scope, refresh_state)
          update(refresh_state, :status => :finished)
        end
      end

      def wait_for_sweeping!(refresh_state)
        sweep_retry_count = refresh_state.sweep_retry_count + 1

        if sweep_retry_count > sweep_retry_count_limit
          update(
            refresh_state,
            :status        => :error,
            :error_message => "Sweep retry count limit of #{sweep_retry_count_limit} was reached."
          )
        else
          update(refresh_state, :status => :waiting_for_refresh_state_parts, :sweep_retry_count => sweep_retry_count)
          requeue_sweeping!
        end
      end

      def requeue_unconnected_edges(persister)
        data = persister.to_hash
        logger.info("Re-queuing unconnected edges #{data}...")
        messaging_client.publish_message(
          :service => "platform.topological-inventory.persister",
          :message => "save_inventory",
          :payload => data,
        )
      end

      def requeue_sweeping!
        logger.info("Re-queuing sweeping job...")
        messaging_client.publish_message(
          :service => "platform.topological-inventory.persister",
          :message => "save_inventory",
          :payload => payload,
        )
      end

      def new_persister(old_persister, retry_max)
        new_persister = schema_class.new(source)
        new_persister.retry_max = retry_max if new_persister.retry_max.nil?
        new_persister.retry_count = old_persister.retry_count.nil? ? 1 : (old_persister.retry_count + 1)
        new_persister
      end

      def sweep_retry_count_limit
        100
      end

      def reconnect_unconnected_edges_retry_count_limit
        1
      end
    end
  end
end
