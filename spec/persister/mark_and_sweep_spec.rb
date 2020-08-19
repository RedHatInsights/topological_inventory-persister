require "topological_inventory/persister/worker"
require_relative "refresh_worker_helper"

describe TopologicalInventory::Persister::Worker do
  include TestInventory::RefreshWorkerHelper

  let(:tenant) { Tenant.find_or_create_by!(:name => "default", :external_tenant => "external_tenant_uuid") }
  let(:vm_uuid) { "6fd5b322-e333-4bb7-bf70-b74bdf13d4c6" }
  let!(:vm) { Vm.find_or_create_by!(:tenant => tenant, :source_ref => "vm-1", :uid_ems => vm_uuid, :source => source_aws) }
  let(:client) { double(:client) }
  let(:test_inventory_dir) { Pathname.new(__dir__).join("test_inventory") }
  let!(:source) do
    Source.find_or_create_by!(
      :tenant => tenant, :uid => "9a874712-9a55-49ab-a46a-c823acc35503",
    )
  end
  let(:source_aws) do
    Source.find_or_create_by!(
      :tenant => tenant, :uid => "189d944b-93c3-4aea-87f8-846a8e7573de"
    )
  end
  let(:refresh_state_uuid) { "3022848a-b70f-46a3-9c7a-ee7f8009e90a" }

  context "#run" do
    before do
      allow(ManageIQ::Messaging::Client).to receive(:open).and_return(client)
      allow(client).to receive(:close)
    end

    it "automatically fills :last_seen_at timestamp for refreshed entities and archives them in last step" do
      expect(client).not_to receive(:publish_message)

      time_now = Time.now.utc
      time_before = Time.now.utc - 20.seconds
      time_after  = Time.now.utc + 2.hours

      cg1 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "a40e2927-77b8-487e-92bb-63f32989b015")
      cg2 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "1", :last_seen_at => time_before)
      cg3 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "2", :last_seen_at => time_after)
      cg4 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "3")
      cg6 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "4")
      cn1 = ContainerNode.create!(:source => source, :tenant => tenant, :source_ref => "1")
      cn2 = ContainerNode.create!(:source => source, :tenant => tenant, :source_ref => "2")

      new_cg_source_ref = "b40e2927-77b8-487e-92bb-63f32989b015"

      # Refresh first part and mark :last_seen_at
      refresh(client, ["mark_and_sweep", "mark_part_1.json"])

      date_field = ContainerGroup.arel_table[:last_seen_at]
      expect(ContainerGroup.where(date_field.gt(time_now)).pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg3.source_ref])
      )
      expect(ContainerGroup.where(date_field.lt(time_now)).or(ContainerGroup.where(:last_seen_at => nil)).pluck(:source_ref)).to(
        match_array([cg2.source_ref, cg4.source_ref, cg6.source_ref])
      )

      # Refresh second part and mark :last_seen_at
      refresh(client, ["mark_and_sweep", "mark_part_2.json"])

      date_field = ContainerGroup.arel_table[:last_seen_at]
      expect(ContainerGroup.where(date_field.gt(time_now)).pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg3.source_ref, new_cg_source_ref])
      )
      expect(ContainerGroup.where(date_field.lt(time_now)).or(ContainerGroup.where(:last_seen_at => nil)).pluck(:source_ref)).to(
        match_array([cg2.source_ref, cg4.source_ref, cg6.source_ref])
      )

      # Send sweep all non marked entities
      refresh(client, ["mark_and_sweep", "sweep_all.json"])

      expect(ContainerGroup.active.pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg3.source_ref, new_cg_source_ref])
      )
      expect(ContainerGroup.archived.pluck(:source_ref)).to(
        match_array([cg2.source_ref, cg4.source_ref, cg6.source_ref])
      )

      expect(ContainerNode.active.pluck(:source_ref)).to(
        match_array([])
      )
      expect(ContainerNode.archived.pluck(:source_ref)).to(
        match_array([cn1.source_ref, cn2.source_ref])
      )
    end

    it "sweeps only inventory_collections listed in persister's :sweep_scope" do
      expect(client).not_to receive(:publish_message)

      time_now = Time.now.utc
      time_before = Time.now.utc - 20.seconds
      time_after  = Time.now.utc + 2.hours

      cg1 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "a40e2927-77b8-487e-92bb-63f32989b015")
      cg2 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "1", :last_seen_at => time_before)
      cg3 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "2", :last_seen_at => time_after)
      cg4 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "3")
      cg6 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "4")
      cn1 = ContainerNode.create!(:source => source, :tenant => tenant, :source_ref => "1")
      cn2 = ContainerNode.create!(:source => source, :tenant => tenant, :source_ref => "2")

      new_cg_source_ref = "b40e2927-77b8-487e-92bb-63f32989b015"

      # Refresh first part and mark :last_seen_at
      refresh(client, ["mark_and_sweep", "mark_part_1.json"])

      date_field = ContainerGroup.arel_table[:last_seen_at]
      expect(ContainerGroup.where(date_field.gt(time_now)).pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg3.source_ref])
      )
      expect(ContainerGroup.where(date_field.lt(time_now)).or(ContainerGroup.where(:last_seen_at => nil)).pluck(:source_ref)).to(
        match_array([cg2.source_ref, cg4.source_ref, cg6.source_ref])
      )

      # Refresh second part and mark :last_seen_at
      refresh(client, ["mark_and_sweep", "mark_part_2.json"])

      date_field = ContainerGroup.arel_table[:last_seen_at]
      expect(ContainerGroup.where(date_field.gt(time_now)).pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg3.source_ref, new_cg_source_ref])
      )
      expect(ContainerGroup.where(date_field.lt(time_now)).or(ContainerGroup.where(:last_seen_at => nil)).pluck(:source_ref)).to(
        match_array([cg2.source_ref, cg4.source_ref, cg6.source_ref])
      )

      # Send sweep all non marked :container_groups
      refresh(client, ["mark_and_sweep", "sweep_container_groups.json"])

      expect(ContainerGroup.active.pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg3.source_ref, new_cg_source_ref])
      )
      expect(ContainerGroup.archived.pluck(:source_ref)).to(
        match_array([cg2.source_ref, cg4.source_ref, cg6.source_ref])
      )

      expect(ContainerNode.active.pluck(:source_ref)).to(
        match_array([cn1.source_ref, cn2.source_ref])
      )
      expect(ContainerNode.archived.pluck(:source_ref)).to(
        match_array([])
      )

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
      expect(refresh_state.status).to eq("finished")
    end

    it "sweeps subcollections with full scope" do
      expect(client).not_to receive(:publish_message)

      time_now = Time.now.utc
      time_before = Time.now.utc - 20.seconds
      time_after  = Time.now.utc + 2.hours

      cg1 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "a40e2927-77b8-487e-92bb-63f32989b015")
      cg2 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "2", :last_seen_at => time_before)
      cg3 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "3", :last_seen_at => time_now)
      cg4 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "4")
      cg6 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "6", :last_seen_at => time_after)
      c1 = Container.create!(:tenant => tenant, :container_group => cg1, :name => "alertmanager")
      c2 = Container.create!(:tenant => tenant, :container_group => cg1, :name => "name_2")
      c3 = Container.create!(:tenant => tenant, :container_group => cg3, :name => "name_3")
      c4 = Container.create!(:tenant => tenant, :container_group => cg6, :name => "name_4", :last_seen_at => time_after)
      tag1 = Tag.create(:tenant => tenant, :namespace => "openshift", :name => "tag1", :value => "tag1_value")
      tag3 = Tag.create(:tenant => tenant, :namespace => "openshift", :name => "tag3", :value => "tag3_value")
      _ctag1 = ContainerGroupTag.create!(:container_group => cg1, :tag => tag1)
      _ctag2 = ContainerGroupTag.create!(:container_group => cg1, :tag => tag3)
      _ctag3 = ContainerGroupTag.create!(:container_group => cg3, :tag => tag3)
      _ctag4 = ContainerGroupTag.create!(:container_group => cg6, :tag => tag3, :last_seen_at => time_after)

      new_cg_source_ref  = "b40e2927-77b8-487e-92bb-63f32989b015"
      new_container_name = "config-reloader"
      new_tag_name = "tag2"

      # Refresh first and second part and mark :last_seen_at
      refresh(client, ["mark_and_sweep", "mark_part_1.json"])
      refresh(client, ["mark_and_sweep", "mark_part_2.json"])

      # Send sweep all non marked :container_groups
      refresh(client, ["mark_and_sweep", "sweep_container_groups.json"])

      new_cg        = ContainerGroup.find_by(:source_ref => new_cg_source_ref)
      new_tag       = Tag.find_by(:name => new_tag_name)

      expect(ContainerGroup.active.pluck(:source_ref)).to(
        match_array([cg1.source_ref, new_cg_source_ref, cg6.source_ref])
      )
      expect(ContainerGroup.archived.pluck(:source_ref)).to(
        match_array([cg2.source_ref, cg3.source_ref, cg4.source_ref])
      )

      expect(Container.active.pluck(:name)).to(
        match_array([c1.name, new_container_name, c4.name])
      )
      expect(Container.archived.pluck(:name)).to(
        match_array([c2.name, c3.name])
      )

      expect(ContainerGroupTag.includes(:container_group, :tag).map {|x| [x.container_group.source_ref, x.tag.name]}).to(
        match_array([[cg1.source_ref, tag1.name], [new_cg.source_ref, new_tag.name], [cg6.source_ref, tag3.name]])
      )

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
      expect(refresh_state.status).to eq("finished")
    end

    it "sweeps subcollections with targeted scope" do
      expect(client).not_to receive(:publish_message)

      time_now = Time.now.utc
      time_before = Time.now.utc - 20.seconds
      time_after  = Time.now.utc + 2.hours

      cg1 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "a40e2927-77b8-487e-92bb-63f32989b015")
      cg2 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "2", :last_seen_at => time_before)
      cg3 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "3", :last_seen_at => time_now)
      cg4 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "4")
      cg6 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "6", :last_seen_at => time_after)
      c1 = Container.create!(:tenant => tenant, :container_group => cg1, :name => "alertmanager")
      c2 = Container.create!(:tenant => tenant, :container_group => cg1, :name => "name_2")
      c3 = Container.create!(:tenant => tenant, :container_group => cg3, :name => "name_3")
      c4 = Container.create!(:tenant => tenant, :container_group => cg6, :name => "name_4", :last_seen_at => time_after)
      tag1 = Tag.create(:tenant => tenant, :name => "tag1", :value => "tag1_value")
      tag3 = Tag.create(:tenant => tenant, :name => "tag3", :value => "tag3_value")
      _ctag1 = ContainerGroupTag.create!(:container_group => cg1, :tag => tag1)
      _ctag2 = ContainerGroupTag.create!(:container_group => cg1, :tag => tag3)
      _ctag3 = ContainerGroupTag.create!(:container_group => cg3, :tag => tag3)
      _ctag4 = ContainerGroupTag.create!(:container_group => cg6, :tag => tag3, :last_seen_at => time_after)

      new_cg_source_ref  = "b40e2927-77b8-487e-92bb-63f32989b015"
      new_container_name = "config-reloader"
      new_tag_name = "tag2"

      # Refresh first and second part and mark :last_seen_at
      refresh(client, ["mark_and_sweep", "mark_part_1.json"])
      refresh(client, ["mark_and_sweep", "mark_part_2.json"])

      # Send sweep all non marked :container_groups
      refresh(client, ["mark_and_sweep", "sweep_targeted_container_groups.json"])

      new_cg        = ContainerGroup.find_by(:source_ref => new_cg_source_ref)
      new_tag       = Tag.find_by(:name => new_tag_name)

      expect(ContainerGroup.active.pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg3.source_ref, new_cg_source_ref, cg6.source_ref, cg2.source_ref, cg4.source_ref])
      )
      expect(ContainerGroup.archived.pluck(:source_ref)).to(
        match_array([])
      )

      expect(Container.active.pluck(:name)).to(
        match_array([c1.name, c3.name, new_container_name, c4.name])
      )
      expect(Container.archived.pluck(:name)).to(
        match_array([c2.name])
      )

      # _ctag2 should be deleted
      expect(ContainerGroupTag.includes(:container_group, :tag).map {|x| [x.container_group.source_ref, x.tag.name]}).to(
        match_array([[cg1.source_ref, tag1.name], [cg3.source_ref, tag3.name], [new_cg.source_ref, new_tag.name], [cg6.source_ref, tag3.name]])
      )

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
      expect(refresh_state.status).to eq("finished")
    end

    it "checks partial update failure will error out the whole refresh_state" do
      expect(client).not_to receive(:publish_message)

      allow(TopologicalInventory::Persister).to receive(:logger).and_return(::InventoryRefresh::NullLogger.new)

      cg1 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "a40e2927-77b8-487e-92bb-63f32989b015")
      cg2 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "1")

      refresh(client, ["mark_and_sweep", "mark_part_1.json"])

      expect(
        source.refresh_states.find_by(:uuid => refresh_state_uuid).refresh_state_parts.where(:status => :finished).count
      ).to(
        eq(1)
      )

      # Refresh second part and mark :last_seen_at
      # Make it fail on source.container_groups query
      allow_any_instance_of(Source).to receive(:container_groups).and_return(nil)
      refresh(client, ["mark_and_sweep", "mark_part_2.json"])

      expect(
        source.refresh_states.find_by(:uuid => refresh_state_uuid).refresh_state_parts.where(:status => :finished).count
      ).to(
        eq(1)
      )

      # Send persister with total_parts = XY, that will cause sweeping all tables having :last_seen_on column
      refresh(client, ["mark_and_sweep", "sweep_container_groups.json"])

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
      expect(refresh_state.status).to(eq("error"))
      expect(refresh_state.error_message).to(eq("Error when saving one or more parts, sweeping can't be done."))
      expect(refresh_state.refresh_state_parts.where(:status => :error).count).to(eq(1))
      expect(refresh_state.refresh_state_parts.where(:status => :error).first.error_message).to(include("undefined method `where' for nil:NilClass"))

      expect(ContainerGroup.active.pluck(:source_ref)).to(
        match_array([cg1.source_ref, cg2.source_ref])
      )
      expect(ContainerGroup.archived.pluck(:source_ref)).to(
        match_array([])
      )
    end

    context "with empty scope" do
      before :each do
        expect(client).not_to receive(:publish_message)
        allow(TopologicalInventory::Persister).to receive(:logger).and_return(::InventoryRefresh::NullLogger.new)

        refresh(client, ["mark_and_sweep", "mark_part_1.json"])
        refresh(client, ["mark_and_sweep", "mark_part_2.json"])
      end

      it "checks nil scope doesn't sweep anything" do
        refresh(client, ["mark_and_sweep", "empty_sweep_format/empty1.json"])

        expect(ContainerGroup.active.count).to eq(2)
        expect(Container.active.count).to eq(2)
        expect(ContainerGroupTag.count).to eq(2)
        expect(Tag.count).to eq(2)

        refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
        expect(refresh_state.status).to eq("finished")
      end

      it "checks empty array scope doesn't sweep anything" do
        refresh(client, ["mark_and_sweep", "empty_sweep_format/empty2.json"])

        expect(ContainerGroup.active.count).to eq(2)
        expect(Container.active.count).to eq(2)
        expect(ContainerGroupTag.count).to eq(2)
        expect(Tag.count).to eq(2)

        refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
        expect(refresh_state.status).to eq("finished")
      end

      it "checks empty hash scope doesn't sweep anything" do
        refresh(client, ["mark_and_sweep", "empty_sweep_format/empty3.json"])

        expect(ContainerGroup.active.count).to eq(2)
        expect(Container.active.count).to eq(2)
        expect(ContainerGroupTag.count).to eq(2)
        expect(Tag.count).to eq(2)

        refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
        expect(refresh_state.status).to eq("finished")
      end

      it "checks missing sweep scope doesn't change anything" do
        refresh(client, ["mark_and_sweep", "empty_sweep_format/empty4.json"])

        expect(ContainerGroup.active.count).to eq(2)
        expect(Container.active.count).to eq(2)
        expect(ContainerGroupTag.count).to eq(2)
        expect(Tag.count).to eq(2)

        refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
        expect(refresh_state.status).to eq("finished")
      end
    end

    context "checks sweep fails when sending bad sweep scope format" do
      it "checks bad array format" do
        pending("Persister deserialization is not part of the workflow, therefore it fails a level up")

        expect(client).not_to receive(:publish_message)
        allow(TopologicalInventory::Persister).to receive(:logger).and_return(::InventoryRefresh::NullLogger.new)

        refresh(client, ["mark_and_sweep", "mark_part_1.json"])
        refresh(client, ["mark_and_sweep", "mark_part_2.json"])

        # Send persister with total_parts = XY, that will cause sweeping all tables having :last_seen_on column
        refresh(client, ["mark_and_sweep", "bad_sweep_format/bad1.json"])

        refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
        expect(refresh_state.status).to(eq("error"))
        expect(refresh_state.error_message).to(include("Error while sweeping: Allowed format of sweep scope is Array<String> or Hash{String => Hash},"))
        expect(refresh_state.refresh_state_parts.where(:status => :error).count).to(eq(0))
      end

      it "checks bad hash format" do
        pending("Persister deserialization is not part of the workflow, therefore it fails a level up")

        expect(client).not_to receive(:publish_message)
        allow(TopologicalInventory::Persister).to receive(:logger).and_return(::InventoryRefresh::NullLogger.new)

        refresh(client, ["mark_and_sweep", "mark_part_1.json"])
        refresh(client, ["mark_and_sweep", "mark_part_2.json"])

        # Send persister with total_parts = XY, that will cause sweeping all tables having :last_seen_on column
        refresh(client, ["mark_and_sweep", "bad_sweep_format/bad2.json"])

        refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
        expect(refresh_state.status).to(eq("error"))
        expect(refresh_state.error_message).to(include("Error while sweeping: Allowed format of sweep scope is Array<String> or Hash{String => Hash},"))
        expect(refresh_state.refresh_state_parts.where(:status => :error).count).to(eq(0))
      end

      it "checks bad string format" do
        pending("Persister deserialization is not part of the workflow, therefore it fails a level up")

        expect(client).not_to receive(:publish_message)
        allow(TopologicalInventory::Persister).to receive(:logger).and_return(::InventoryRefresh::NullLogger.new)

        refresh(client, ["mark_and_sweep", "mark_part_1.json"])
        refresh(client, ["mark_and_sweep", "mark_part_2.json"])

        # Send persister with total_parts = XY, that will cause sweeping all tables having :last_seen_on column
        refresh(client, ["mark_and_sweep", "bad_sweep_format/bad3.json"])

        refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
        expect(refresh_state.status).to(eq("error"))
        expect(refresh_state.error_message).to(include("Error while sweeping: Allowed format of sweep scope is Array<String> or Hash{String => Hash},"))
        expect(refresh_state.refresh_state_parts.where(:status => :error).count).to(eq(0))
      end
    end

    it "checks sweep fails after hundred tries, waiting for all parts to be finished" do
      allow(TopologicalInventory::Persister).to receive(:logger).and_return(::InventoryRefresh::NullLogger.new)

      cg1 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "1")

      # Expect the workflow to re-queue the sweep 100 times before failing
      expect(client).to receive(:publish_message).exactly(100).times

      101.times do
        # Sweep
        refresh(client, ["mark_and_sweep", "sweep_container_groups.json"])
      end

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)

      expect(refresh_state.status).to eq("error")
      expect(refresh_state.error_message).to eq("Sweep retry count limit of 100 was reached.")

      # Sweeping doesn't happen if there is a failure
      expect(ContainerGroup.active.pluck(:source_ref)).to(
        match_array([cg1.source_ref])
      )
      expect(ContainerGroup.archived.pluck(:source_ref)).to(
        match_array([])
      )
    end

    it "checks sweeping fails gracefully" do
      allow(TopologicalInventory::Persister).to receive(:logger).and_return(::InventoryRefresh::NullLogger.new)
      allow_any_instance_of(RefreshState).to receive(:refresh_state_parts).and_return(nil)

      cg1 = ContainerGroup.create!(:source => source, :tenant => tenant, :source_ref => "1")

      # Sweep
      refresh(client, ["mark_and_sweep", "sweep_container_groups.json"])

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)

      expect(refresh_state.status).to eq("error")
      expect(refresh_state.error_message).to eq("Error while sweeping: undefined method `count' for nil:NilClass")

      # Sweeping doesn't happen if there is a failure
      expect(ContainerGroup.active.pluck(:source_ref)).to(
        match_array([cg1.source_ref])
      )
      expect(ContainerGroup.archived.pluck(:source_ref)).to(
        match_array([])
      )
    end

    it "checks sweeping doesn't fail when we remove the refresh state" do
      expect(client).to receive(:publish_message).exactly(1).times # requeue sweeping

      # Refresh first and second part and mark :last_seen_at
      refresh(client, ["mark_and_sweep", "mark_part_1.json"])
      refresh(client, ["mark_and_sweep", "mark_part_2.json"])

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
      # Remove the refresh state
      refresh_state.destroy!

      # Send sweep all non marked :container_groups
      refresh(client, ["mark_and_sweep", "sweep_targeted_container_groups.json"])

      refresh_state = source.refresh_states.find_by(:uuid => refresh_state_uuid)
      # The refresh state will be upserted again and it will timeout on max sweep tries
      expect(refresh_state.status).to eq("waiting_for_refresh_state_parts")
    end
  end
end
