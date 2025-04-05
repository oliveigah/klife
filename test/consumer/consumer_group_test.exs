defmodule Klife.Consumer.ConsumerGroupTest do
  use ExUnit.Case

  test "basic test" do
    defmodule MyConsumerGroup do
      use Klife.Consumer.ConsumerGroup, client: MyClient
    end

    consumer_opts = [
      topics: [
        [name: "benchmark_topic_0"],
        [name: "benchmark_topic_1"]
      ],
      group_name: "share_group_example_1"
    ]

    start_supervised!({MyConsumerGroup, consumer_opts})
  end
end
