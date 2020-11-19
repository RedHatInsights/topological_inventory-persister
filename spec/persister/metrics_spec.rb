require "topological_inventory/persister/metrics"
require "net/http"

describe TopologicalInventory::Persister::Metrics do
  subject! { described_class.new(9394) }
  after    { subject.stop_server }

  it "exposes metrics" do
    subject.record_process
    subject.record_process
    subject.record_process(:error)
    subject.record_process_timing { }

    metrics = get_metrics
    expect(metrics["topological_inventory_persister_messages_total{result=\"success\"}"]).to eq("2")
    expect(metrics["topological_inventory_persister_messages_total{result=\"error\"}"]).to eq("1")
    expect(metrics["topological_inventory_persister_message_process_seconds_bucket{le=\"+Inf\"}"]).to eq("1")
  end

  def get_metrics
    metrics = Net::HTTP.get(URI("http://localhost:9394/metrics")).split("\n").delete_if do |e|
      e.blank? || e.start_with?("#")
    end

    metrics.each_with_object({}) do |m, hash|
      k, v = m.split
      hash[k] = v
    end
  end
end
