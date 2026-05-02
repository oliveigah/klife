defmodule Example.Consumers.SimplestConsumerGroup do
  use Klife.Consumer.ConsumerGroup,
    client: Example.MySimplestClient,
    group_name: "simplest_cg_example",
    topics: [
      [name: "my_consumer_topic"],
      [name: "my_consumer_topic_2"]
    ]

  @impl true
  def handle_record_batch(_topic, _partition, _cg_name, record_list) do
    Enum.map(record_list, fn %Klife.Record{} = rec ->
      IO.inspect("Consuming record with offset #{rec.offset} and value #{rec.value}!")
      {:commit, rec}
    end)
  end
end
