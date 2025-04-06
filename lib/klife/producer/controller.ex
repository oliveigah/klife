defmodule Klife.Producer.Controller do
  @moduledoc false

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.PubSub

  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Producer.ProducerSupervisor

  alias Klife.TxnProducerPool

  alias Klife.Producer

  alias Klife.MetadataCache

  defstruct [
    :client_name,
    :producers,
    :topics,
    :txn_pools
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__, args.client_name}))
  end

  @impl true
  def init(args) do
    client_name = args.client_name
    topics_list = args.topics

    state = %__MODULE__{
      client_name: client_name,
      producers: args.producers,
      txn_pools: args.txn_pools,
      topics: topics_list
    }

    :ok = PubSub.subscribe({:metadata_updated, client_name})
    :ok = sync_with_metadata(state)
    {:ok, state}
  end

  @impl true
  def handle_info(
        {{:metadata_updated, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    :ok = sync_with_metadata(state)

    {:noreply, state}
  end

  defp sync_with_metadata(%__MODULE__{} = state) do
    %__MODULE__{
      client_name: client_name,
      topics: topics
    } = state

    MetadataCache.get_all_metadata(state.client_name)
    |> Enum.each(fn meta ->
      %{
        key: {topic_name, p_index}
      } = meta

      config_topic = Enum.find(topics, %{}, &(&1.name == topic_name))

      true =
        MetadataCache.update_metadata(
          state.client_name,
          topic_name,
          p_index,
          :default_producer,
          config_topic[:default_producer] || client_name.get_default_producer()
        )

      true =
        MetadataCache.update_metadata(
          state.client_name,
          topic_name,
          p_index,
          :default_partitioner,
          config_topic[:default_partitioner] || client_name.get_default_partitioner()
        )
    end)

    :ok =
      if ConnController.disabled_feature?(client_name, :producer),
        do: :ok,
        else: handle_producers(state)

    :ok =
      if ConnController.disabled_feature?(client_name, :txn_producer),
        do: :ok,
        else: handle_txn_producers(state)

    :ok
  end

  # Private functions

  defp handle_producers(%__MODULE__{} = state) do
    for producer <- state.producers do
      opts = Map.put(producer, :client_name, state.client_name)

      DynamicSupervisor.start_child(
        via_tuple({ProducerSupervisor, state.client_name}),
        {Producer, opts}
      )
      |> case do
        {:ok, _pid} -> :ok
        {:error, {:already_started, pid}} -> send(pid, :handle_change)
      end
    end

    :ok
  end

  defp handle_txn_producers(%__MODULE__{} = state) do
    for txn_pool <- state.txn_pools,
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
        client_name: state.client_name,
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

      DynamicSupervisor.start_child(
        via_tuple({ProducerSupervisor, state.client_name}),
        {Producer, txn_producer_configs}
      )
      |> case do
        {:ok, _pid} -> :ok
        {:error, {:already_started, pid}} -> send(pid, :handle_change)
      end
    end

    for txn_pool <- state.txn_pools do
      DynamicSupervisor.start_child(
        via_tuple({ProducerSupervisor, state.client_name}),
        {TxnProducerPool, Map.put(txn_pool, :client_name, state.client_name)}
      )
      |> case do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok
      end
    end

    :ok
  end
end
