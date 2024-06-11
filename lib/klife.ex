defmodule Klife do
  @moduledoc """
  Main functions to interact with clusters.

  Usually you will not need to call any function here directly
  but instead use them through a module that use `Klife.Cluster`.
  """

  alias Klife.Record
  alias Klife.Producer
  alias Klife.TxnProducerPool
  alias Klife.Producer.Controller, as: PController

  def produce(%Record{} = record, cluster, opts \\ []) do
    case produce_batch([record], cluster, opts) do
      [resp] -> resp
      resp -> resp
    end
  end

  def produce_batch([%Record{} | _] = records, cluster, opts \\ []) do
    records =
      records
      |> Enum.with_index(1)
      |> Enum.map(fn {rec, idx} ->
        rec
        |> Map.replace!(:__estimated_size, Record.estimate_size(rec))
        |> Map.replace!(:__batch_index, idx)
        |> maybe_add_partition(cluster, opts)
      end)

    if TxnProducerPool.in_txn?(cluster),
      do: TxnProducerPool.produce(records, cluster, opts),
      else: Producer.produce(records, cluster, opts)
  end

  def produce_batch_txn([%Record{} | _] = records, cluster, opts \\ []) do
    transaction(
      fn -> records |> produce_batch(cluster, opts) |> Record.verify_batch() end,
      cluster,
      opts
    )
  end

  def transaction(fun, cluster, opts \\ []) do
    TxnProducerPool.run_txn(cluster, get_txn_pool(opts), fun)
  end

  defp get_txn_pool(opts), do: Keyword.get(opts, :txn_pool, Klife.Cluster.default_txn_pool_name())

  defp maybe_add_partition(%Record{} = record, cluster, opts) do
    case record do
      %Record{partition: nil, topic: topic} ->
        %{
          default_partitioner: default_partitioner_mod,
          max_partition: max_partition
        } = PController.get_partitioner_data(cluster, topic)

        partitioner_mod = Keyword.get(opts, :partitioner, default_partitioner_mod)

        %{record | partition: partitioner_mod.get_partition(record, max_partition)}

      record ->
        record
    end
  end
end
