defmodule Klife.ProducerTest do
  use ExUnit.Case

  alias Klife.Producer

  test "produce message sync no batch" do
    record = %{
      value: "abc",
      key: "some_key",
      headers: [%{key: "header_1", value: "header_val_1"}]
    }

    topic = "my_no_batch_topic"

    assert {:ok, offset} = Producer.produce_sync(record, topic, 1, :my_test_cluster_1)

    assert is_number(offset)
  end

  test "produce message sync using not default producer" do
    record = %{
      value: "abc",
      key: "some_key",
      headers: [%{key: "header_1", value: "header_val_1"}]
    }

    topic = "my_no_batch_topic"

    assert {:ok, offset} =
             Producer.produce_sync(record, topic, 1, :my_test_cluster_1,
               producer: :benchmark_producer
             )

    assert is_number(offset)
  end

  test "produce message sync with batch" do
    topic = "my_batch_topic"

    rec_1 = %{
      value: "some_val_1",
      key: "some_key_1",
      headers: [%{key: "header_1", value: "header_val_1"}]
    }

    task_1 =
      Task.async(fn ->
        Producer.produce_sync(rec_1, topic, 1, :my_test_cluster_1)
      end)

    rec_2 = %{
      value: "some_val_2",
      key: "some_key_2",
      headers: [%{key: "header_2", value: "header_val_2"}]
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Producer.produce_sync(rec_2, topic, 1, :my_test_cluster_1)
      end)

    rec_3 = %{
      value: "some_val_3",
      key: "some_key_3",
      headers: [%{key: "header_3", value: "header_val_3"}]
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Producer.produce_sync(rec_3, topic, 1, :my_test_cluster_1)
      end)

    assert [{:ok, offset_1}, {:ok, offset_2}, {:ok, offset_3}] =
             Task.await_many([task_1, task_2, task_3], 1_000)

    assert offset_2 - offset_1 == 1
    assert offset_3 - offset_2 == 1
  end
end
