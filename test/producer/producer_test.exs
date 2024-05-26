defmodule Klife.ProducerTest do
  use ExUnit.Case

  alias Klife.Record

  alias Klife.Producer
  alias Klife.Producer.Controller, as: ProdController
  alias Klife.Utils
  alias Klife.TestUtils

  defp assert_offset(expected_record, cluster, offset) do
    stored_record =
      Utils.get_record_by_offset(
        cluster,
        expected_record.topic,
        expected_record.partition,
        offset
      )

    Enum.each(Map.from_struct(expected_record), fn {k, v} ->
      if k in [:value, :key, :headers] do
        assert v == Map.get(stored_record, k)
      end
    end)
  end

  defp wait_batch_cycle(cluster, topic, partition) do
    rec = %Record{
      value: "wait_cycle",
      key: "wait_cycle",
      headers: [],
      topic: topic,
      partition: partition
    }

    {:ok, _} = Producer.produce(rec, cluster)
  end

  test "produce message sync no batching" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    cluster = :my_test_cluster_1

    assert {:ok, offset} = Producer.produce(record, cluster)

    assert_offset(record, cluster, offset)
    record_batch = Utils.get_record_batch_by_offset(cluster, record.topic, 1, offset)
    assert length(record_batch) == 1
  end

  test "produce message sync using non default producer" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    cluster = :my_test_cluster_1

    assert {:ok, offset} =
             Producer.produce(record, cluster, producer: :benchmark_producer)

    assert_offset(record, cluster, offset)

    record_batch =
      Utils.get_record_batch_by_offset(cluster, record.topic, record.partition, offset)

    assert length(record_batch) == 1
  end

  test "produce message sync with batching" do
    cluster = :my_test_cluster_1
    topic = "test_batch_topic"

    wait_batch_cycle(cluster, topic, 1)

    rec_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    task_1 =
      Task.async(fn ->
        Producer.produce(rec_1, cluster)
      end)

    rec_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Producer.produce(rec_2, cluster)
      end)

    rec_3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Producer.produce(rec_3, cluster)
      end)

    assert [{:ok, offset_1}, {:ok, offset_2}, {:ok, offset_3}] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset_2 - offset_1 == 1
    assert offset_3 - offset_2 == 1

    assert_offset(rec_1, cluster, offset_1)
    assert_offset(rec_2, cluster, offset_2)
    assert_offset(rec_3, cluster, offset_3)

    batch_1 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_1)
    batch_2 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_2)
    batch_3 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset_3)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end

  test "produce message sync with batching and compression" do
    cluster = :my_test_cluster_1
    topic = "test_compression_topic"
    partition = 1

    wait_batch_cycle(cluster, topic, partition)

    rec_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    task_1 =
      Task.async(fn ->
        Producer.produce(rec_1, cluster)
      end)

    rec_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Producer.produce(rec_2, cluster)
      end)

    rec_3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Producer.produce(rec_3, cluster)
      end)

    assert [{:ok, offset_1}, {:ok, offset_2}, {:ok, offset_3}] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset_2 - offset_1 == 1
    assert offset_3 - offset_2 == 1

    assert_offset(rec_1, cluster, offset_1)
    assert_offset(rec_2, cluster, offset_2)
    assert_offset(rec_3, cluster, offset_3)

    batch_1 = Utils.get_record_batch_by_offset(cluster, topic, partition, offset_1)
    batch_2 = Utils.get_record_batch_by_offset(cluster, topic, partition, offset_2)
    batch_3 = Utils.get_record_batch_by_offset(cluster, topic, partition, offset_3)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3

    assert [%{attributes: attr}] =
             Utils.get_partition_resp_records_by_offset(cluster, topic, 1, offset_1)

    assert :snappy = KlifeProtocol.RecordBatch.decode_attributes(attr).compression
  end

  test "is able to recover from cluster changes" do
    cluster = :my_test_cluster_1
    topic = "test_no_batch_topic"

    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    assert {:ok, offset} = Producer.produce(record, cluster)

    assert_offset(record, cluster, offset)

    %{broker_id: old_broker_id} = ProdController.get_topics_partitions_metadata(cluster, topic, 1)

    {:ok, service_name} = TestUtils.stop_broker(cluster, old_broker_id)

    Process.sleep(10)

    %{broker_id: new_broker_id} = ProdController.get_topics_partitions_metadata(cluster, topic, 1)

    assert new_broker_id != old_broker_id

    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    assert {:ok, offset} = Producer.produce(record, cluster)

    assert_offset(record, cluster, offset)

    {:ok, _} = TestUtils.start_broker(service_name, cluster)
  end

  test "produce batch message sync no batching" do
    rec1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    rec2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    rec3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    cluster = :my_test_cluster_1

    assert [
             {:ok, offset1},
             {:ok, offset2},
             {:ok, offset3}
           ] = Producer.produce([rec1, rec2, rec3], cluster)

    assert_offset(rec1, cluster, offset1)
    assert_offset(rec2, cluster, offset2)
    assert_offset(rec3, cluster, offset3)

    record_batch = Utils.get_record_batch_by_offset(cluster, rec1.topic, 1, offset1)
    assert length(record_batch) == 3
  end

  test "produce batch message sync no batching - multi partition/topic" do
    rec1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    rec3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 2
    }

    rec4 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    rec5 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    cluster = :my_test_cluster_1

    assert [
             {:ok, offset1},
             {:ok, offset2},
             {:ok, offset3},
             {:ok, offset4},
             {:ok, offset5}
           ] = Producer.produce([rec1, rec2, rec3, rec4, rec5], cluster)

    assert_offset(rec1, cluster, offset1)
    assert_offset(rec2, cluster, offset2)
    assert_offset(rec3, cluster, offset3)
    assert_offset(rec4, cluster, offset4)
    assert_offset(rec5, cluster, offset5)

    record_batch = Utils.get_record_batch_by_offset(cluster, rec1.topic, rec1.partition, offset1)
    assert length(record_batch) == 1

    record_batch = Utils.get_record_batch_by_offset(cluster, rec2.topic, rec2.partition, offset2)
    assert length(record_batch) == 1

    record_batch = Utils.get_record_batch_by_offset(cluster, rec3.topic, rec3.partition, offset3)
    assert length(record_batch) == 1

    record_batch = Utils.get_record_batch_by_offset(cluster, rec4.topic, rec4.partition, offset4)
    assert length(record_batch) == 2
  end

  test "produce batch message sync with batching" do
    cluster = :my_test_cluster_1
    topic = "test_batch_topic"

    wait_batch_cycle(cluster, topic, 1)

    rec1_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    rec1_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 2
    }

    task_1 =
      Task.async(fn ->
        Producer.produce([rec1_1, rec1_2], cluster)
      end)

    rec2_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    rec2_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 2
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Producer.produce([rec2_1, rec2_2], cluster)
      end)

    rec3_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    rec3_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 2
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Producer.produce([rec3_1, rec3_2], cluster)
      end)

    assert [
             [{:ok, offset1_1}, {:ok, offset1_2}],
             [{:ok, offset2_1}, {:ok, offset2_2}],
             [{:ok, offset3_1}, {:ok, offset3_2}]
           ] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset2_1 - offset1_1 == 1
    assert offset3_1 - offset2_1 == 1

    assert offset2_2 - offset1_2 == 1
    assert offset3_2 - offset2_2 == 1

    assert_offset(rec1_1, cluster, offset1_1)
    assert_offset(rec1_2, cluster, offset1_2)
    assert_offset(rec2_1, cluster, offset2_1)
    assert_offset(rec2_2, cluster, offset2_2)
    assert_offset(rec3_1, cluster, offset3_1)
    assert_offset(rec3_2, cluster, offset3_2)

    batch_1 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset1_1)
    batch_2 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset2_1)
    batch_3 = Utils.get_record_batch_by_offset(cluster, topic, 1, offset3_1)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3

    batch_1 = Utils.get_record_batch_by_offset(cluster, topic, 2, offset1_2)
    batch_2 = Utils.get_record_batch_by_offset(cluster, topic, 2, offset2_2)
    batch_3 = Utils.get_record_batch_by_offset(cluster, topic, 2, offset3_2)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end
end
