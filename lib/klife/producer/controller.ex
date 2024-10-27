defmodule Klife.Producer.Controller do
  @moduledoc false

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  alias Klife.PubSub

  alias KlifeProtocol.Messages
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Producer.ProducerSupervisor

  alias Klife.TxnProducerPool

  alias Klife.Producer

  @check_metadata_delay :timer.seconds(5)

  defstruct [
    :client_name,
    :producers,
    :topics,
    :check_metadata_waiting_pids,
    :check_metadata_timer_ref,
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
      topics: topics_list,
      check_metadata_waiting_pids: [],
      check_metadata_timer_ref: nil
    }

    :ets.new(topics_partitions_metadata_table(client_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    :ets.new(partitioner_metadata_table(client_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    :ok = PubSub.subscribe({:cluster_change, client_name})

    {:ok, do_init(state)}
  end

  defp do_init(state) do
    {:noreply, state} = handle_info(:check_metadata, state)
    state
  end

  def handle_info(
        {{:cluster_change, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    Process.cancel_timer(state.check_metadata_timer_ref)
    new_ref = Process.send_after(self(), :check_cluster, 0)

    {:noreply,
     %__MODULE__{
       state
       | check_metadata_timer_ref: new_ref
     }}
  end

  @impl true
  def handle_info(
        :check_metadata,
        %__MODULE__{client_name: client_name} = state
      ) do
    content = %{topics: nil}

    case Broker.send_message(Messages.Metadata, client_name, :controller, content) do
      {:error, _} ->
        :ok = ConnController.trigger_brokers_verification(client_name)
        new_ref = Process.send_after(self(), :check_metadata, :timer.seconds(1))
        {:noreply, %{state | check_metadata_timer_ref: new_ref}}

      {:ok, %{content: resp}} ->
        :ok = setup_producers(state, resp)
        :ok = setup_partitioners(state, resp)

        if Enum.any?(resp.topics, &(&1.error_code != 0)) do
          new_ref = Process.send_after(self(), :check_metadata, :timer.seconds(1))
          {:noreply, %{state | check_metadata_timer_ref: new_ref}}
        else
          state.check_metadata_waiting_pids
          |> Enum.reverse()
          |> Enum.each(&GenServer.reply(&1, :ok))

          new_ref = Process.send_after(self(), :check_metadata, @check_metadata_delay)

          {:noreply,
           %{state | check_metadata_timer_ref: new_ref, check_metadata_waiting_pids: []}}
        end
    end
  end

  @impl true
  def handle_call(:trigger_check_metadata, from, state) do
    case state do
      %__MODULE__{check_metadata_waiting_pids: []} ->
        Process.cancel_timer(state.check_metadata_timer_ref)
        new_ref = Process.send_after(self(), :check_cluster, 0)

        {:noreply,
         %__MODULE__{
           state
           | check_metadata_waiting_pids: [from],
             check_metadata_timer_ref: new_ref
         }}

      %__MODULE__{} ->
        {:noreply,
         %__MODULE__{
           state
           | check_metadata_waiting_pids: [from | state.check_metadata_waiting_pids]
         }}
    end
  end

  # Public Interface

  def trigger_metadata_verification_sync(client_name) do
    GenServer.call(via_tuple({__MODULE__, client_name}), :trigger_check_metadata)
  end

  def trigger_metadata_verification_async(client_name) do
    GenServer.cast(via_tuple({__MODULE__, client_name}), :trigger_check_metadata)
  end

  def get_topics_partitions_metadata(client_name, topic, partition) do
    [{_key, broker_id, default_producer, batcher_id}] =
      client_name
      |> topics_partitions_metadata_table()
      |> :ets.lookup({topic, partition})

    %{
      broker_id: broker_id,
      producer_name: default_producer,
      batcher_id: batcher_id
    }
  end

  def get_broker_id(client_name, topic, partition) do
    client_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 2)
  end

  def get_default_producer(client_name, topic, partition) do
    client_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 3)
  end

  def get_batcher_id(client_name, topic, partition) do
    client_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 4)
  end

  def update_batcher_id(client_name, topic, partition, new_batcher_id) do
    client_name
    |> topics_partitions_metadata_table()
    |> :ets.update_element({topic, partition}, {4, new_batcher_id})
  end

  def get_all_topics_partitions_metadata(client_name) do
    client_name
    |> topics_partitions_metadata_table()
    |> :ets.tab2list()
    |> Enum.map(fn {{topic_name, partition_idx}, leader_id, _default_producer, batcher_id} ->
      %{
        topic_name: topic_name,
        partition_idx: partition_idx,
        leader_id: leader_id,
        batcher_id: batcher_id
      }
    end)
  end

  def get_partitioner_data(client_name, topic) do
    client_name
    |> partitioner_metadata_table()
    |> :ets.lookup_element(topic, 2)
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

  defp setup_producers(%__MODULE__{} = state, resp) do
    %__MODULE__{
      client_name: client_name,
      topics: topics
    } = state

    table_name = topics_partitions_metadata_table(client_name)

    any_new? =
      for topic <- resp.topics,
          partition <- topic.partitions,
          topic.error_code == 0,
          reduce: false do
        acc ->
          case :ets.lookup(table_name, {topic.name, partition.partition_index}) do
            [] ->
              config_topic = Enum.find(topics, %{}, &(&1.name == topic.name))

              :ets.insert(table_name, {
                {topic.name, partition.partition_index},
                partition.leader_id,
                config_topic[:default_producer] || apply(client_name, :get_default_producer, []),
                # batcher_id will be defined on producer
                nil
              })

              true

            [{key, current_broker_id, _default_producer, _batcher_id}] ->
              if current_broker_id != partition.leader_id do
                :ets.update_element(
                  table_name,
                  key,
                  {2, partition.leader_id}
                )

                true
              else
                acc
              end
          end
      end

    if any_new? do
      :ok = handle_producers(state)
      :ok = handle_txn_producers(state)
    end

    :ok
  end

  defp setup_partitioners(%__MODULE__{} = state, resp) do
    %__MODULE__{
      client_name: client_name,
      topics: topics
    } = state

    table_name = partitioner_metadata_table(client_name)

    for topic <- resp.topics, topic.error_code == 0 do
      config_topic = Enum.find(topics, %{}, &(&1.name == topic.name))

      %{partition_index: max_partition} = Enum.max_by(topic.partitions, & &1.partition_index)

      data = %{
        max_partition: max_partition,
        default_partitioner:
          config_topic[:default_partitioner] || client_name.get_default_partitioner()
      }

      case :ets.lookup(table_name, topic.name) do
        [{_key, ^data}] -> :noop
        _ -> :ets.insert(table_name, {topic.name, data})
      end
    end

    :ok
  end

  defp topics_partitions_metadata_table(client_name),
    do: :"topics_partitions_metadata.#{client_name}"

  defp partitioner_metadata_table(client_name),
    do: :"partitioner_metadata.#{client_name}"
end
