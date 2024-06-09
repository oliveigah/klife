defmodule Klife do
  alias Klife.Record
  alias Klife.Producer
  alias Klife.TxnProducerPool
  alias Klife.Producer.Controller, as: PController

  def produce(%Record{} = record, opts \\ []) do
    case produce_batch([record], opts) do
      [resp] -> resp
      resp -> resp
    end
  end

  def produce_batch([%Record{} | _] = records, opts \\ []) do
    cluster = get_cluster(opts)

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

  def produce_batch_txn([%Record{} | _] = records, opts \\ []) do
    transaction(fn -> records |> produce_batch(opts) |> verify_batch() end, opts)
  end

  def transaction(fun, opts \\ []) do
    cluster = get_cluster(opts)
    TxnProducerPool.run_txn(cluster, get_txn_pool(opts), fun)
  end

  def verify_batch(produce_resps) do
    case Enum.group_by(produce_resps, &elem(&1, 0), &elem(&1, 1)) do
      %{error: error_list} ->
        {:error, error_list}

      %{ok: resp} ->
        {:ok, resp}
    end
  end

  def verify_batch!(produce_resps) do
    case verify_batch(produce_resps) do
      {:ok, resp} -> resp
      {:error, errors} -> raise "Error on batch verification. #{inspect(errors)}"
    end
  end

  defp default_cluster(), do: :persistent_term.get(:klife_default_cluster)
  defp get_cluster(opts), do: Keyword.get(opts, :cluster, default_cluster())
  defp get_txn_pool(opts), do: Keyword.get(opts, :txn_pool, :klife_txn_pool)

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
