defmodule Klife.Producer do
  use GenServer

  import Klife.ProcessRegistry

  alias Klife.Producer.Dispatcher
  alias Klife.Producer.DispatcherSupervisor
  alias Klife.Producer.Controller, as: ProducerController
  alias Klife.Connection.Controller, as: ConnController

  # TODO: Implement commented options functionality
  @producer_options [
    cluster_name: [type: :atom, required: true],
    name: [type: :atom, required: true],
    client_id: [type: :string],
    acks: [type: {:in, [:all, 0, 1]}, default: :all],
    linger_ms: [type: :non_neg_integer, default: 0],
    batch_size_bytes: [type: :non_neg_integer, default: 512_000],
    delivery_timeout_ms: [type: :non_neg_integer, default: :timer.minutes(1)],
    request_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(15)],
    retry_backoff_ms: [type: :non_neg_integer, default: :timer.seconds(1)],
    max_in_flight_requests: [type: :non_neg_integer, default: 1],
    dispatchers_count: [type: :pos_integer, default: 1],
    enable_idempotence: [type: :boolean, default: true],
    compression_type: [type: {:in, [:none, :gzip, :snappy]}, default: :none]
  ]

  defstruct (Keyword.keys(@producer_options) -- [:name]) ++ [:producer_name]

  def opts_schema(), do: @producer_options

  def start_link(args) do
    validated_args = NimbleOptions.validate!(args, @producer_options)
    producer_name = Keyword.fetch!(validated_args, :name)
    cluster_name = Keyword.fetch!(validated_args, :cluster_name)

    GenServer.start_link(__MODULE__, validated_args,
      name: via_tuple({__MODULE__, cluster_name, producer_name})
    )
  end

  def init(validated_args) do
    args_map = Map.new(validated_args)

    base = %__MODULE__{
      client_id: "klife_producer.#{args_map.cluster_name}.#{args_map.name}",
      producer_name: args_map.name
    }

    filtered_args = Map.take(args_map, Map.keys(base))
    state = Map.merge(base, filtered_args)

    :ok = init_dispatchers(state)

    {:ok, state}
  end

  def produce_sync(record, topic, partition, cluster_name, opts \\ []) do
    %{
      broker_id: broker_id,
      producer_name: default_producer,
      dispatcher_id: default_dispatcher_id
    } = ProducerController.get_topics_partitions_metadata(cluster_name, topic, partition)

    {producer_name, dispatcher_id} =
      case Keyword.get(opts, :producer) do
        nil ->
          {default_producer, default_dispatcher_id}

        other_producer ->
          {other_producer, get_dispatcher_id(cluster_name, other_producer, topic, partition)}
      end

    {:ok, delivery_timeout_ms} =
      Dispatcher.produce_sync(
        record,
        topic,
        partition,
        cluster_name,
        broker_id,
        producer_name,
        dispatcher_id
      )

    # TODO: Should we handle cluster change errors here by retrying after a cluster check?
    receive do
      {:klife_produce_sync, :ok, offset} ->
        {:ok, offset}

      {:klife_produce_sync, :error, err} ->
        {:error, err}
    after
      delivery_timeout_ms ->
        {:error, :timeout}
    end
  end

  defp init_dispatchers(%__MODULE__{} = state) do
    known_brokers = ConnController.get_known_brokers(state.cluster_name)
    dispatchers_per_broker = state.dispatchers_count
    :ok = do_init_dispatchers(state, known_brokers, dispatchers_per_broker)
    :ok = update_topic_partition_metadata(state, dispatchers_per_broker)

    :ok
  end

  defp do_init_dispatchers(state, known_brokers, dispatchers_per_broker) do
    for broker_id <- known_brokers,
        dispatcher_id <- 0..(dispatchers_per_broker - 1) do
      result =
        DynamicSupervisor.start_child(
          via_tuple({DispatcherSupervisor, state.cluster_name}),
          {Dispatcher, [{:broker_id, broker_id}, {:id, dispatcher_id}, {:producer_config, state}]}
        )

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp update_topic_partition_metadata(%__MODULE__{} = state, dispatchers_per_broker) do
    %__MODULE__{
      cluster_name: cluster_name,
      producer_name: producer_name
    } = state

    cluster_name
    |> ProducerController.get_all_topics_partitions_metadata()
    |> Enum.group_by(& &1.leader_id)
    |> Enum.map(fn {_broker_id, topics_list} ->
      topics_list
      |> Enum.with_index()
      |> Enum.map(fn {val, idx} ->
        dipsatcher_id =
          if dispatchers_per_broker > 1, do: rem(idx, dispatchers_per_broker), else: 0

        Map.put(val, :dispatcher_id, dipsatcher_id)
      end)
    end)
    |> List.flatten()
    |> Enum.each(fn %{topic_name: t_name, partition_idx: p_idx, dispatcher_id: d_id} ->
      # Used when a record is produced by a non default producer
      # in this case the proper dispatcher_id won't be present at
      # main metadata ets table, therefore we need a way to
      # find out it's value.
      put_dispatcher_id(cluster_name, producer_name, t_name, p_idx, d_id)

      if ProducerController.get_default_producer(cluster_name, t_name, p_idx) == producer_name do
        ProducerController.update_dispatcher_id(cluster_name, t_name, p_idx, d_id)
      end
    end)
  end

  defp put_dispatcher_id(cluster_name, producer_name, topic, partition, dispatcher_id) do
    :persistent_term.put(
      {__MODULE__, cluster_name, producer_name, topic, partition},
      dispatcher_id
    )
  end

  defp get_dispatcher_id(cluster_name, producer_name, topic, partition) do
    :persistent_term.get({__MODULE__, cluster_name, producer_name, topic, partition})
  end
end
