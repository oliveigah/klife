defmodule MyConsumerGroup do
  use Klife.Consumer.ConsumerGroup,
    client: MyClient,
    group_name: "consumer_group_test_1",
    topics: [
      [name: "my_consumer_topic"],
      [name: "my_consumer_topic_2"]
    ]

  require Logger

  alias Klife.Record

  @impl true
  def handle_record_batch(topic, partition, _cg_name, record_lists) do
    %Record{offset: first_offset} = List.first(record_lists)
    %Record{offset: last_offset} = List.last(record_lists)

    IO.inspect(
      "Handling from offset #{first_offset} to offset #{last_offset} from topic #{topic} partition #{partition}"
    )

    :commit
  end

  @impl true
  def handle_consumer_start(topic, partition, group_name) do
    Logger.info(
      event: "consumer_start",
      topic: topic,
      partition: partition,
      group: group_name,
      mod: __MODULE__
    )

    :ok
  end

  @impl true
  def handle_consumer_stop(topic, partition, group_name, reason) do
    Logger.info(
      event: "consumer_stop",
      topic: topic,
      partition: partition,
      group: group_name,
      mod: __MODULE__,
      reason: reason
    )
  end
end
