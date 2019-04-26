module TestInventory
  module RefreshWorkerHelper
    def refresh(client, path)
      inventory = JSON.parse(File.read(test_inventory_dir.join(*path)))
      message = ManageIQ::Messaging::ReceivedMessage.new(nil, nil, inventory, nil, client)

      allow(client).to receive(:subscribe_topic).and_yield(message)

      described_class.new.run
      source.reload
    end
  end
end
