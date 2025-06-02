defmodule Example.Consumers.SimplestConsumerGroup do
  use Klife.Consumer.ConsumerGroup,
    client: Example.MySimplestClient,
    group_name: "simplest_cg_example",
    topics: [
      [name: "my_consumer_topic"],
      [name: "my_consumer_topic_2"]
    ]

  alias Klife.Record

  @impl true
  def handle_record_batch(topic, partition, record_list) do
    %Record{offset: first_offset} = List.first(record_list)
    %Record{offset: last_offset} = List.last(record_list)

    IO.inspect(
      "Handling from offset #{first_offset} to offset #{last_offset} from topic #{topic} partition #{partition}"
    )

    {:commit, :all}
  end
end
