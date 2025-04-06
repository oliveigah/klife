defmodule Klife.Consumer.FetcherTest do
  use ExUnit.Case

  alias Klife.Consumer.Fetcher.Batcher

  alias Klife.MetadataCache

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

    assert {:ok, %Record{offset: offset1}} = MyClient.produce(record)

    record = %Record{
      value: "normal val",
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    assert {:ok, %Record{offset: _offset2}} = MyClient.produce(record)

    record = %Record{
      value: "normal val",
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    assert {:ok, %Record{offset: offset3}} = MyClient.produce(record)

    record = %Record{
      value: "normal val",
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    assert {:ok, %Record{offset: _offset4}} = MyClient.produce(record)

    _req1 = %Batcher.BatchItem{
      topic_name: topic,
      partition: partition,
      offset_to_fetch: offset1,
      max_bytes: 1,
      __callback: self()
    }

    _req2 = %Batcher.BatchItem{
      topic_name: topic,
      partition: partition,
      offset_to_fetch: offset3,
      max_bytes: 1,
      __callback: self()
    }

    broker =
      MetadataCache.get_metadata_attribute(MyClient, topic, partition, :leader_id)

    MyClient.transaction(fn ->
      record = %Record{
        value: "txn_record",
        key: :rand.bytes(10),
        headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
        topic: topic,
        partition: partition
      }

      {:ok, %{offset: _txn_offset1}} = MyClient.produce(record)
      {:ok, %{offset: txn_offset2}} = MyClient.produce(record)
      {:ok, %{offset: _txn_offset3}} = MyClient.produce(record)

      _other_rec =
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

      req =
        %Batcher.BatchItem{
          topic_name: topic,
          partition: partition,
          offset_to_fetch: txn_offset2,
          max_bytes: 1,
          __callback: self()
        }

      :ok =
        Batcher.request_data([req], MyClient, :klife_default_fetcher, broker, 0, :read_committed)

      assert_receive {:fetcher_response, {:ok, _data}}, 1000
    end)
  end
end
