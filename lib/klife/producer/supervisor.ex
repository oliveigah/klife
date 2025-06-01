defmodule Klife.Producer.Supervisor do
  @moduledoc false

  use Supervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.Connection.Controller, as: ConnController

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: via_tuple({__MODULE__, args.client_name}))
  end

  @impl true
  def init(args) do
    client = args.client_name

    max_restarts =
      (args[:txn_pools] || [])
      |> Enum.map(fn %{pool_size: p} -> p end)
      |> Enum.sum()

    children = [
      handle_producers(args, ConnController.disabled_feature?(client, :producer)),
      handle_txn_producers(args, ConnController.disabled_feature?(client, :txn_producer)),
      handle_txn_producer_pool(args, ConnController.disabled_feature?(client, :txn_producer))
    ]

    Supervisor.init(List.flatten(children),
      strategy: :one_for_one,
      # Since the strategy for handle txn coordinator changes
      # is to restart the producer and we may have a very large
      # number of txn producers, we need to accomodate a restart
      # for each producer in order to prevent system crash in
      # the worst case scenario.
      max_restarts: max_restarts + 1,
      # In order to not hide problems with the max restarts change
      # we need to bump this number in order to catch problems
      max_seconds: 60
    )
  end

  defp handle_producers(_args, true), do: []

  defp handle_producers(args, false) do
    for producer_conf <- args.producers do
      opts = Map.put(producer_conf, :client_name, args.client_name)

      %{
        id: opts.name,
        start: {Klife.Producer, :start_link, [opts]},
        restart: :permanent,
        shutdown: opts.request_timeout_ms,
        type: :worker
      }
    end
  end

  defp handle_txn_producers(_args, true), do: []

  defp handle_txn_producers(args, false) do
    for txn_pool <- args.txn_pools,
        txn_producer_count <- 1..txn_pool.pool_size do
      txn_id =
        if txn_pool.base_txn_id != "" do
          txn_pool.base_txn_id <> "_#{txn_producer_count}"
        else
          :crypto.strong_rand_bytes(11)
          |> Base.url_encode64(padding: false)
          |> binary_part(0, 15)
          |> Kernel.<>("_#{txn_producer_count}")
        end

      txn_producer_configs = %{
        client_name: args.client_name,
        name: "klife_txn_producer.#{txn_pool.name}.#{txn_producer_count}",
        acks: :all,
        linger_ms: 0,
        delivery_timeout_ms: txn_pool.delivery_timeout_ms,
        request_timeout_ms: txn_pool.request_timeout_ms,
        retry_backoff_ms: txn_pool.retry_backoff_ms,
        max_in_flight_requests: 1,
        batchers_count: 1,
        enable_idempotence: true,
        compression_type: txn_pool.compression_type,
        txn_id: txn_id,
        txn_timeout_ms: txn_pool.txn_timeout_ms
      }

      %{
        id: txn_producer_configs.name,
        start: {Klife.Producer, :start_link, [txn_producer_configs]},
        restart: :permanent,
        shutdown: txn_producer_configs.request_timeout_ms,
        type: :worker
      }
    end
  end

  defp handle_txn_producer_pool(_args, true), do: []

  defp handle_txn_producer_pool(args, false) do
    for txn_pool <- args.txn_pools do
      opts = Map.put(txn_pool, :client_name, args.client_name)

      %{
        id: opts.name,
        start: {Klife.TxnProducerPool, :start_link, [opts]},
        restart: :permanent,
        shutdown: opts.request_timeout_ms,
        type: :worker
      }
    end
  end
end
