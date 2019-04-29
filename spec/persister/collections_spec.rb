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
    Source.find_or_create_by!(:tenant => tenant, :uid => "9a874712-9a55-49ab-a46a-c823acc35503")
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

      # There should be 1 publish call writing to persister-output-stream queue
      expect(client).to receive(:publish_message).exactly(1).times
    end

    it "refreshes service_instances" do
      refresh(client, ["collections", "service_instances.json"])

      expect(source.service_instances.count).to eq(3)

      service_instance = source.service_instances.find_by(:source_ref => "82e98be9-41bf-11e9-828d-0a580a8000cc")
      service_plan     = source.service_plans.find_by(:source_ref => "836cc3e0-fdee-11e8-860c-06945c5af756")
      service_offering = source.service_offerings.find_by(:source_ref => "836cc3e0-fdee-11e8-860c-06945c5af756")

      expect(service_instance).to(
        have_attributes(
          :tenant_id           => source.tenant_id,
          :source_id           => source.id,
          :source_ref          => "82e98be9-41bf-11e9-828d-0a580a8000cc",
          :name                => "amq62-basic-07f3e100-366a-41d5-afd8-7e3d7a90c5d4",
          :service_plan_id     => service_plan.id,
          :service_offering_id => service_offering.id,
          :external_url        => "https://test_openshift.com:8443/console/project/default/browse/service-instances/amq62-basic-07f3e100-366a-41d5-afd8-7e3d7a90c5d4?tab=details"
        )
      )
    end

    it "refreshes container_resource_quotas" do
      refresh(client, ["collections", "container_resource_quotas.json"])

      expect(source.container_resource_quotas.count).to eq(3)

      container_resource_quota = source.container_resource_quotas.find_by(:source_ref => "807d6b84-f691-11e7-9bd4-0a46c474dfe0")
      expect(container_resource_quota).to(
        have_attributes(
          :tenant_id            => source.tenant_id,
          :source_id            => source.id,
          :container_project_id => nil,
          :source_ref           => "807d6b84-f691-11e7-9bd4-0a46c474dfe0",
          :resource_version     => "150282475",
          :name                 => "compute-resources",
          :status               => {
            "hard" => {"limits.cpu" => "2", "limits.memory" => "1Gi"},
            "used" => {"limits.cpu" => "0", "limits.memory" => "0"}
          },
          :spec                 => {
            "hard"   => {"limits.cpu" => "2", "limits.memory" => "1Gi"},
            "scopes" => ["NotTerminating"]
          },
        )
      )
    end

    it "refreshes flavors" do
      refresh(client, ["collections", "flavors.json"])

      expect(source.flavors.count).to eq(164)

      flavor = source.flavors.find_by(:source_ref => "m1.small")
      expect(flavor).to(
        have_attributes(
          :tenant_id  => source.tenant_id,
          :source_id  => source.id,
          :source_ref => "m1.small",
          :name       => "m1.small"
        )
      )
    end

    it "refreshes source_regions" do
      refresh(client, ["collections", "source_regions.json"])

      expect(source.source_regions.count).to eq(15)

      source_region = source.source_regions.find_by(:source_ref => "us-east-1")
      expect(source_region).to(
        have_attributes(
          :tenant_id  => source.tenant_id,
          :source_id  => source.id,
          :source_ref => "us-east-1",
          :name       => "us-east-1",
          :endpoint   => "ec2.us-east-1.amazonaws.com"
        )
      )
    end

    it "refreshes vms" do
      refresh(client, ["collections", "vms.json"])

      expect(source.vms.count).to eq(6)

      vm = source.vms.find_by(:source_ref => "i-8b5739f2")
      expect(vm).to(
        have_attributes(
          :tenant_id   => source.tenant_id,
          :source_id   => source.id,
          :source_ref  => "i-8b5739f2",
          :uid_ems     => "i-8b5739f2",
          :name        => "EmsRefreshSpec-PoweredOn-VPC",
          :power_state => "on",
        )
      )

      expect(vm.flavor).to(
        have_attributes(
          :tenant_id  => source.tenant_id,
          :source_id  => source.id,
          :source_ref => "t1.micro",
          :name       => nil
        )
      )
    end

    it "refreshes volume_types" do
      refresh(client, ["collections", "volume_types.json"])

      expect(source.volume_types.count).to eq(5)

      volume_type = source.volume_types.find_by(:source_ref => "gp2")
      expect(volume_type).to(
        have_attributes(
          :tenant_id   => source.tenant_id,
          :source_id   => source.id,
          :source_ref  => "gp2",
          :name        => "gp2",
          :description => "General Purpose",
          :extra       => {
            "storageMedia"  => "SSD-backed",
            "volumeType"    => "General Purpose",
            "maxIopsvolume" => "10000",
            "maxVolumeSize" => "16 TiB"
          }
        )
      )
    end

    it "refreshes volumes" do
      refresh(client, ["collections", "volumes.json"])

      expect(source.volumes.count).to eq(10)

      volume = source.volumes.find_by(:source_ref => "vol-67606d2d")
      expect(volume).to(
        have_attributes(
          :tenant_id         => source.tenant_id,
          :source_id         => source.id,
          :source_ref        => "vol-67606d2d",
          :name              => "EmsRefreshSpec-PoweredOn-VPC-root",
          :state             => "in-use",
          :size              => 7516192768,
          :source_created_at => Time.parse("2013-09-23 20:11:57 UTC").utc,
        )
      )

      expect(volume.source_region).to(
        have_attributes(
          :tenant_id  => source.tenant_id,
          :source_id  => source.id,
          :source_ref => "us-east-1",
          :name       => nil,
          :endpoint   => nil
        )
      )

      expect(volume.volume_type).to(
        have_attributes(
          :tenant_id   => source.tenant_id,
          :source_id   => source.id,
          :source_ref  => "standard",
          :name        => nil,
          :description => nil
        )
      )

      expect(volume.volume_attachments.count).to eq(1)
      expect(volume.volume_attachments.first).to(
        have_attributes(
          :tenant_id => source.tenant_id,
          :device    => "/dev/sda1",
          :state     => "attached"
        )
      )

      expect(volume.vms.count).to eq(1)

      expect(volume.vms.first).to(
        have_attributes(
          :tenant_id   => source.tenant_id,
          :source_id   => source.id,
          :source_ref  => "i-8b5739f2",
          :uid_ems     => nil,
          :name        => nil,
          :power_state => nil,
        )
      )
    end
  end
end
