require "topological_inventory/persister/logging"

module TopologicalInventory
  module Persister
    class Workflow
      include Logging

      def initialize(persister, messaging_client, payload)
        @persister        = persister
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

      attr_reader :persister, :messaging_client, :payload
      delegate :inventory_collections,
               :ingress_api_sent_at,
               :manager,
               :persist!,
               :persister_started_at, :persister_finished_at,
               :refresh_state_uuid,
               :refresh_state_started_at, :refresh_state_sent_at,
               :refresh_state_part_uuid,
               :refresh_state_part_collected_at, :refresh_state_part_sent_at,
               :refresh_time_tracking,
               :sweep_scope,
               :total_parts,
               :to => :persister

      def define_refresh_state_ics
        refresh_states_inventory_collection = ::InventoryRefresh::InventoryCollection.new(
          :manager_ref                 => [:uuid],
          :parent                      => manager,
          :association                 => :refresh_states,
          :create_only                 => true,
          :model_class                 => RefreshState,
          :inventory_object_attributes => %i(uuid status source_id tenant_id),
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
        link_data_to_refresh_state_part

        persist!
        send_changes_to_queue!
        send_task_updates_to_queue!

        persister.persister_finished_at = Time.now.utc.to_datetime.to_s
        log_refresh_time_tracking(:refresh_state_part)

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
          # service_instance_tasks' updated_records contain custom hashes
          # filled by custom_save_block (used by Workflow.send_task_updates_to_queue!)
          next if x.name == :service_instance_tasks

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

      def send_task_updates_to_queue!
        tasks_ic = persister.inventory_collections.detect { |x| x.name == :service_instance_tasks }
        return if tasks_ic.nil?

        tasks_ic.updated_records.to_a.each do |payload|
          forwardable_headers = payload.delete(:forwardable_headers)

          messaging_client.publish_topic(
            :service => "platform.topological-inventory.task-output-stream",
            :event   => "Task.update",
            :payload => payload,
            :headers => forwardable_headers
          )
        end
      end

      def update(record, data)
        # Using this instead of record.update or record.update_attributes, because the queries are firing several Exists
        # queries on Source, for some reason. We don't need to check for exists. If it doesn't exist the foreign
        # key constraint will be fired.
        record.class.where(:id => record.id).update_all(data)
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

          persister.persister_finished_at = Time.now.utc.to_datetime.to_s
          log_refresh_time_tracking(:refresh_state)
          update(refresh_state,
                 :status      => :finished,
                 :started_at  => refresh_state_started_at,
                 :finished_at => persister_finished_at)
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

      def requeue_sweeping!
        logger.info("Re-queuing sweeping job...")
        messaging_client.publish_message(
          :service => "platform.topological-inventory.persister",
          :message => "save_inventory",
          :payload => payload,
        )
      end

      def sweep_retry_count_limit
        100
      end

      def link_data_to_refresh_state_part
        refresh_state_part = ::RefreshStatePart.find_by(:uuid => refresh_state_part_uuid)
        if refresh_state_part.present?
          ics = inventory_collections.select { |ic| ic.data.present? }
          ics.each do |ic|
            ic.data.each do |inventory_object|
              inventory_object.data[:refresh_state_part_id] = refresh_state_part.id
            end
          end
        end
      end

      # @param type [Symbol] :refresh_state_part | :refresh_state
      def log_refresh_time_tracking(type)
        msg = "Refresh tracking: State: #{refresh_state_uuid} "
        msg += "| Part: #{refresh_state_part_uuid} " if type == :refresh_state_part

        data = if type == :refresh_state_part
                 %i[refresh_state_part_collected_at
                    refresh_state_part_sent_at
                    ingress_api_sent_at
                    persister_started_at
                    persister_finished_at
                   ]
               else
                 %i[refresh_state_started_at
                    refresh_state_sent_at
                    ingress_api_sent_at
                    persister_started_at
                    persister_finished_at
                   ]
               end
        msg += "[#{data.collect {|name| "#{name}: #{send(name)}"}.join(' | ')}]"
        logger.info(msg)
      end
    end
  end
end
