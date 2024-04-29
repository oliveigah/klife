defmodule Klife.Producer.Controller do
  use GenServer

  import Klife.ProcessRegistry

  alias KlifeProtocol.Messages
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Utils
  alias Klife.Producer.ProducerSupervisor

  alias Klife.Producer

  @default_producer %{name: :default_producer}
  @check_metadata_delay :timer.seconds(10)

  defstruct [
    :cluster_name,
    :producers,
    :topics,
    :check_metadata_waiting_pids,
    :check_metadata_timer_ref
  ]

  def start_link(args) do
    cluster_name = Keyword.fetch!(args, :cluster_name)
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(args) do
    cluster_name = Keyword.fetch!(args, :cluster_name)
    topics_list = Keyword.get(args, :topics, [])

    timer_ref = Process.send_after(self(), :check_metadata, 0)

    state = %__MODULE__{
      cluster_name: cluster_name,
      producers: [@default_producer] ++ Keyword.get(args, :producers, []),
      topics: Enum.filter(topics_list, &Map.get(&1, :enable_produce, true)),
      check_metadata_waiting_pids: [],
      check_metadata_timer_ref: timer_ref
    }

    Enum.each(topics_list, fn t ->
      :persistent_term.put(
        {__MODULE__, cluster_name, t.name},
        Map.get(t, :producer, @default_producer.name)
      )
    end)

    :ets.new(topics_partitions_metadata_table(cluster_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    Utils.wait_connection!(cluster_name)

    {:ok, state}
  end

  def handle_info(:init_producers, %__MODULE__{} = state) do
    for producer <- state.producers do
      opts =
        producer
        |> Map.put(:cluster_name, state.cluster_name)
        |> Map.to_list()

      result =
        DynamicSupervisor.start_child(
          via_tuple({ProducerSupervisor, state.cluster_name}),
          {Producer, opts}
        )

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        :check_metadata,
        %__MODULE__{cluster_name: cluster_name, topics: topics} = state
      ) do
    content = %{
      topics: Enum.map(topics, fn t -> %{name: t.name} end)
    }

    case Broker.send_message(Messages.Metadata, cluster_name, :controller, content) do
      {:error, _} ->
        :ok = ConnController.trigger_brokers_verification(cluster_name)
        new_ref = Process.send_after(self(), :check_metadata, :timer.seconds(1))
        {:noreply, %{state | check_metadata_timer_ref: new_ref}}

      {:ok, %{content: resp}} ->
        table_name = topics_partitions_metadata_table(cluster_name)

        results =
          for topic <- Enum.filter(resp.topics, &(&1.error_code == 0)),
              config_topic = Enum.find(topics, &(&1.name == topic.name)),
              partition <- topic.partitions do
            case :ets.lookup(table_name, {topic.name, partition.partition_index}) do
              [] ->
                :ets.insert(table_name, {
                  {topic.name, partition.partition_index},
                  partition.leader_id,
                  config_topic[:producer] || @default_producer.name,
                  nil
                })

                :new

              [{key, current_broker_id, _default_producer, _batcher_id}] ->
                if current_broker_id != partition.leader_id do
                  :ets.update_element(
                    table_name,
                    key,
                    {2, partition.leader_id}
                  )

                  :new
                else
                  :noop
                end
            end
          end

        if Enum.any?(results, &(&1 == :new)) do
          send(self(), :init_producers)
        end

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
  def handle_call(:trigger_check_metadata, from, %__MODULE__{} = state) do
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
           | check_metadata_waiting_pids: [from | state.check_metadata_timer_ref]
         }}
    end
  end

  @impl true
  def handle_cast(:trigger_check_metadata, %__MODULE__{} = state) do
    Process.cancel_timer(state.check_metadata_timer_ref)
    new_ref = Process.send_after(self(), :check_cluster, 0)

    {:noreply,
     %__MODULE__{
       state
       | check_metadata_timer_ref: new_ref
     }}
  end

  # Public Interface

  def trigger_metadata_verification_sync(cluster_name) do
    GenServer.call(via_tuple({__MODULE__, cluster_name}), :trigger_check_metadata)
  end

  def trigger_metadata_verification_async(cluster_name) do
    GenServer.cast(via_tuple({__MODULE__, cluster_name}), :trigger_check_metadata)
  end

  def get_topics_partitions_metadata(cluster_name, topic, partition) do
    [{_key, broker_id, default_producer, batcher_id}] =
      cluster_name
      |> topics_partitions_metadata_table()
      |> :ets.lookup({topic, partition})

    %{
      broker_id: broker_id,
      producer_name: default_producer,
      batcher_id: batcher_id
    }
  end

  def get_broker_id(cluster_name, topic, partition) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 2)
  end

  def get_default_producer(cluster_name, topic, partition) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 3)
  end

  def get_batcher_id(cluster_name, topic, partition) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 4)
  end

  def update_batcher_id(cluster_name, topic, partition, new_batcher_id) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.update_element({topic, partition}, {4, new_batcher_id})
  end

  def get_all_topics_partitions_metadata(cluster_name) do
    cluster_name
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

  def get_producer_for_topic(cluster_name, topic),
    do: :persistent_term.get({__MODULE__, cluster_name, topic})

  # Private functions

  defp topics_partitions_metadata_table(cluster_name),
    do: :"topics_partitions_metadata.#{cluster_name}"
end
