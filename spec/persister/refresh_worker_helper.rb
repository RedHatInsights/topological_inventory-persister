module TestInventory
  module RefreshWorkerHelper
    def refresh(client, path)
      inventory = JSON.parse(File.read(test_inventory_dir.join(*path)))
      messages = [ManageIQ::Messaging::ReceivedMessage.new(nil, nil, inventory, nil)]

      allow(client).to receive(:subscribe_messages).and_yield(messages)

      described_class.new.run
      source.reload
    end
  end
end
