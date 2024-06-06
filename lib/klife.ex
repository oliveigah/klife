defmodule Klife do
  alias Klife.Record
  alias Klife.Producer
  alias Klife.TxnProducerPool
  alias Klife.Producer.Controller, as: PController

  def produce(record_or_records, opts \\ [])

  def produce(%Record{} = record, opts) do
    case produce([record], opts) do
      [resp] ->
        resp

      resp ->
        resp
    end
  end

  def produce([%Record{} | _] = records, opts) do
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

    in_txn? = TxnProducerPool.in_txn?(cluster)
    with_txn_opt = Keyword.get(opts, :with_txn, false)

    cond do
      in_txn? ->
        TxnProducerPool.produce(records, cluster, opts)

      with_txn_opt ->
        transaction(
          fn ->
            resp = produce(records, opts)

            # Do we really need this match?
            if Enum.all?(resp, &match?({:ok, _}, &1)),
              do: {:ok, resp},
              else: {:error, :abort}
          end,
          opts
        )
        |> case do
          {:ok, resp} -> resp
          err -> err
        end

      true ->
        Producer.produce(records, cluster, opts)
    end
  end

  def transaction(fun, opts \\ []) do
    cluster = get_cluster(opts)
    TxnProducerPool.run_txn(cluster, get_txn_pool(opts), fun)
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
