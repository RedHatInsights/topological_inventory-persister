require "topological_inventory/persister/worker"

describe TopologicalInventory::Persister::Worker do
  let(:tenant) { Tenant.find_or_create_by!(:name => "default", :external_tenant => "external_tenant_uuid") }
  let(:vm_uuid) { "6fd5b322-e333-4bb7-bf70-b74bdf13d4c6" }
  let!(:vm) { Vm.find_or_create_by!(:tenant => tenant, :source_ref => "vm-1", :uid_ems => vm_uuid, :source => source_aws) }
  let(:ocp_source_type) { SourceType.find_or_create_by(:name => "openshift", :product_name => "OpenShift", :vendor => "Red Hat") }
  let(:aws_source_type) { SourceType.find_or_create_by(:name => "amazon", :product_name => "Amazon Web Services", :vendor => "Amazon") }
  let(:client) { double(:client) }
  let(:test_inventory_dir) { Pathname.new(__dir__).join("test_inventory") }
  let!(:source) do
    Source.find_or_create_by!(
      :tenant      => tenant,
      :source_type => ocp_source_type,
      :name        => "OCP",
      :uid         => "9a874712-9a55-49ab-a46a-c823acc35503",
    )
  end
  let(:source_aws) do
    Source.find_or_create_by!(
      :tenant => tenant, :source_type => aws_source_type, :name => "AWS", :uid => "189d944b-93c3-4aea-87f8-846a8e7573de"
    )
  end
  let(:refresh_state_uuid) { "3022848a-b70f-46a3-9c7a-ee7f8009e90a" }

  context "#run" do
    before do
      allow(ManageIQ::Messaging::Client).to receive(:open).and_return(client)
      allow(client).to receive(:close)
    end

    it "re-queues the missing edges as partial updates" do
      requeue_value = nil
      allow(client).to receive(:publish_message) do |arg|
        if arg[:service] == "platform.topological-inventory.persister"
          requeue_value = arg
        end
      end

      # Refresh data with links to container_projects missing
      refresh(client, :path => ["reconnect_unconnected_edges", "container_groups_without_projects.json"])

      cp_ref1 = "a56c6854-baaf-11e8-ba7e-d094660d31fb"
      cp_ref2 = "b56c6854-baaf-11e8-ba7e-d094660d31fb"
      cp_ref3 = "c56c6854-baaf-11e8-ba7e-d094660d31fb"
      cg_ref1 =  "a40e2927-77b8-487e-92bb-63f32989b015"
      cg_ref2 =  "b40e2927-77b8-487e-92bb-63f32989b015"
      cg_ref3 =  "c40e2927-77b8-487e-92bb-63f32989b015"

      cg1 = ContainerGroup.find_by(:source_ref => cg_ref1)
      cg2 = ContainerGroup.find_by(:source_ref => cg_ref2)
      cg3 = ContainerGroup.find_by(:source_ref => cg_ref3)
      expect(cg1.container_project.source_ref).to eq cp_ref1
      expect(cg2.container_project).to be_nil
      expect(cg3.container_project).to be_nil
      expect(ContainerProject.count).to eq(1)

      # Refresh the missing projects
      refresh(client, :path => ["reconnect_unconnected_edges", "isolated_projects.json"])

      expect(cg1.reload.container_project.source_ref).to eq cp_ref1
      expect(cg2.reload.container_project).to be_nil
      expect(cg3.reload.container_project).to be_nil
      expect(ContainerProject.count).to eq(3)

      # Now refresh the re-queued unconnecded edges and observe they will connect
      refresh(client, :data => requeue_value)

      expect(cg1.reload.container_project.source_ref).to eq cp_ref1
      expect(cg2.reload.container_project.source_ref).to eq cp_ref2
      expect(cg3.reload.container_project.source_ref).to eq cp_ref3
      expect(ContainerProject.count).to eq(3)
    end

    it "checks that re-queuing will stop after :max_retry limit is reached" do
      # Refresh and observe that unconnected values are requeued
      requeue_value = nil
      allow(client).to receive(:publish_message) do |arg|
        if arg[:service] == "platform.topological-inventory.persister"
          requeue_value = arg
        end
      end

      refresh(client, :path => ["reconnect_unconnected_edges", "container_groups_without_projects.json"])
      expect(requeue_value).not_to be_nil

      # Now refresh reconnected values and observe retry limit is reached and we don't requeue the job again
      new_requeue_value = nil
      allow(client).to receive(:publish_message) do |arg|
        if arg[:service] == "platform.topological-inventory.persister"
          new_requeue_value = arg
        end
      end

      expect(TopologicalInventory::Persister.logger).to receive(:warn) do |arg|
        expect(arg).to match(/Re-queuing unconnected edges :retry_max reached/)
      end
      refresh(client, :data => requeue_value)
      expect(new_requeue_value).to be_nil
    end
  end

  def refresh(client, path: nil, data: nil)
    inventory = if path
                  JSON.parse(File.read(test_inventory_dir.join(*path)))
                elsif data
                  JSON.parse(data[:payload].to_json)
                end

    messages = [ManageIQ::Messaging::ReceivedMessage.new(nil, nil, inventory, nil, client)]

    allow(client).to receive(:subscribe_messages).and_yield(messages)

    described_class.new.run
    source.reload
  end
end
