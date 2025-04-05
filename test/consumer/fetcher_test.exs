defmodule Klife.Consumer.FetcherTest do
  use ExUnit.Case

  alias Klife.Consumer.Fetcher.Batcher

  alias Klife.Producer.Controller, as: PController
  alias Klife.Record

  test "basic test" do
    topic = "my_topic_1"
    partition = 1

    record = %Record{
      value: "normal val",
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    assert {:ok, %Record{offset: offset1} = resp_rec} = MyClient.produce(record)

    record = %Record{
      value: "normal val",
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    assert {:ok, %Record{offset: offset2} = resp_rec} = MyClient.produce(record)

    record = %Record{
      value: "normal val",
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    assert {:ok, %Record{offset: offset3} = resp_rec} = MyClient.produce(record)

    record = %Record{
      value: "normal val",
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    assert {:ok, %Record{offset: offset4} = resp_rec} = MyClient.produce(record)

    req1 = %Batcher.BatchItem{
      topic_name: topic,
      partition: partition,
      offset_to_fetch: offset1,
      max_bytes: 1,
      __callback: self()
    }

    req2 = %Batcher.BatchItem{
      topic_name: topic,
      partition: partition,
      offset_to_fetch: offset3,
      max_bytes: 1,
      __callback: self()
    }

    broker = PController.get_broker_id(MyClient, topic, partition)

    MyClient.transaction(fn ->
      record = %Record{
        value: "txn_record",
        key: :rand.bytes(10),
        headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
        topic: topic,
        partition: partition
      }

      {:ok, %{offset: txn_offset1}} = MyClient.produce(record)
      {:ok, %{offset: txn_offset2}} = MyClient.produce(record)
      {:ok, %{offset: txn_offset3}} = MyClient.produce(record)

      other_rec =
        Task.async(fn ->
          record = %Record{
            value: "other normal record",
            topic: topic,
            partition: partition
          }

          {:ok, rec} = MyClient.produce(record)
          rec
        end)
        |> Task.await()
        |> IO.inspect()

      req =
        %Batcher.BatchItem{
          topic_name: topic,
          partition: partition,
          offset_to_fetch: txn_offset2,
          max_bytes: 1,
          __callback: self()
        }
        |> IO.inspect()

      :ok =
        Batcher.request_data([req], MyClient, :klife_default_fetcher, broker, 0, :read_committed)

      assert_receive {:fetcher_response, {:ok, data}}, 1000

      IO.inspect(data)
    end)
  end
end
