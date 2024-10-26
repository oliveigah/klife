defmodule Klife.Testing do
  @moduledoc """
  Testing helper functions.

  In order to test kafka behaviour on tests we can have 2 approachs:

  - Having a running kafka broker locally and testing against it
  - Mocking all external calls to the broker

  `Klife.Testing` supports the first approach by offering helper functions in order to
  verify if a record with the given list of properties exists in the broker.

  You can use it like this:

  ```elixir
  # on test_helper.exs
  Klife.Testing.setup(MyClient)

  # on your test file
  Klife.Testing.all_produced(MyClient, "my_topic_a", value: "abc")
  ```


  The mocks approach is not supported directly by Klife but can be achieved using some
  awesome community libraries such as [Mimic](https://github.com/edgurgel/mimic) or
  [Mox](https://github.com/dashbitco/mox).

  """

  alias Klife.Producer.Controller, as: PController
  alias Klife.Connection.Broker, as: Broker
  alias KlifeProtocol.Messages, as: M

  # TODO: Rethink all_produced when consumer system is functional
  @doc """
  Return a list of `Klife.Record` that match the given filters.

  You can search by 3 fields:
  - value: binary
  - key: binary
  - headers: list of maps %{key: binary, value: binary}

  The semantics between all possible fields is "and". Which means we only return records
  that have match on all 3 filters if all 3 are available.

  The semantics on the headers list is also "and". Which means we only return records
  that have match with all headers given on the list.

  ## Examples
      iex> val = :rand.bytes(1000)
      iex> rec = %Klife.Record{value: val, topic: "my_topic_1"}
      iex> {:ok, %Klife.Record{}} = MyClient.produce(rec)
      iex> [%Klife.Record{}] = Klife.Testing.all_produced(MyClient, "my_topic_1", value: val)
  """
  def all_produced(_client, _topic, []),
    do: raise("all_produced/3 must have at least one of the following opts value, key or headers")

  def all_produced(client, topic, search_opts) do
    metas =
      client
      |> PController.get_all_topics_partitions_metadata()
      |> Enum.filter(fn meta -> meta.topic_name == topic end)

    metas
    |> Enum.group_by(fn m -> m.leader_id end)
    |> Enum.map(fn {leader_id, metas} -> get_records(leader_id, metas, client) end)
    |> List.flatten()
    |> Enum.filter(fn rec -> match_search_map?(rec, search_opts) end)
  end

  @doc """
  Setup `Klife.Testing`, call it on your `test_helper.exs`.

  In order to avoid big searchs on big local running kafka topics, this setup retrieves
  all te current latests offsets and stores it to only search after them.
  """
  def setup(client) do
    metas = PController.get_all_topics_partitions_metadata(client)

    :ok = warmup_topics(metas, client)

    metas
    |> Enum.group_by(fn m -> m.leader_id end)
    |> Enum.map(fn {leader_id, metas} -> get_latest_offsets(leader_id, metas, client) end)
    |> List.flatten()
    |> Enum.group_by(fn {topic, _pdata} -> topic end, fn {_topic, pdata} -> pdata end)
    |> Enum.map(fn {topic, pdatas} -> {topic, List.flatten(pdatas)} end)
    |> Enum.each(fn {topic, pdata} ->
      Enum.each(pdata, fn {partition, offset} ->
        :persistent_term.put({__MODULE__, client, topic, partition}, offset)
      end)
    end)
  end

  defp warmup_topics(metas, client) do
    recs =
      Enum.map(metas, fn meta ->
        if String.starts_with?(meta.topic_name, "__") do
          nil
        else
          %Klife.Record{
            topic: meta.topic_name,
            value: "klife_warmup_txn",
            partition: meta.partition_idx
          }
        end
      end)
      |> Enum.reject(fn e -> is_nil(e) end)

    txn_fun = fn ->
      apply(client, :produce_batch, [recs])
      {:error, :test_txn_warmup}
    end

    {:error, :test_txn_warmup} = apply(client, :transaction, [txn_fun])

    :ok
  end

  defp get_setup_offset(client, topic, partition) do
    :persistent_term.get({__MODULE__, client, topic, partition}, -1)
  end

  defp match_search_map?(rec, search_opts) do
    Enum.all?(search_opts, fn {k, v} ->
      case k do
        :value ->
          rec.value == v

        :key ->
          rec.key == v

        :headers ->
          Enum.all?(v, fn hv -> hv in rec.headers end)
      end
    end)
  end

  defp get_records(leader_id, metas, client_name) do
    # 100 MB
    max_bytes = 100_000_000

    content = %{
      replica_id: -1,
      max_wait_ms: 100,
      min_bytes: 1,
      max_bytes: max_bytes,
      isolation_level: 0,
      topics:
        metas
        |> Enum.group_by(fn meta -> meta.topic_name end, fn meta -> meta.partition_idx end)
        |> Enum.map(fn {topic, partitions} ->
          %{
            topic: topic,
            partitions:
              Enum.map(partitions, fn p ->
                %{
                  partition: p,
                  fetch_offset: get_setup_offset(client_name, topic, p) + 1,
                  partition_max_bytes: round(max_bytes / length(partitions))
                }
              end)
          }
        end)
    }

    {:ok, %{content: %{responses: [%{topic: topic} = t_data]}}} =
      Broker.send_message(
        M.Fetch,
        client_name,
        leader_id,
        content
      )

    t_data.partitions
    |> List.flatten()
    |> Enum.map(fn pdata ->
      if pdata.error_code not in [0, 1], do: raise("unexpected error code for #{inspect(pdata)}")

      aborted_offset =
        case pdata.aborted_transactions do
          [%{first_offset: aborted_offset}] -> aborted_offset
          _ -> :infinity
        end

      pdata.records
      |> Enum.map(fn rec_batch ->
        rec_batch
        |> Map.put(:partition_idx, pdata.partition_index)
        |> Map.put(:first_aborted_offset, aborted_offset)
      end)
    end)
    |> List.flatten()
    |> Enum.map(fn batch ->
      batch.records
      |> Enum.map(fn rec ->
        new_rec =
          rec
          |> Map.put(:partition_idx, batch.partition_idx)
          |> Map.put(:offset, batch.base_offset + rec.offset_delta)

        if new_rec.offset >= batch.first_aborted_offset, do: nil, else: new_rec
      end)
    end)
    |> List.flatten()
    |> Enum.reject(fn rec -> is_nil(rec) end)
    |> Enum.map(fn rec ->
      %Klife.Record{
        value: rec.value,
        topic: topic,
        key: rec.key,
        headers: rec.headers,
        offset: rec.offset,
        partition: rec.partition_idx,
        error_code: nil
      }
    end)
  end

  defp get_latest_offsets(leader_id, metas, client_name) do
    content = %{
      replica_id: -1,
      isolation_level: 1,
      topics:
        metas
        |> Enum.group_by(fn meta -> meta.topic_name end, fn meta -> meta.partition_idx end)
        |> Enum.map(fn {topic, partitions} ->
          %{
            name: topic,
            partitions:
              Enum.map(partitions, fn p ->
                %{
                  partition_index: p,
                  timestamp: -1
                }
              end)
          }
        end)
    }

    {:ok, %{content: %{topics: tdatas}}} =
      Broker.send_message(
        M.ListOffsets,
        client_name,
        leader_id,
        content
      )

    Enum.map(tdatas, fn tdata ->
      value =
        tdata.partitions
        |> Enum.map(fn pdata ->
          {pdata.partition_index, pdata.offset}
        end)

      {tdata.name, value}
    end)
  end
end