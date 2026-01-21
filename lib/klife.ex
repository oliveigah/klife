defmodule Klife do
  @moduledoc """
  Main functions to interact with clients.

  Usually you will not need to call any function here directly
  but instead use them through a module that uses `Klife.Client`.
  """

  # TODO: Standardize error messages and raises
  # TODO: Standardize timeouts

  alias Klife.Record
  alias Klife.Producer
  alias Klife.TxnProducerPool
  alias Klife.Connection.Controller, as: ConnController

  alias Klife.MetadataCache

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
    records = prepare_records(records, client, opts)

    if TxnProducerPool.in_txn?(client) do
      TxnProducerPool.produce(records, client, opts)
    else
      if ConnController.disabled_feature?(client, :producer) do
        raise """
        You have tried to call the Produce API, but the producer feature is disabled. Check logs for details.
        """
      end

      Producer.produce(records, client, opts)
    end
  end

  @doc false
  def produce_async(%Record{} = record, client, opts \\ []) do
    if ConnController.disabled_feature?(client, :producer) do
      raise """
      You have tried to call the Produce API, but the producer feature is disabled. Check logs for details.
      """
    end

    prepared_rec = prepare_records(record, client, opts)
    Producer.produce_async([prepared_rec], client, opts)
  end

  @doc false
  def produce_batch_async([%Record{} | _] = records, client, opts \\ []) do
    if ConnController.disabled_feature?(client, :producer) do
      raise """
      You have tried to call the Produce API, but the producer feature is disabled. Check logs for details.
      """
    end

    case opts[:callback] do
      nil ->
        records = prepare_records(records, client, opts)
        Producer.produce_async(records, client, opts)

      {m, f, args} ->
        Task.start(fn -> apply(m, f, [produce_batch(records, client, opts) | args]) end)
        :ok

      fun when is_function(fun, 1) ->
        Task.start(fn -> fun.(produce_batch(records, client, opts)) end)
        :ok
    end
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
    if ConnController.disabled_feature?(client, :txn_producer) do
      raise """
      You have tried to call the Transaction API, but the txn_producer feature is disabled. Check logs for details.
      """
    end

    TxnProducerPool.run_txn(client, get_txn_pool(client, opts), fun)
  end

  defp get_txn_pool(client, opts) do
    Keyword.get(opts, :pool_name) || client.get_default_txn_pool()
  end

  defp maybe_add_partition(%Record{} = record, client, opts) do
    case record do
      %Record{partition: nil, topic: topic} ->
        {:ok,
         %{
           default_partitioner: default_partitioner_mod,
           max_partition: max_partition
         }} = MetadataCache.get_metadata(client, topic, 0)

        partitioner_mod = Keyword.get(opts, :partitioner, default_partitioner_mod)

        %{record | partition: partitioner_mod.get_partition(record, max_partition)}

      record ->
        record
    end
  end

  defp prepare_records(%Record{} = rec, client, opts) do
    [new_rec] = prepare_records([rec], client, opts)
    new_rec
  end

  defp prepare_records(recs, client, opts) when is_list(recs) do
    recs
    |> Enum.with_index(1)
    |> Enum.map(fn {rec, idx} ->
      rec
      |> Map.replace!(:__estimated_size, Record.estimate_size(rec))
      |> Map.replace!(:__batch_index, idx)
      |> maybe_add_partition(client, opts)
    end)
  end
end
