defmodule Klife.Consumer.FetcherTest do
  use ExUnit.Case

  alias Klife.Consumer.Fetcher

  alias Klife.Record

  alias Klife.TestUtils

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

  test "multi offsets for the same topic" do
    topic1 = "my_topic_1"

    record1 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record2 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    record3 = %Record{
      value: :rand.bytes(10),
      topic: topic1,
      partition: 0
    }

    [
      {:ok, %Record{offset: offset1} = rec1},
      {:ok, %Record{offset: offset2} = rec2},
      {:ok, %Record{offset: offset3} = rec3}
    ] = MyClient.produce_batch([record1, record2, record3])

    tpo_list = [
      {topic1, 0, offset1},
      {topic1, 0, offset2},
      {topic1, 0, offset3}
    ]

    assert %{
             {^topic1, 0, ^offset1} => {:ok, [resp1_rec, resp2_rec, resp3_rec]},
             {^topic1, 0, ^offset2} => {:ok, [resp2_rec, resp3_rec]},
             {^topic1, 0, ^offset3} => {:ok, [resp3_rec]}
           } = Fetcher.fetch(tpo_list, MyClient)

    TestUtils.assert_records(resp1_rec, rec1)
    TestUtils.assert_records(resp2_rec, rec2)
    TestUtils.assert_records(resp3_rec, rec3)
  end

  test "aborted transaction should not impact future records" do
    topic = "test_no_batch_topic"
    partition = 1

    [{:ok, rec0}] =
      MyClient.produce_batch([
        %Klife.Record{topic: topic, partition: partition, value: "a"}
      ])

    MyClient.produce_batch([
      %Klife.Record{topic: topic, partition: partition, value: "b"}
    ])

    MyClient.produce_batch([
      %Klife.Record{topic: topic, partition: partition, value: "c"},
      %Klife.Record{topic: topic, partition: partition, value: "d"}
    ])

    {:error, txn_error_resp0} =
      MyClient.transaction(
        fn ->
          resp0 =
            MyClient.produce_batch([
              %Klife.Record{topic: topic, partition: partition, value: "e"}
            ])

          resp1 =
            MyClient.produce_batch([
              %Klife.Record{topic: topic, partition: partition, value: "f"}
            ])

          {:error, resp0 ++ resp1}
        end,
        pool_name: :my_test_pool_1
      )

    {:ok, txn_success_resp} =
      MyClient.transaction(
        fn ->
          resp =
            MyClient.produce_batch([
              %Klife.Record{topic: topic, partition: partition, value: "g"},
              %Klife.Record{topic: topic, partition: partition, value: "h"}
            ])

          {:ok, resp}
        end,
        pool_name: :my_test_pool_1
      )

    [{:ok, resp_check_rec0}] =
      MyClient.produce_batch([
        %Klife.Record{topic: topic, partition: partition, value: "i"}
      ])

    {:error, txn_error_resp1} =
      MyClient.transaction(
        fn ->
          aborted_offsets =
            MyClient.produce_batch([
              %Klife.Record{topic: topic, partition: partition, value: "j"},
              %Klife.Record{topic: topic, partition: partition, value: "k"}
            ])

          {:error, aborted_offsets}
        end,
        pool_name: :my_test_pool_1
      )

    [{:ok, resp_check_rec1}] =
      MyClient.produce_batch([
        %Klife.Record{topic: topic, partition: partition, value: "l"}
      ])

    fetch_resp =
      Fetcher.fetch([{topic, partition, rec0.offset}], MyClient)

    assert {:ok, all_recs} = fetch_resp[{topic, partition, rec0.offset}]

    to_check = Enum.find(all_recs, fn r -> r.offset == resp_check_rec0.offset end)
    assert to_check.value == resp_check_rec0.value
    assert to_check.is_aborted == false

    to_check = Enum.find(all_recs, fn r -> r.offset == resp_check_rec1.offset end)
    assert to_check.value == resp_check_rec1.value
    assert to_check.is_aborted == false

    Enum.each(txn_error_resp0, fn {:ok, to_check} ->
      to_check = Enum.find(all_recs, fn r -> r.offset == to_check.offset end)
      assert to_check.is_aborted == true
    end)

    Enum.each(txn_success_resp, fn {:ok, to_check} ->
      to_check = Enum.find(all_recs, fn r -> r.offset == to_check.offset end)
      assert to_check.is_aborted == false
    end)

    Enum.each(txn_error_resp1, fn {:ok, to_check} ->
      to_check = Enum.find(all_recs, fn r -> r.offset == to_check.offset end)
      assert to_check.is_aborted == true
    end)
  end
end
