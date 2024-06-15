defmodule Klife do
  @moduledoc """
  Main functions to interact with clients.

  Usually you will not need to call any function here directly
  but instead use them through a module that use `Klife.Client`.
  """

  alias Klife.Record
  alias Klife.Producer
  alias Klife.TxnProducerPool
  alias Klife.Producer.Controller, as: PController

  def produce(%Record{} = record, client, opts \\ []) do
    case produce_batch([record], client, opts) do
      [resp] -> resp
      resp -> resp
    end
  end

  def produce_batch([%Record{} | _] = records, client, opts \\ []) do
    records =
      records
      |> Enum.with_index(1)
      |> Enum.map(fn {rec, idx} ->
        rec
        |> Map.replace!(:__estimated_size, Record.estimate_size(rec))
        |> Map.replace!(:__batch_index, idx)
        |> maybe_add_partition(client, opts)
      end)

    if TxnProducerPool.in_txn?(client),
      do: TxnProducerPool.produce(records, client, opts),
      else: Producer.produce(records, client, opts)
  end

  def produce_batch_txn([%Record{} | _] = records, client, opts \\ []) do
    transaction(
      fn -> records |> produce_batch(client, opts) |> Record.verify_batch() end,
      client,
      opts
    )
  end

  def transaction(fun, client, opts \\ []) do
    TxnProducerPool.run_txn(client, get_txn_pool(client, opts), fun)
  end

  def in_txn?(client), do: TxnProducerPool.in_txn?(client)

  defp get_txn_pool(client, opts) do
    case Keyword.get(opts, :pool_name) do
      nil -> apply(client, :get_default_txn_pool, [])
      val -> val
    end
  end

  defp maybe_add_partition(%Record{} = record, client, opts) do
    case record do
      %Record{partition: nil, topic: topic} ->
        %{
          default_partitioner: default_partitioner_mod,
          max_partition: max_partition
        } = PController.get_partitioner_data(client, topic)

        partitioner_mod = Keyword.get(opts, :partitioner, default_partitioner_mod)

        %{record | partition: partitioner_mod.get_partition(record, max_partition)}

      record ->
        record
    end
  end
end
