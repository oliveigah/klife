defmodule Klife do
  @moduledoc """
  Main functions to interact with clients.

  Usually you will not need to call any function here directly
  but instead use them through a module that uses `Klife.Client`.
  """

  alias Klife.Record
  alias Klife.Producer
  alias Klife.TxnProducerPool
  alias Klife.Producer.Controller, as: PController

  @produce_opts [
    producer: [
      type: :atom,
      required: false,
      doc:
        "Producer's name that will override the `default_producer` configuration. Ignored inside transactions."
    ],
    partitioner: [
      type: :atom,
      required: false,
      doc: "Module that will override `default_partitioner` configuration."
    ]
  ]

  @async_opts [
    callback: [
      type: :any,
      required: false,
      doc:
        "MFA or function/1 that will be called with the produce result. The result is injected as the first argument on MFA and is the only argument for anonymous functions"
    ]
  ]

  @txn_opts [
    pool_name: [
      type: :atom,
      required: false,
      doc: "Txn pool's name that will override the `default_txn_pool` configuration."
    ]
  ]

  @doc false
  def get_produce_opts(), do: @produce_opts
  @doc false
  def get_txn_opts(), do: @txn_opts
  @doc false
  def get_async_opts(), do: @async_opts

  @doc false
  def produce(%Record{} = record, client, opts \\ []) do
    [resp] = produce_batch([record], client, opts)
    resp
  end

  @doc false
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

  @doc false
  def produce_async(%Record{} = record, client, opts \\ []) do
    produce_batch_async([record], client, opts)
  end

  @doc false
  def produce_batch_async([%Record{} | _] = records, client, opts \\ []) do
    records =
      records
      |> Enum.with_index(1)
      |> Enum.map(fn {rec, idx} ->
        rec
        |> Map.replace!(:__estimated_size, Record.estimate_size(rec))
        |> Map.replace!(:__batch_index, idx)
        |> maybe_add_partition(client, opts)
      end)

    Producer.produce_async(records, client, opts)
  end

  @doc false
  def produce_batch_txn([%Record{} | _] = records, client, opts \\ []) do
    transaction(
      fn -> records |> produce_batch(client, opts) |> Record.verify_batch() end,
      client,
      opts
    )
  end

  @doc false
  def transaction(fun, client, opts \\ []) do
    TxnProducerPool.run_txn(client, get_txn_pool(client, opts), fun)
  end

  defp get_txn_pool(client, opts) do
    Keyword.get(opts, :pool_name) || client.get_default_txn_pool()
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
