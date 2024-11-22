defmodule Klife.ProducerTest do
  use ExUnit.Case

  import Klife.ProcessRegistry, only: [registry_lookup: 1]

  alias Klife.Record

  alias Klife.Producer.Controller, as: ProdController
  alias Klife.TestUtils

  doctest Klife.TxnProducerPool

  defp assert_resp_record(expected_record, response_record) do
    Enum.each(Map.from_struct(expected_record), fn {k, v} ->
      if v != nil do
        assert v == Map.get(response_record, k)
      end
    end)

    assert is_number(response_record.offset)
    assert is_number(response_record.partition)
  end

  defp wait_batch_cycle(client, topic, partition) do
    rec = %Record{
      value: "wait_cycle",
      key: "wait_cycle",
      headers: [],
      topic: topic,
      partition: partition
    }

    {:ok, _} = MyClient.produce(rec, client: client)
  end

  test "produce message sync no batching" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    assert {:ok, %Record{offset: offset} = resp_rec} = MyClient.produce(record)

    assert_resp_record(record, resp_rec)
    assert :ok = TestUtils.assert_offset(MyClient, record, offset)
    record_batch = TestUtils.get_record_batch_by_offset(MyClient, record.topic, 1, offset)
    assert length(record_batch) == 1
  end

  test "produce message sync no batching - unconfigured topic" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "non_configured_topic_1",
      partition: 1
    }

    assert {:ok, %Record{offset: offset} = resp_rec} = MyClient.produce(record)

    assert_resp_record(record, resp_rec)
    assert :ok = TestUtils.assert_offset(MyClient, record, offset)
    record_batch = TestUtils.get_record_batch_by_offset(MyClient, record.topic, 1, offset)
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

    assert {:ok, %Record{} = rec} = MyClient.produce(record, producer: :benchmark_producer)

    assert :ok = TestUtils.assert_offset(MyClient, record, rec.offset)

    record_batch =
      TestUtils.get_record_batch_by_offset(MyClient, record.topic, record.partition, rec.offset)

    assert length(record_batch) == 1
  end

  test "produce message sync with batching" do
    topic = "test_batch_topic"

    wait_batch_cycle(MyClient, topic, 1)

    rec_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    task_1 =
      Task.async(fn ->
        MyClient.produce(rec_1)
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
        MyClient.produce(rec_2)
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
        MyClient.produce(rec_3)
      end)

    assert [
             {:ok, %Record{} = resp_rec1},
             {:ok, %Record{} = resp_rec2},
             {:ok, %Record{} = resp_rec3}
           ] = Task.await_many([task_1, task_2, task_3], 2_000)

    assert resp_rec2.offset - resp_rec1.offset == 1
    assert resp_rec3.offset - resp_rec2.offset == 1

    assert :ok = TestUtils.assert_offset(MyClient, rec_1, resp_rec1.offset)
    assert :ok = TestUtils.assert_offset(MyClient, rec_2, resp_rec2.offset)
    assert :ok = TestUtils.assert_offset(MyClient, rec_3, resp_rec3.offset)

    batch_1 = TestUtils.get_record_batch_by_offset(MyClient, topic, 1, resp_rec1.offset)
    batch_2 = TestUtils.get_record_batch_by_offset(MyClient, topic, 1, resp_rec2.offset)
    batch_3 = TestUtils.get_record_batch_by_offset(MyClient, topic, 1, resp_rec3.offset)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end

  test "produce message sync with batching and compression" do
    topic = "test_compression_topic"
    partition = 1

    wait_batch_cycle(MyClient, topic, partition)

    rec_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    task_1 =
      Task.async(fn ->
        MyClient.produce(rec_1)
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
        MyClient.produce(rec_2)
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
        MyClient.produce(rec_3)
      end)

    assert [
             {:ok, %Record{} = resp_rec1},
             {:ok, %Record{} = resp_rec2},
             {:ok, %Record{} = resp_rec3}
           ] = Task.await_many([task_1, task_2, task_3], 2_000)

    assert resp_rec2.offset - resp_rec1.offset == 1
    assert resp_rec3.offset - resp_rec2.offset == 1

    assert :ok = TestUtils.assert_offset(MyClient, rec_1, resp_rec1.offset)
    assert :ok = TestUtils.assert_offset(MyClient, rec_2, resp_rec2.offset)
    assert :ok = TestUtils.assert_offset(MyClient, rec_3, resp_rec3.offset)

    batch_1 = TestUtils.get_record_batch_by_offset(MyClient, topic, partition, resp_rec1.offset)
    batch_2 = TestUtils.get_record_batch_by_offset(MyClient, topic, partition, resp_rec2.offset)
    batch_3 = TestUtils.get_record_batch_by_offset(MyClient, topic, partition, resp_rec3.offset)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3

    assert [%{attributes: attr}] =
             TestUtils.get_partition_resp_records_by_offset(MyClient, topic, 1, resp_rec1.offset)

    assert :snappy = KlifeProtocol.RecordBatch.decode_attributes(attr).compression
  end

  @tag cluster_change: true, capture_log: true, timeout: 90_000
  test "is able to recover from client changes" do
    topic = "test_no_batch_topic"

    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    assert {:ok, %Record{} = resp_rec} = MyClient.produce(record)

    assert :ok = TestUtils.assert_offset(MyClient, record, resp_rec.offset)

    %{broker_id: old_broker_id} =
      ProdController.get_topics_partitions_metadata(MyClient, topic, 1)

    {:ok, service_name} = TestUtils.stop_broker(MyClient, old_broker_id)

    Process.sleep(50)

    %{broker_id: new_broker_id} =
      ProdController.get_topics_partitions_metadata(MyClient, topic, 1)

    assert new_broker_id != old_broker_id

    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    assert {:ok, %Record{} = resp_rec} = MyClient.produce(record)

    assert :ok = TestUtils.assert_offset(MyClient, record, resp_rec.offset)

    {:ok, _} = TestUtils.start_broker(service_name, MyClient)
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

    assert [
             {:ok, %Record{offset: offset1}},
             {:ok, %Record{offset: offset2}},
             {:ok, %Record{offset: offset3}}
           ] = MyClient.produce_batch([rec1, rec2, rec3])

    assert :ok = TestUtils.assert_offset(MyClient, rec1, offset1)
    assert :ok = TestUtils.assert_offset(MyClient, rec2, offset2)
    assert :ok = TestUtils.assert_offset(MyClient, rec3, offset3)

    record_batch = TestUtils.get_record_batch_by_offset(MyClient, rec1.topic, 1, offset1)
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

    assert [
             {:ok, %Record{offset: offset1}},
             {:ok, %Record{offset: offset2}},
             {:ok, %Record{offset: offset3}},
             {:ok, %Record{offset: offset4}},
             {:ok, %Record{offset: offset5}}
           ] = MyClient.produce_batch([rec1, rec2, rec3, rec4, rec5])

    assert :ok = TestUtils.assert_offset(MyClient, rec1, offset1)
    assert :ok = TestUtils.assert_offset(MyClient, rec2, offset2)
    assert :ok = TestUtils.assert_offset(MyClient, rec3, offset3)
    assert :ok = TestUtils.assert_offset(MyClient, rec4, offset4)
    assert :ok = TestUtils.assert_offset(MyClient, rec5, offset5)

    record_batch =
      TestUtils.get_record_batch_by_offset(MyClient, rec1.topic, rec1.partition, offset1)

    assert length(record_batch) == 1

    record_batch =
      TestUtils.get_record_batch_by_offset(MyClient, rec2.topic, rec2.partition, offset2)

    assert length(record_batch) == 1

    record_batch =
      TestUtils.get_record_batch_by_offset(MyClient, rec3.topic, rec3.partition, offset3)

    assert length(record_batch) == 1

    record_batch =
      TestUtils.get_record_batch_by_offset(MyClient, rec4.topic, rec4.partition, offset4)

    assert length(record_batch) == 2
  end

  test "produce batch message sync with batching" do
    topic = "test_batch_topic"

    wait_batch_cycle(MyClient, topic, 1)

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
        MyClient.produce_batch([rec1_1, rec1_2])
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
        MyClient.produce_batch([rec2_1, rec2_2])
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
        MyClient.produce_batch([rec3_1, rec3_2])
      end)

    assert [
             [{:ok, %Record{offset: offset1_1}}, {:ok, %Record{offset: offset1_2}}],
             [{:ok, %Record{offset: offset2_1}}, {:ok, %Record{offset: offset2_2}}],
             [{:ok, %Record{offset: offset3_1}}, {:ok, %Record{offset: offset3_2}}]
           ] = Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset2_1 - offset1_1 == 1
    assert offset3_1 - offset2_1 == 1

    assert offset2_2 - offset1_2 == 1
    assert offset3_2 - offset2_2 == 1

    assert :ok = TestUtils.assert_offset(MyClient, rec1_1, offset1_1)
    assert :ok = TestUtils.assert_offset(MyClient, rec1_2, offset1_2)
    assert :ok = TestUtils.assert_offset(MyClient, rec2_1, offset2_1)
    assert :ok = TestUtils.assert_offset(MyClient, rec2_2, offset2_2)
    assert :ok = TestUtils.assert_offset(MyClient, rec3_1, offset3_1)
    assert :ok = TestUtils.assert_offset(MyClient, rec3_2, offset3_2)

    batch_1 = TestUtils.get_record_batch_by_offset(MyClient, topic, 1, offset1_1)
    batch_2 = TestUtils.get_record_batch_by_offset(MyClient, topic, 1, offset2_1)
    batch_3 = TestUtils.get_record_batch_by_offset(MyClient, topic, 1, offset3_1)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3

    batch_1 = TestUtils.get_record_batch_by_offset(MyClient, topic, 2, offset1_2)
    batch_2 = TestUtils.get_record_batch_by_offset(MyClient, topic, 2, offset2_2)
    batch_3 = TestUtils.get_record_batch_by_offset(MyClient, topic, 2, offset3_2)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end

  test "produce record using default partitioner" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic"
    }

    assert {:ok,
            %Record{
              offset: offset,
              partition: partition,
              topic: topic
            } = resp_rec} = MyClient.produce(record)

    assert_resp_record(record, resp_rec)
    assert :ok = TestUtils.assert_offset(MyClient, record, offset, partition: partition)

    record_batch = TestUtils.get_record_batch_by_offset(MyClient, topic, partition, offset)
    assert length(record_batch) == 1
  end

  test "produce record using custom partitioner on config" do
    record = %Record{
      value: :rand.bytes(10),
      key: "3",
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic_2"
    }

    assert {:ok,
            %Record{
              offset: offset,
              partition: 3,
              topic: topic
            } = resp_rec} = MyClient.produce(record)

    assert_resp_record(record, resp_rec)
    assert :ok = TestUtils.assert_offset(MyClient, record, offset, partition: 3)

    record_batch = TestUtils.get_record_batch_by_offset(MyClient, topic, 3, offset)
    assert length(record_batch) == 1
  end

  test "produce record using custom partitioner on opts" do
    record = %Record{
      value: :rand.bytes(10),
      key: "4",
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic"
    }

    assert {:ok,
            %Record{
              offset: offset,
              partition: 4,
              topic: topic
            } = resp_rec} = MyClient.produce(record, partitioner: Klife.TestCustomPartitioner)

    assert_resp_record(record, resp_rec)
    assert :ok = TestUtils.assert_offset(MyClient, record, offset, partition: 4)

    record_batch = TestUtils.get_record_batch_by_offset(MyClient, topic, 4, offset)
    assert length(record_batch) == 1
  end

  test "produce message batch async - anon fun" do
    key1 = :rand.bytes(10)

    rec1 = %Record{
      value: :rand.bytes(10),
      key: key1,
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_async_topic",
      partition: 1
    }

    key2 = :rand.bytes(10)

    rec2 = %Record{
      value: :rand.bytes(10),
      key: key2,
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    key3 = :rand.bytes(10)

    rec3 = %Record{
      value: :rand.bytes(10),
      key: key3,
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_async_topic",
      partition: 3
    }

    parent = self()

    assert :ok =
             MyClient.produce_batch_async([rec1, rec2, rec3],
               callback: fn resp -> send(parent, {:ping, resp}) end
             )

    assert_receive({:ping, [{:ok, new_rec1}, {:ok, new_rec2}, {:ok, new_rec3}]}, 1000)

    assert :ok = TestUtils.assert_offset(MyClient, rec1, new_rec1.offset)
    assert :ok = TestUtils.assert_offset(MyClient, rec2, new_rec2.offset)
    assert :ok = TestUtils.assert_offset(MyClient, rec3, new_rec3.offset)
  end

  test "produce message async no batching - anon fun" do
    rec = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_async_topic",
      partition: 1
    }

    parent = self()

    assert :ok = MyClient.produce_async(rec, callback: fn resp -> send(parent, {:ping, resp}) end)

    assert_receive({:ping, resp}, 1000)

    assert {:ok, new_rec} = resp

    assert :ok = TestUtils.assert_offset(MyClient, rec, new_rec.offset)
    record_batch = TestUtils.get_record_batch_by_offset(MyClient, rec.topic, 1, new_rec.offset)
    assert length(record_batch) == 1
  end

  test "produce message async no batching - mfa" do
    defmodule CB do
      def exec(resp, arg1, arg2) do
        send(arg1, {:ping, resp, arg2})
      end
    end

    rec = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_async_topic",
      partition: 1
    }

    parent = self()

    assert :ok = MyClient.produce_async(rec, callback: {CB, :exec, [parent, "arg2"]})

    assert_receive({:ping, resp, "arg2"}, 1000)

    assert {:ok, new_rec} = resp
    assert :ok = TestUtils.assert_offset(MyClient, rec, new_rec.offset)

    record_batch = TestUtils.get_record_batch_by_offset(MyClient, rec.topic, 1, new_rec.offset)

    assert length(record_batch) == 1
  end

  test "producer epoch bump" do
    client_name = MyClient

    %{
      "test_no_batch_topic" => [t1_data | _],
      "test_no_batch_topic_2" => [t2_data | _]
    } =
      ProdController.get_all_topics_partitions_metadata(client_name)
      |> Enum.filter(fn data ->
        data.topic_name in ["test_no_batch_topic", "test_no_batch_topic_2"]
      end)
      |> Enum.group_by(fn data -> {data.leader_id, data.batcher_id} end)
      |> Enum.take(1)
      |> List.first()
      |> elem(1)
      |> Enum.group_by(fn data -> data.topic_name end)

    rec1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: t1_data.topic_name,
      partition: t1_data.partition_idx
    }

    rec2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: t2_data.topic_name,
      partition: t2_data.partition_idx
    }

    default_producer_name = Klife.Client.default_producer_name()

    [{batcher_pid, _}] =
      registry_lookup(
        {Klife.Producer.Batcher, client_name, t1_data.leader_id, default_producer_name,
         t1_data.batcher_id}
      )

    [{producer_pid, _}] = registry_lookup({Klife.Producer, client_name, default_producer_name})

    assert [
             {:ok, %Record{}},
             {:ok, %Record{}}
           ] = MyClient.produce_batch([rec1, rec2])

    tp_key = {t1_data.topic_name, t1_data.partition_idx}

    before_epoch =
      batcher_pid
      |> :sys.get_state()
      |> Map.get(:producer_epochs)
      |> Map.fetch!(tp_key)

    producer_state = :sys.get_state(producer_pid)

    assert {^before_epoch, ^batcher_pid} =
             producer_state
             |> Map.get(:epochs)
             |> Map.get(tp_key)

    send(batcher_pid, {:bump_epoch, [tp_key]})

    :ok =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        state = :sys.get_state(batcher_pid)

        new_epoch =
          state
          |> Map.get(:producer_epochs)
          |> Map.get(tp_key)

        new_bs =
          state
          |> Map.get(:base_sequences)
          |> Map.get(tp_key)

        if new_epoch > before_epoch and new_bs == 0 do
          {:halt, :ok}
        else
          Process.sleep(1)
          {:cont, nil}
        end
      end)

    producer_state = :sys.get_state(producer_pid)

    expected_epoch = before_epoch + 1

    assert {^expected_epoch, ^batcher_pid} =
             producer_state
             |> Map.get(:epochs)
             |> Map.get(tp_key)

    assert [{:ok, %Record{}}] = MyClient.produce_batch([rec1])
    assert [{:ok, %Record{}}] = MyClient.produce_batch([rec2])
  end

  test "txn produce message - aborts" do
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
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    rec4 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec5 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec6 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    assert {:error,
            [
              {:ok, %Record{offset: offset1}},
              {:ok, %Record{offset: offset2}},
              {:ok, %Record{offset: offset3}},
              {:ok, %Record{offset: offset4}},
              {:ok, %Record{offset: offset5}},
              {:ok, %Record{offset: offset6}}
            ]} =
             MyClient.transaction(fn ->
               resp1 = MyClient.produce_batch([rec1, rec2, rec3])

               assert [
                        {:ok, %Record{offset: offset1}},
                        {:ok, %Record{offset: offset2}},
                        {:ok, %Record{offset: offset3}}
                      ] = resp1

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec1, offset1, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec1, offset1, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec2, offset2, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec2, offset2, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec3, offset3, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec3, offset3, isolation: :uncommitted)

               resp2 = MyClient.produce_batch([rec4, rec5, rec6])

               assert [
                        {:ok, %Record{offset: offset4}},
                        {:ok, %Record{offset: offset5}},
                        {:ok, %Record{offset: offset6}}
                      ] = resp2

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec4, offset4, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec4, offset4, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec5, offset5, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec5, offset5, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec6, offset6, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec6, offset6, isolation: :uncommitted)

               {:error, resp1 ++ resp2}
             end)

    TestUtils.assert_offset(MyClient, rec1, offset1, txn_status: :aborted, isolation: :committed)
    TestUtils.assert_offset(MyClient, rec2, offset2, txn_status: :aborted, isolation: :committed)
    TestUtils.assert_offset(MyClient, rec3, offset3, txn_status: :aborted, isolation: :committed)
    TestUtils.assert_offset(MyClient, rec4, offset4, txn_status: :aborted, isolation: :committed)
    TestUtils.assert_offset(MyClient, rec5, offset5, txn_status: :aborted, isolation: :committed)
    TestUtils.assert_offset(MyClient, rec6, offset6, txn_status: :aborted, isolation: :committed)
  end

  test "txn produce message - commits" do
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
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    rec4 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec5 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec6 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    assert {:ok,
            [
              {:ok, %Record{offset: offset1}},
              {:ok, %Record{offset: offset2}},
              {:ok, %Record{offset: offset3}},
              {:ok, %Record{offset: offset4}},
              {:ok, %Record{offset: offset5}},
              {:ok, %Record{offset: offset6}}
            ]} =
             MyClient.transaction(fn ->
               resp1 = MyClient.produce_batch([rec1, rec2, rec3])

               assert [
                        {:ok, %Record{offset: offset1}},
                        {:ok, %Record{offset: offset2}},
                        {:ok, %Record{offset: offset3}}
                      ] = resp1

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec1, offset1, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec1, offset1, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec2, offset2, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec2, offset2, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec3, offset3, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec3, offset3, isolation: :uncommitted)

               resp2 = MyClient.produce_batch([rec4, rec5, rec6])

               assert [
                        {:ok, %Record{offset: offset4}},
                        {:ok, %Record{offset: offset5}},
                        {:ok, %Record{offset: offset6}}
                      ] = resp2

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec4, offset4, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec4, offset4, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec5, offset5, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec5, offset5, isolation: :uncommitted)

               assert :not_found =
                        TestUtils.assert_offset(MyClient, rec6, offset6, isolation: :committed)

               assert :ok =
                        TestUtils.assert_offset(MyClient, rec6, offset6, isolation: :uncommitted)

               {:ok, resp1 ++ resp2}
             end)

    TestUtils.assert_offset(MyClient, rec1, offset1, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec2, offset2, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec3, offset3, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec4, offset4, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec5, offset5, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec6, offset6, txn_status: :committed)
  end

  @tag capture_log: true
  test "txn produce message - multiple transactions using the same worker" do
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
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    rec4 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec5 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec6 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    assert {:ok,
            [
              {:ok, %Record{offset: offset1}},
              {:ok, %Record{offset: offset2}}
            ]} =
             MyClient.transaction(
               fn ->
                 resp = MyClient.produce_batch([rec1, rec2])

                 assert [
                          {:ok, %Record{offset: offset1}},
                          {:ok, %Record{offset: offset2}}
                        ] = resp

                 assert :not_found =
                          TestUtils.assert_offset(MyClient, rec1, offset1, isolation: :committed)

                 assert :ok =
                          TestUtils.assert_offset(MyClient, rec1, offset1, isolation: :uncommitted)

                 assert :not_found =
                          TestUtils.assert_offset(MyClient, rec2, offset2, isolation: :committed)

                 assert :ok =
                          TestUtils.assert_offset(MyClient, rec2, offset2, isolation: :uncommitted)

                 {:ok, resp}
               end,
               pool_name: :my_test_pool_1
             )

    TestUtils.assert_offset(MyClient, rec1, offset1, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec2, offset2, txn_status: :committed)

    assert {:error, %RuntimeError{message: "crazy error"}} =
             MyClient.transaction(
               fn ->
                 resp = MyClient.produce_batch([rec3, rec4, rec5])

                 assert [
                          {:ok, %Record{offset: offset3}},
                          {:ok, %Record{offset: offset4}},
                          {:ok, %Record{offset: offset5}}
                        ] = resp

                 assert :not_found =
                          TestUtils.assert_offset(MyClient, rec3, offset3, isolation: :committed)

                 assert :ok =
                          TestUtils.assert_offset(MyClient, rec3, offset3, isolation: :uncommitted)

                 assert :not_found =
                          TestUtils.assert_offset(MyClient, rec4, offset4, isolation: :committed)

                 assert :ok =
                          TestUtils.assert_offset(MyClient, rec4, offset4, isolation: :uncommitted)

                 assert :not_found =
                          TestUtils.assert_offset(MyClient, rec5, offset5, isolation: :committed)

                 assert :ok =
                          TestUtils.assert_offset(MyClient, rec5, offset5, isolation: :uncommitted)

                 Process.put(:raised_offsets, {offset3, offset4, offset5})
                 raise "crazy error"
               end,
               pool_name: :my_test_pool_1
             )

    {offset3, offset4, offset5} = Process.get(:raised_offsets)
    TestUtils.assert_offset(MyClient, rec3, offset3, txn_status: :aborted, isolation: :committed)
    TestUtils.assert_offset(MyClient, rec4, offset4, txn_status: :aborted, isolation: :committed)
    TestUtils.assert_offset(MyClient, rec5, offset5, txn_status: :aborted, isolation: :committed)

    assert {:ok, {:ok, %Record{offset: offset6}}} =
             MyClient.transaction(
               fn ->
                 resp = MyClient.produce(rec6)

                 assert {:ok, %Record{offset: offset6}} = resp

                 assert :not_found =
                          TestUtils.assert_offset(MyClient, rec6, offset6, isolation: :committed)

                 assert :ok =
                          TestUtils.assert_offset(MyClient, rec6, offset6, isolation: :uncommitted)

                 {:ok, resp}
               end,
               pool_name: :my_test_pool_1
             )

    TestUtils.assert_offset(MyClient, rec6, offset6, txn_status: :committed)
  end

  # TODO: How to assert transactional behaviour here?
  test "txn produce batch txn" do
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
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    rec4 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec5 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec6 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    assert {:ok,
            [
              %Record{offset: offset1},
              %Record{offset: offset2},
              %Record{offset: offset3}
            ]} = MyClient.produce_batch_txn([rec1, rec2, rec3])

    TestUtils.assert_offset(MyClient, rec1, offset1, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec2, offset2, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec3, offset3, txn_status: :committed)

    assert {:ok,
            [
              %Record{offset: offset4},
              %Record{offset: offset5},
              %Record{offset: offset6}
            ]} = MyClient.produce_batch_txn([rec4, rec5, rec6])

    TestUtils.assert_offset(MyClient, rec4, offset4, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec5, offset5, txn_status: :committed)
    TestUtils.assert_offset(MyClient, rec6, offset6, txn_status: :committed)

    rec7 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec8 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "unkown_topic",
      partition: 0
    }

    rec7_val = rec7.value
    rec8_val = rec8.value

    assert {:error,
            [
              %Record{value: ^rec7_val, error_code: 55},
              %Record{value: ^rec8_val, error_code: 3}
            ]} = MyClient.produce_batch_txn([rec7, rec8])
  end
end
