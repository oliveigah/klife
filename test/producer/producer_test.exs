defmodule Klife.ProducerTest do
  use ExUnit.Case

  alias Klife.Producer

  test "produce message sync no batch" do
    record = %{value: "abc"}
    topic = "no_batch_topic"

    assert {:ok, res} = Producer.produce_sync(record, topic, 1, :my_test_cluster_1)

    assert %{content: %{responses: [topic_resp]}} = res
    assert %{name: ^topic, partition_responses: [partition_resp]} = topic_resp
    assert %{base_offset: offset, error_code: 0, index: 1} = partition_resp
    assert is_number(offset)
  end
end
