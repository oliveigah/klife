defmodule Example.Consumers.SimplestConsumerGroup do
  use Klife.Consumer.ConsumerGroup,
    client: Example.MySimplestClient,
    group_name: "simplest_cg_example",
    topics: [
      [name: "my_consumer_topic"],
      [name: "my_consumer_topic_2"]
    ]
end
