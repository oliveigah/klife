defmodule Klife.ProducerTest do
  use ExUnit.Case

  alias Klife.Producer
  alias Klife.Producer.Controller, as: ProdController
  alias Klife.Utils
  alias Klife.TestUtils

  defp assert_offset(expected_record, cluster, topic, partition, offset) do
    stored_record = Utils.get_record_by_offset(cluster, topic, partition, offset)

    Enum.each(expected_record, fn {k, v} ->
      assert v == Map.get(stored_record, k)
    end)
  end

  defp wait_batch_cycle(cluster, topic) do
    rec = %{
      value: "wait_cycle",
      key: "wait_cycle",
      headers: []
    }

    {:ok, _} = Producer.produce(rec, topic, 1, cluster)
  end

  test "produce message sync no batch" do
    record = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    cluster = :my_test_cluster_1
    topic = "test_no_batch_topic"

    assert {:ok, offset} = Producer.produce(record, topic, 1, cluster)

    assert_offset(record, cluster, topic, 1, offset)
    record_batch = Utils.get_record_batch_by_offset(cluster, topic, 1, offset)
    assert length(record_batch) == 1
  end

  test "produce message sync using not default producer" do
    record = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    cluster = :my_test_cluster_1
    topic = "test_no_batch_topic"

    assert {:ok, offset} =
             Producer.produce(record, topic, 1, cluster, producer: :benchmark_producer)

    assert_offset(record, cluster, topic, 1, offset)
    record_batch = Utils.get_record_batch_by_offset(cluster, topic, 1, offset)
    assert length(record_batch) == 1
  end

  test "produce message sync with batch" do
    cluster = :my_test_cluster_1
    topic = "test_batch_topic"

    wait_batch_cycle(cluster, topic)

    rec_1 = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    task_1 =
      Task.async(fn ->
        Producer.produce(rec_1, topic, 1, cluster)
      end)

    rec_2 = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Producer.produce(rec_2, topic, 1, cluster)
      end)

    rec_3 = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Producer.produce(rec_3, topic, 1, cluster)
      end)

    assert [{:ok, offset_1}, {:ok, offset_2}, {:ok, offset_3}] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset_2 - offset_1 == 1
    assert offset_3 - offset_2 == 1

    assert_offset(rec_1, cluster, topic, 1, offset_1)
    assert_offset(rec_2, cluster, topic, 1, offset_2)
    assert_offset(rec_3, cluster, topic, 1, offset_3)

    batch_1 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_1)
    batch_2 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_2)
    batch_3 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_3)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end

  test "produce message sync with batch and compression" do
    cluster = :my_test_cluster_1
    topic = "test_compression_topic"

    wait_batch_cycle(cluster, topic)

    rec_1 = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    task_1 =
      Task.async(fn ->
        Producer.produce(rec_1, topic, 1, cluster)
      end)

    rec_2 = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Producer.produce(rec_2, topic, 1, cluster)
      end)

    rec_3 = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Producer.produce(rec_3, topic, 1, cluster)
      end)

    assert [{:ok, offset_1}, {:ok, offset_2}, {:ok, offset_3}] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset_2 - offset_1 == 1
    assert offset_3 - offset_2 == 1

    assert_offset(rec_1, cluster, topic, 1, offset_1)
    assert_offset(rec_2, cluster, topic, 1, offset_2)
    assert_offset(rec_3, cluster, topic, 1, offset_3)

    batch_1 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_1)
    batch_2 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_2)
    batch_3 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_3)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3

    assert [%{attributes: attr}] =
             Utils.get_partition_resp_records_by_offset(cluster, topic, 1, offset_1)

    assert :snappy = KlifeProtocol.RecordBatch.decode_attributes(attr).compression
  end

  test "is able to recover from cluster changes" do
    cluster = :my_test_cluster_1
    topic = "test_no_batch_topic"

    record = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    assert {:ok, offset} = Producer.produce(record, topic, 1, cluster)

    assert_offset(record, cluster, topic, 1, offset)

    %{broker_id: old_broker_id} = ProdController.get_topics_partitions_metadata(cluster, topic, 1)

    {:ok, service_name} = TestUtils.stop_broker(cluster, old_broker_id)

    %{broker_id: new_broker_id} = ProdController.get_topics_partitions_metadata(cluster, topic, 1)

    assert new_broker_id != old_broker_id

    record = %{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}]
    }

    assert {:ok, offset} = Producer.produce(record, topic, 1, cluster)

    assert_offset(record, cluster, topic, 1, offset)

    {:ok, _} = TestUtils.start_broker(service_name, cluster)
  end
end
