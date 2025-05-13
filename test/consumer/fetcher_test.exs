defmodule Klife.Consumer.FetcherTest do
  use ExUnit.Case

  alias Klife.Consumer.Fetcher

  alias Klife.Record

  alias Klife.TestUtils

  # TODO: Revisit this test later
  # test "basic test" do
  # topic = "my_topic_1"
  # partition = 1

  # record = %Record{
  #   value: "normal val",
  #   key: :rand.bytes(10),
  #   headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
  #   topic: topic,
  #   partition: partition
  # }

  # assert {:ok, %Record{offset: offset1}} = MyClient.produce(record)

  # record = %Record{
  #   value: "normal val",
  #   key: :rand.bytes(10),
  #   headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
  #   topic: topic,
  #   partition: partition
  # }

  # assert {:ok, %Record{offset: _offset2}} = MyClient.produce(record)

  # record = %Record{
  #   value: "normal val",
  #   key: :rand.bytes(10),
  #   headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
  #   topic: topic,
  #   partition: partition
  # }

  # assert {:ok, %Record{offset: offset3}} = MyClient.produce(record)

  # record = %Record{
  #   value: "normal val",
  #   key: :rand.bytes(10),
  #   headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
  #   topic: topic,
  #   partition: partition
  # }

  # assert {:ok, %Record{offset: _offset4}} = MyClient.produce(record)

  # _req1 = %Batcher.BatchItem{
  #   topic_name: topic,
  #   partition: partition,
  #   offset_to_fetch: offset1,
  #   max_bytes: 1,
  #   __callback: self()
  # }

  # _req2 = %Batcher.BatchItem{
  #   topic_name: topic,
  #   partition: partition,
  #   offset_to_fetch: offset3,
  #   max_bytes: 1,
  #   __callback: self()
  # }

  # broker =
  #   MetadataCache.get_metadata_attribute(MyClient, topic, partition, :leader_id)

  # MyClient.transaction(fn ->
  #   record = %Record{
  #     value: "txn_record",
  #     key: :rand.bytes(10),
  #     headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
  #     topic: topic,
  #     partition: partition
  #   }

  #   {:ok, %{offset: _txn_offset1}} = MyClient.produce(record)
  #   {:ok, %{offset: txn_offset2}} = MyClient.produce(record)
  #   {:ok, %{offset: _txn_offset3}} = MyClient.produce(record)

  #   _other_rec =
  #     Task.async(fn ->
  #       record = %Record{
  #         value: "other normal record",
  #         topic: topic,
  #         partition: partition
  #       }

  #       {:ok, rec} = MyClient.produce(record)
  #       rec
  #     end)
  #     |> Task.await()

  #   req =
  #     %Batcher.BatchItem{
  #       topic_name: topic,
  #       partition: partition,
  #       offset_to_fetch: txn_offset2,
  #       max_bytes: 1,
  #       __callback: self()
  #     }

  #   :ok =
  #     Batcher.request_data([req], MyClient, :klife_default_fetcher, broker, 0, :read_committed)

  #   assert_receive {:fetcher_response, {:ok, _data}}, 1000
  # end)
  # end

  test "basic test" do
    topic1 = "my_topic_1"
    topic2 = "my_topic_2"

    record1 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record2 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 1
    }

    record3 = %Record{
      value: :rand.bytes(10),
      topic: topic2,
      partition: 1
    }

    [
      {:ok, %Record{offset: offset_t1_p0} = rec1},
      {:ok, %Record{offset: offset_t1_p1} = rec2},
      {:ok, %Record{offset: offset_t2_p1} = rec3}
    ] = MyClient.produce_batch([record1, record2, record3])

    tpo_list = [
      {topic1, 0, offset_t1_p0},
      {topic1, 1, offset_t1_p1},
      {topic2, 1, offset_t2_p1}
    ]

    assert %{
             {^topic1, 0, ^offset_t1_p0} => {:ok, [resp1_rec]},
             {^topic1, 1, ^offset_t1_p1} => {:ok, [resp2_rec]},
             {^topic2, 1, ^offset_t2_p1} => {:ok, [resp3_rec]}
           } = Fetcher.fetch(tpo_list, MyClient)

    TestUtils.assert_records(resp1_rec, rec1)
    TestUtils.assert_records(resp2_rec, rec2)
    TestUtils.assert_records(resp3_rec, rec3)
  end

  test "multi records same batch" do
    topic1 = "my_topic_1"
    topic2 = "my_topic_2"

    record1 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record2 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 1
    }

    record3 = %Record{
      value: :rand.bytes(10),
      topic: topic2,
      partition: 1
    }

    record4 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record5 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    [
      {:ok, %Record{offset: offset_t1_p0} = rec1},
      {:ok, %Record{offset: offset_t1_p1} = rec2},
      {:ok, %Record{offset: offset_t2_p1} = rec3},
      {:ok, %Record{} = rec4},
      {:ok, %Record{} = rec5}
    ] = MyClient.produce_batch([record1, record2, record3, record4, record5])

    tpo_list = [
      {topic1, 0, offset_t1_p0},
      {topic1, 1, offset_t1_p1},
      {topic2, 1, offset_t2_p1}
    ]

    assert %{
             {^topic1, 0, ^offset_t1_p0} => {:ok, [resp1_rec, resp4_rec, resp5_rec]},
             {^topic1, 1, ^offset_t1_p1} => {:ok, [resp2_rec]},
             {^topic2, 1, ^offset_t2_p1} => {:ok, [resp3_rec]}
           } = Fetcher.fetch(tpo_list, MyClient)

    TestUtils.assert_records(resp1_rec, rec1)
    TestUtils.assert_records(resp2_rec, rec2)
    TestUtils.assert_records(resp3_rec, rec3)
    TestUtils.assert_records(resp4_rec, rec4)
    TestUtils.assert_records(resp5_rec, rec5)
  end

  test "multi records same batch - request offset in the middle of batch" do
    topic1 = "my_topic_1"
    topic2 = "my_topic_2"

    record1 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record2 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 1
    }

    record3 = %Record{
      value: :rand.bytes(10),
      topic: topic2,
      partition: 1
    }

    record4 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record5 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    [
      {:ok, %Record{} = _rec1},
      {:ok, %Record{offset: offset_t1_p1} = rec2},
      {:ok, %Record{offset: offset_t2_p1} = rec3},
      {:ok, %Record{offset: offset_t1_p0} = rec4},
      {:ok, %Record{} = rec5}
    ] = MyClient.produce_batch([record1, record2, record3, record4, record5])

    tpo_list = [
      {topic1, 0, offset_t1_p0},
      {topic1, 1, offset_t1_p1},
      {topic2, 1, offset_t2_p1}
    ]

    assert %{
             {^topic1, 0, ^offset_t1_p0} => {:ok, [resp4_rec, resp5_rec]},
             {^topic1, 1, ^offset_t1_p1} => {:ok, [resp2_rec]},
             {^topic2, 1, ^offset_t2_p1} => {:ok, [resp3_rec]}
           } = Fetcher.fetch(tpo_list, MyClient)

    TestUtils.assert_records(resp2_rec, rec2)
    TestUtils.assert_records(resp3_rec, rec3)
    TestUtils.assert_records(resp4_rec, rec4)
    TestUtils.assert_records(resp5_rec, rec5)
  end

  test "multi records multi batch" do
    topic1 = "my_topic_1"
    topic2 = "my_topic_2"

    record1 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record2 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 1
    }

    record3 = %Record{
      value: :rand.bytes(10),
      topic: topic2,
      partition: 1
    }

    record4 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record5 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    [
      {:ok, %Record{offset: offset_t1_p0} = rec1},
      {:ok, %Record{offset: offset_t1_p1} = rec2},
      {:ok, %Record{offset: offset_t2_p1} = rec3}
    ] = MyClient.produce_batch([record1, record2, record3])

    [
      {:ok, %Record{} = rec4},
      {:ok, %Record{} = rec5}
    ] =
      MyClient.produce_batch([record4, record5])

    tpo_list = [
      {topic1, 0, offset_t1_p0},
      {topic1, 1, offset_t1_p1},
      {topic2, 1, offset_t2_p1}
    ]

    assert %{
             {^topic1, 0, ^offset_t1_p0} => {:ok, [resp1_rec, resp4_rec, resp5_rec]},
             {^topic1, 1, ^offset_t1_p1} => {:ok, [resp2_rec]},
             {^topic2, 1, ^offset_t2_p1} => {:ok, [resp3_rec]}
           } = Fetcher.fetch(tpo_list, MyClient)

    TestUtils.assert_records(resp1_rec, rec1)
    TestUtils.assert_records(resp2_rec, rec2)
    TestUtils.assert_records(resp3_rec, rec3)
    TestUtils.assert_records(resp4_rec, rec4)
    TestUtils.assert_records(resp5_rec, rec5)
  end

  test "unkown offset" do
    topic1 = "my_topic_1"
    topic2 = "my_topic_2"

    record1 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record2 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 1
    }

    record3 = %Record{
      value: :rand.bytes(10),
      topic: topic2,
      partition: 1
    }

    [
      {:ok, %Record{offset: offset_t1_p0} = _rec1},
      {:ok, %Record{offset: offset_t1_p1} = rec2},
      {:ok, %Record{offset: offset_t2_p1} = rec3}
    ] = MyClient.produce_batch([record1, record2, record3])

    unkown_offset = offset_t1_p0 + 1

    tpo_list = [
      {topic1, 0, unkown_offset},
      {topic1, 1, offset_t1_p1},
      {topic2, 1, offset_t2_p1}
    ]

    assert %{
             {^topic1, 0, ^unkown_offset} => {:ok, []},
             {^topic1, 1, ^offset_t1_p1} => {:ok, [resp2_rec]},
             {^topic2, 1, ^offset_t2_p1} => {:ok, [resp3_rec]}
           } = Fetcher.fetch(tpo_list, MyClient)

    TestUtils.assert_records(resp2_rec, rec2)
    TestUtils.assert_records(resp3_rec, rec3)
  end

  test "error" do
    topic1 = "my_topic_1"
    topic2 = "my_topic_2"

    record1 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record2 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 1
    }

    record3 = %Record{
      value: :rand.bytes(10),
      topic: topic2,
      partition: 1
    }

    [
      {:ok, %Record{offset: offset_t1_p0} = rec1},
      {:ok, %Record{offset: offset_t1_p1} = rec2},
      {:ok, %Record{offset: offset_t2_p1} = rec3}
    ] = MyClient.produce_batch([record1, record2, record3])

    tpo_list = [
      {topic1, 0, offset_t1_p0},
      {"unknown_topic", 1, offset_t1_p1},
      {topic2, 1, offset_t2_p1}
    ]

    assert %{
             {^topic1, 0, ^offset_t1_p0} => {:ok, [resp1_rec]},
             {"unknown_topic", 1, ^offset_t1_p1} => {:error, [resp2_rec]},
             {^topic2, 1, ^offset_t2_p1} => {:ok, [resp3_rec]}
           } = Fetcher.fetch(tpo_list, MyClient)

    TestUtils.assert_records(resp1_rec, rec1)
    TestUtils.assert_records(resp2_rec, rec2)
    TestUtils.assert_records(resp3_rec, rec3)
  end
end
