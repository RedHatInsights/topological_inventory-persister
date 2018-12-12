require "topological_inventory/persister/worker"

require_relative "refresh_worker_helper"

describe TopologicalInventory::Persister::Worker do
  include TestInventory::RefreshWorkerHelper
  let(:tenant) { Tenant.find_or_create_by!(:name => "default") }
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

    it "refreshes flavors" do
      refresh(client, ["collections", "flavors.json"])

      expect(source.flavors.count).to eq(164)

      flavor = source.flavors.find_by(:source_ref => "m5d.12xlarge")
      expect(flavor).to(
        have_attributes(
          :tenant_id  => source.tenant_id,
          :source_id  => source.id,
          :source_ref => "m5d.12xlarge",
          :name       => "m5d.12xlarge",
          :disk_size  => 966367641600,
          :memory     => 206158430208,
          :disk_count => 2,
          :cpus       => 48,
          :extra      => {
            "prices"     =>
              {"OnDemand" =>
                 {"22PCVUMSTSHECWJD.JRTCKXETXF" =>
                    {"sku"             => "22PCVUMSTSHECWJD",
                     "effectiveDate"   => "2018-12-01T00:00:00Z",
                     "offerTermCode"   => "JRTCKXETXF",
                     "termAttributes"  => {},
                     "priceDimensions" =>
                       {"22PCVUMSTSHECWJD.JRTCKXETXF.6YS6EN2CT7" =>
                          {"unit"         => "Hrs",
                           "endRange"     => "Inf",
                           "rateCode"     => "22PCVUMSTSHECWJD.JRTCKXETXF.6YS6EN2CT7",
                           "appliesTo"    => [],
                           "beginRange"   => "0",
                           "description"  =>
                             "$2.712 per On Demand Linux m5d.12xlarge Instance Hour",
                           "pricePerUnit" => {"USD" => "2.7120000000"}}}}}},
            "attributes" =>
              {"ecu"                    => "173",
               "vcpu"                   => "48",
               "memory"                 => "192 GiB",
               "storage"                => "2 x 900 NVMe SSD",
               "clockSpeed"             => "2.5 GHz",
               "physicalProcessor"      => "Intel Xeon Platinum 8175",
               "processorFeatures"      => "Intel AVX, Intel AVX2, Intel AVX512, Intel Turbo",
               "networkPerformance"     => "10 Gigabit",
               "dedicatedEbsThroughput" => "6000 Mbps"}
          }
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
