defmodule Klife.TestingTest do
  use ExUnit.Case

  alias Klife.Testing
  alias Klife.Record

  test "same batch" do
    val1 = :rand.bytes(1000)
    key1 = :rand.bytes(1000)
    header = %{key: :rand.bytes(100), value: :rand.bytes(100)}
    topic = "test_no_batch_topic"

    rec1 = %Record{
      value: val1,
      topic: topic,
      partition: 0,
      headers: [header]
    }

    rec2 = %Record{
      value: :rand.bytes(1000),
      key: key1,
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec3 = %Record{
      value: val1,
      topic: topic,
      partition: 0
    }

    rec4 = %Record{
      value: :rand.bytes(1000),
      topic: topic,
      key: key1,
      partition: 0,
      headers: [header]
    }

    assert {:ok, [resp_rec1, resp_rec2, resp_rec3, resp_rec4]} =
             MyClient.produce_batch([rec1, rec2, rec3, rec4]) |> Klife.Record.verify_batch()

    assert [test_rec1, test_rec3] =
             Testing.all_produced(MyClient, topic, value: val1)

    assert {test_rec1.topic, test_rec1.partition, test_rec1.offset} ==
             {resp_rec1.topic, resp_rec1.partition, resp_rec1.offset}

    assert {test_rec3.topic, test_rec3.partition, test_rec3.offset} ==
             {resp_rec3.topic, resp_rec3.partition, resp_rec3.offset}

    assert [test_rec2, test_rec4] =
             Testing.all_produced(MyClient, topic, key: key1)

    assert {test_rec2.topic, test_rec2.partition, test_rec2.offset} ==
             {resp_rec2.topic, resp_rec2.partition, resp_rec2.offset}

    assert {test_rec4.topic, test_rec4.partition, test_rec4.offset} ==
             {resp_rec4.topic, resp_rec4.partition, resp_rec4.offset}

    assert [test_rec1, test_rec4] =
             Testing.all_produced(MyClient, topic, headers: [header])

    assert {test_rec1.topic, test_rec1.partition, test_rec1.offset} ==
             {resp_rec1.topic, resp_rec1.partition, resp_rec1.offset}

    assert {test_rec4.topic, test_rec4.partition, test_rec4.offset} ==
             {resp_rec4.topic, resp_rec4.partition, resp_rec4.offset}
  end

  test "multi batch" do
    val1 = :rand.bytes(1000)
    key1 = :rand.bytes(1000)
    header = %{key: :rand.bytes(100), value: :rand.bytes(100)}
    topic = "test_no_batch_topic"

    rec1 = %Record{
      value: val1,
      topic: topic,
      partition: 0,
      headers: [header]
    }

    rec2 = %Record{
      value: :rand.bytes(1000),
      key: key1,
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec3 = %Record{
      value: val1,
      topic: topic,
      partition: 0
    }

    rec4 = %Record{
      value: :rand.bytes(1000),
      topic: topic,
      key: key1,
      partition: 0,
      headers: [header]
    }

    assert {:ok, resp_rec1} = MyClient.produce(rec1)
    assert {:ok, resp_rec2} = MyClient.produce(rec2)
    assert {:ok, resp_rec3} = MyClient.produce(rec3)
    assert {:ok, resp_rec4} = MyClient.produce(rec4)

    assert [test_rec1, test_rec3] =
             Testing.all_produced(MyClient, topic, value: val1)

    assert {test_rec1.topic, test_rec1.partition, test_rec1.offset} ==
             {resp_rec1.topic, resp_rec1.partition, resp_rec1.offset}

    assert {test_rec3.topic, test_rec3.partition, test_rec3.offset} ==
             {resp_rec3.topic, resp_rec3.partition, resp_rec3.offset}

    assert [test_rec2, test_rec4] =
             Testing.all_produced(MyClient, topic, key: key1)

    assert {test_rec2.topic, test_rec2.partition, test_rec2.offset} ==
             {resp_rec2.topic, resp_rec2.partition, resp_rec2.offset}

    assert {test_rec4.topic, test_rec4.partition, test_rec4.offset} ==
             {resp_rec4.topic, resp_rec4.partition, resp_rec4.offset}

    assert [test_rec1, test_rec4] =
             Testing.all_produced(MyClient, topic, headers: [header])

    assert {test_rec1.topic, test_rec1.partition, test_rec1.offset} ==
             {resp_rec1.topic, resp_rec1.partition, resp_rec1.offset}

    assert {test_rec4.topic, test_rec4.partition, test_rec4.offset} ==
             {resp_rec4.topic, resp_rec4.partition, resp_rec4.offset}
  end
end
