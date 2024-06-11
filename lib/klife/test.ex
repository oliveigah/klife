defmodule Klife.Test do
  @moduledoc """
  Testing function helpers
  """
  import ExUnit.Assertions

  alias Klife.Record
  alias Klife.Producer.Controller, as: PController
  alias Klife.Connection.Broker, as: Broker
  alias KlifeProtocol.Messages, as: M

  def assert_offset(
        cluster,
        %Record{topic: topic, partition: partition} = expected_record,
        offset,
        opts \\ []
      ) do
    iso_lvl = Keyword.get(opts, :isolation, :committed)
    txn_status = Keyword.get(opts, :txn_status, :committed)

    cluster
    |> get_record_by_offset(topic, partition, offset, iso_lvl)
    |> case do
      nil ->
        :not_found

      {stored_record, status} ->
        assert status == txn_status

        Enum.each(Map.from_struct(expected_record), fn {k, v} ->
          if k in [:value, :key, :headers] do
            assert v == Map.get(stored_record, k)
          end
        end)
    end
  end

  defp get_record_by_offset(cluster_name, topic, partition, offset, isolation) do
    isolation_level =
      case isolation do
        :committed -> 1
        :uncommitted -> 0
      end

    content = %{
      replica_id: -1,
      max_wait_ms: 1000,
      min_bytes: 1,
      max_bytes: 100_000,
      isolation_level: isolation_level,
      topics: [
        %{
          topic: topic,
          partitions: [
            %{
              partition: partition,
              fetch_offset: offset,
              # 1 guarantees that only the first record batch will
              # be retrieved
              partition_max_bytes: 1
            }
          ]
        }
      ]
    }

    {:ok, %{content: content}} =
      Broker.send_message(
        M.Fetch,
        cluster_name,
        PController.get_broker_id(cluster_name, topic, partition),
        content
      )

    topic_resp = Enum.find(content.responses, &(&1.topic == topic))
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))

    aborted_offset =
      case partition_resp.aborted_transactions do
        [%{first_offset: aborted_offset}] -> aborted_offset
        _ -> :infinity
      end

    case partition_resp.records do
      [%{base_offset: base_offset, records: records}] ->
        rec = Enum.find(records, &(&1.offset_delta + base_offset == offset))
        if aborted_offset <= offset, do: {rec, :aborted}, else: {rec, :committed}

      [] ->
        nil
    end
  end
end
