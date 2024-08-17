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

  def get_produce_opts(), do: @produce_opts
  def get_txn_opts(), do: @txn_opts
  def get_async_opts(), do: @async_opts

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

  # The async implementation is non optimal because it may copy a lot of
  # data to the new task process. Ideally we could solve this by making
  # Dispatcher start the callback task instead of send message to the
  # waiting pid but it would be hard to keep the same API this way
  # because inside Dispatcher we do not have the same data and since
  # we want the async callback to receive the exact same output
  # as the sync counter part this is the easiest for now.
  def produce_async(%Record{} = record, client, opts \\ []) do
    {:ok, _task_pid} =
      Task.start(fn ->
        resp = produce(record, client, opts)

        case opts[:callback] do
          {m, f, args} -> apply(m, f, [resp | args])
          fun when is_function(fun, 1) -> fun.(resp)
          _ -> :noop
        end
      end)

    :ok
  end

  def produce_batch_async([%Record{} | _] = records, client, opts \\ []) do
    {:ok, _task_pid} =
      Task.start(fn ->
        resp = produce_batch(records, client, opts)

        case opts[:callback] do
          {m, f, args} -> apply(m, f, [resp | args])
          fun when is_function(fun, 1) -> fun.(resp)
          _ -> :noop
        end
      end)

    :ok
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
