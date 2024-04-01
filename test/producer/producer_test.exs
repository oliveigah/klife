defmodule Klife.ProducerTest do
  use ExUnit.Case

  alias Klife.Producer
  alias Klife.Utils

  defp assert_offset(expected_record, cluster, topic, partition, offset) do
    stored_record = Utils.get_record_by_offset(cluster, topic, partition, offset)

    Enum.each(expected_record, fn {k, v} ->
      assert v == Map.get(stored_record, k)
    end)
  end

  test "produce message sync no batch" do
    record = %{
      value: :rand.bytes(1_000),
      key: :rand.bytes(1_000),
      headers: [%{key: :rand.bytes(1_000), value: :rand.bytes(1_000)}]
    }

    topic = "my_no_batch_topic"

    assert {:ok, offset} = Producer.produce_sync(record, topic, 1, :my_test_cluster_1)

    assert_offset(record, :my_test_cluster_1, topic, 1, offset)
    record_batch = Utils.get_record_batch_by_offset(:my_test_cluster_1, topic, 1, offset)
    assert length(record_batch) == 1
  end

  test "produce message sync using not default producer" do
    record = %{
      value: :rand.bytes(1_000),
      key: :rand.bytes(1_000),
      headers: [%{key: :rand.bytes(1_000), value: :rand.bytes(1_000)}]
    }

    topic = "my_no_batch_topic"

    assert {:ok, offset} =
             Producer.produce_sync(record, topic, 1, :my_test_cluster_1,
               producer: :benchmark_producer
             )

    assert_offset(record, :my_test_cluster_1, topic, 1, offset)
    record_batch = Utils.get_record_batch_by_offset(:my_test_cluster_1, topic, 1, offset)
    assert length(record_batch) == 1
  end

  test "produce message sync with batch" do
    topic = "my_batch_topic"

    rec_1 = %{
      value: :rand.bytes(1_000),
      key: :rand.bytes(1_000),
      headers: [%{key: :rand.bytes(1_000), value: :rand.bytes(1_000)}]
    }

    task_1 =
      Task.async(fn ->
        Producer.produce_sync(rec_1, topic, 1, :my_test_cluster_1)
      end)

    rec_2 = %{
      value: :rand.bytes(1_000),
      key: :rand.bytes(1_000),
      headers: [%{key: :rand.bytes(1_000), value: :rand.bytes(1_000)}]
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Producer.produce_sync(rec_2, topic, 1, :my_test_cluster_1)
      end)

    rec_3 = %{
      value: :rand.bytes(1_000),
      key: :rand.bytes(1_000),
      headers: [%{key: :rand.bytes(1_000), value: :rand.bytes(1_000)}]
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Producer.produce_sync(rec_3, topic, 1, :my_test_cluster_1)
      end)

    assert [{:ok, offset_1}, {:ok, offset_2}, {:ok, offset_3}] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset_2 - offset_1 == 1
    assert offset_3 - offset_2 == 1

    assert_offset(rec_1, :my_test_cluster_1, topic, 1, offset_1)
    assert_offset(rec_2, :my_test_cluster_1, topic, 1, offset_2)
    assert_offset(rec_3, :my_test_cluster_1, topic, 1, offset_3)

    batch_1 = Utils.get_record_batch_by_offset(:my_test_cluster_1, topic, 1, offset_1)
    batch_2 = Utils.get_record_batch_by_offset(:my_test_cluster_1, topic, 1, offset_2)
    batch_3 = Utils.get_record_batch_by_offset(:my_test_cluster_1, topic, 1, offset_3)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end
end
