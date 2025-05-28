defmodule MyConsumerGroup do
  use Klife.Consumer.ConsumerGroup,
    client: MyClient,
    group_name: "consumer_group_test_1",
    topics: [
      [name: "my_consumer_topic"],
      [name: "my_consumer_topic_2", handler_strategy: {:batch, 10}]
    ]

  alias Klife.Record

  @impl true
  def handle_record(topic, partition, %Record{} = rec) do
    IO.inspect("Handling offset #{rec.offset} from topic #{topic} partition #{partition}")
    :ok
  end

  @impl true
  def handle_record_batch(topic, partition, record_lists) do
    %Record{offset: first_offset} = List.first(record_lists)
    %Record{offset: last_offset} = List.last(record_lists)

    IO.inspect(
      "Handling from offset #{first_offset} to offset #{last_offset} from topic #{topic} partition #{partition}"
    )

    :ok
  end
end
