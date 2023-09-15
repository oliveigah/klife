defmodule Klife.Producer.Controller do
  use GenServer

  import Klife.ProcessRegistry

  require Logger
  alias KlifeProtocol.Messages
  alias Klife.Connection.Broker
  alias Klife.Utils
  alias Klife.Producer.ProducerSupervisor

  alias Klife.Producer

  @default_producer %{name: :default_producer}

  defstruct [:cluster_name, :producers, :topics]

  def start_link(args) do
    cluster_name = Keyword.fetch!(args, :cluster_name)
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(args) do
    cluster_name = Keyword.fetch!(args, :cluster_name)
    topics_list = Keyword.get(args, :topics, [])

    state = %__MODULE__{
      cluster_name: cluster_name,
      producers: [@default_producer] ++ Keyword.get(args, :producers, []),
      topics: Enum.filter(topics_list, &Map.get(&1, :enable_produce, true))
    }

    :persistent_term.put(
      {:producer_topics_partitions, cluster_name},
      String.to_atom("producer_topics_partitions.#{cluster_name}")
    )

    :ets.new(get_producer_topics_table(cluster_name), [:bag, :public, :named_table])

    Enum.each(topics_list, fn t ->
      :persistent_term.put(
        {__MODULE__, cluster_name, t.name},
        Map.get(t, :producer, @default_producer.name)
      )
    end)

    Utils.wait_connection!(cluster_name)

    send(self(), :check_metadata)

    {:ok, state}
  end

  # TODO: Rethink this code considering brokers leaving the cluster (should stop the process)
  # The connection controller already does this for the connection processes but
  # I think it could be better.
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
  def handle_info(:check_metadata, %__MODULE__{} = state) do
    content = %{
      topics: Enum.map(state.topics, fn t -> %{name: t.name} end)
    }

    {:ok, %{content: resp}} =
      Broker.send_sync(Messages.Metadata, state.cluster_name, :controller, content)

    for topic <- Enum.filter(resp.topics, &(&1.error_code == 0)),
        producer_name = get_producer_for_topic(state.cluster_name, topic.name),
        partition <- topic.partitions do
      :persistent_term.put(
        {__MODULE__, state.cluster_name, topic.name, partition.partition_index},
        partition.leader_id
      )

      state.cluster_name
      |> get_producer_topics_table()
      |> :ets.insert({producer_name, {topic.name, partition.partition_index}})
    end

    if Enum.any?(resp.topics, &(&1.error_code != 0)) do
      Process.send_after(self(), :check_metadata, :timer.seconds(5))
    else
      send(self(), :init_producers)
    end

    {:noreply, state}
  end

  # Public Interface
  def get_broker_id(cluster_name, topic, partition) do
    :persistent_term.get({__MODULE__, cluster_name, topic, partition})
  end

  def get_topics_and_partitions_for_producer(cluster_name, producer_name) do
    cluster_name
    |> get_producer_topics_table()
    |> :ets.lookup_element(producer_name, 2)
  end

  # Private functions

  defp get_producer_topics_table(cluster_name),
    do: :persistent_term.get({:producer_topics_partitions, cluster_name})

  defp get_producer_for_topic(cluster_name, topic),
    do: :persistent_term.get({__MODULE__, cluster_name, topic})
end
