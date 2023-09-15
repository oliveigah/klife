defmodule Klife.Producer do
  use GenServer

  import Klife.ProcessRegistry

  alias Klife.Producer.Dispatcher
  alias Klife.Producer.DispatcherSupervisor
  alias Klife.Producer.Controller, as: ProducerController
  alias Klife.Connection.Controller, as: ConnController

  @producer_options [
    cluster_name: [type: :atom, required: true],
    name: [type: :atom, required: true],
    client_id: [type: :string],
    acks: [type: {:in, [:all, 0, 1]}, default: :all],
    linger_ms: [type: :non_neg_integer, default: 0],
    batch_size_bytes: [type: :non_neg_integer, default: 32_000],
    delivery_timeout_ms: [type: :non_neg_integer, default: :timer.minutes(1)],
    request_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(15)],
    retry_backoff_ms: [type: :non_neg_integer, default: :timer.seconds(1)],
    max_retries: [type: :timeout, default: :infinity],
    compression_type: [type: {:in, [:none, :gzip, :snappy]}, default: :none],
    max_inflight_requests: [type: :non_neg_integer, default: 1],
    enable_idempotence: [type: :boolean, default: true]
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

    state.cluster_name
    |> ProducerController.get_topics_and_partitions_for_producer(state.producer_name)
    |> Enum.map(fn {topic, _partition} -> topic end)
    |> Enum.uniq()
    |> Enum.each(fn topic ->
      :persistent_term.put({__MODULE__, state.cluster_name, topic}, state)
    end)

    :ok = init_dispatchers(state)

    {:ok, state}
  end

  def produce_sync(record, topic, partition, cluster_name) do
    broker_id = ProducerController.get_broker_id(cluster_name, topic, partition)
    pconfig = get_producer_for_topic(cluster_name, topic)
    Dispatcher.produce_sync(record, topic, partition, pconfig, broker_id, cluster_name)
  end

  defp init_dispatchers(%__MODULE__{linger_ms: 0} = state) do
    state.cluster_name
    |> ProducerController.get_topics_and_partitions_for_producer(state.producer_name)
    |> Enum.each(fn {topic, partition} ->
      broker_id = ProducerController.get_broker_id(state.cluster_name, topic, partition)

      result =
        DynamicSupervisor.start_child(
          via_tuple({DispatcherSupervisor, state.cluster_name}),
          {Dispatcher,
           [
             {:broker_id, broker_id},
             {:producer_config, state},
             {:topic_name, topic},
             {:topic_partition, partition}
           ]}
        )

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)
  end

  defp init_dispatchers(%__MODULE__{linger_ms: linger_ms} = state) when linger_ms > 0 do
    state.cluster_name
    |> ConnController.get_known_brokers()
    |> Enum.each(fn broker_id ->
      result =
        DynamicSupervisor.start_child(
          via_tuple({DispatcherSupervisor, state.cluster_name}),
          {Dispatcher, [{:broker_id, broker_id}, {:producer_config, state}]}
        )

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)
  end

  defp get_producer_for_topic(cluster_name, topic),
    do: :persistent_term.get({__MODULE__, cluster_name, topic})
end
