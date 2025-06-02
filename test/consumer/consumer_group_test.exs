defmodule Klife.Consumer.ConsumerGroupTest do
  use ExUnit.Case

  test "basic test" do
    defmodule MyConsumerGroup do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @impl true
      def handle_record_batch(_topic, _partition, _records) do
        {:commit, :all}
      end
    end

    consumer_opts = [
      topics: [
        [name: "benchmark_topic_0"],
        [name: "benchmark_topic_1"]
      ],
      group_name: "consumer_group_example_1"
    ]

    start_supervised!({MyConsumerGroup, consumer_opts})
  end
end
