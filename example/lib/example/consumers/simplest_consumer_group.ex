defmodule Example.Consumers.SimplestConsumerGroup do
  use Klife.Consumer.ConsumerGroup, client: Example.MySimplestClient

  def start_link(_opts) do
    Klife.Consumer.ConsumerGroup.start_link(__MODULE__,
      topics: [
        %{name: "my_topic_1"},
        %{name: "my_topic_2"}
      ],
      group_name: "share_group_example_1"
    )
  end

  def handle_batch("my_topic_1", list_of_records) do
  end

  def handle_batch(topic_name, list_of_records) do
  end
end
