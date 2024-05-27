defmodule Klife.Producer do
  use GenServer

  import Klife.ProcessRegistry

  alias Klife.Record

  alias Klife.Producer.Batcher
  alias Klife.Producer.BatcherSupervisor
  alias Klife.Producer.Controller, as: ProducerController
  alias Klife.Connection.Controller, as: ConnController

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
    batchers_count: [type: :pos_integer, default: 1],
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

    :ok = do_handle_batchers(state)

    {:ok, state}
  end

  def handle_info(:handle_batchers, %__MODULE__{} = state) do
    :ok = do_handle_batchers(state)
    {:noreply, state}
  end

  def produce([%Record{} | _] = records, cluster_name, opts) do
    opt_producer = Keyword.get(opts, :producer)
    callback_pid = if Keyword.get(opts, :async, false), do: nil, else: self()

    delivery_timeout_ms =
      records
      |> Enum.group_by(fn r -> {r.topic, r.partition} end)
      |> Enum.map(fn {{t, p}, recs} ->
        %{
          broker_id: broker_id,
          producer_name: default_producer,
          batcher_id: default_batcher_id
        } = ProducerController.get_topics_partitions_metadata(cluster_name, t, p)

        new_key =
          if opt_producer,
            do: {broker_id, opt_producer, get_batcher_id(cluster_name, opt_producer, t, p)},
            else: {broker_id, default_producer, default_batcher_id}

        {new_key, recs}
      end)
      |> Enum.group_by(fn {key, _recs} -> key end, fn {_key, recs} -> recs end)
      |> Enum.map(fn {k, v} -> {k, List.flatten(v)} end)
      |> Enum.reduce(0, fn {key, recs}, acc ->
        {broker_id, producer, batcher_id} = key

        {:ok, delivery_timeout_ms} =
          Batcher.produce(
            recs,
            cluster_name,
            broker_id,
            producer,
            batcher_id,
            callback_pid
          )

        if acc < delivery_timeout_ms, do: delivery_timeout_ms, else: acc
      end)

    if callback_pid do
      max_resps = List.last(records).__batch_index
      responses = wait_produce_response(delivery_timeout_ms, max_resps)

      records
      |> Enum.map(fn %Record{} = rec ->
        case Map.get(responses, rec.__batch_index) do
          {:ok, offset} ->
            {:ok, %{rec | offset: offset}}

          err ->
            err
        end
      end)
      |> case do
        [resp] -> resp
        resps -> resps
      end
    else
      :ok
    end
  end

  defp wait_produce_response(timeout_ms, max_resps) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_produce_response(deadline, max_resps, 0, %{})
  end

  defp do_wait_produce_response(_deadline, max_resps, max_resps, resps), do: resps

  defp do_wait_produce_response(deadline, max_resps, counter, resps) do
    now = System.monotonic_time(:millisecond)

    if deadline > now do
      receive do
        {:klife_produce, resp, batch_idx} ->
          new_resps = Map.put(resps, batch_idx, resp)
          new_counter = counter + 1
          do_wait_produce_response(deadline, max_resps, new_counter, new_resps)
      after
        deadline - now ->
          do_wait_produce_response(deadline, max_resps, counter, resps)
      end
    else
      new_resps =
        Enum.reduce(1..max_resps, resps, fn idx, acc ->
          Map.put_new(acc, idx, {:error, :timeout})
        end)

      do_wait_produce_response(deadline, max_resps, max_resps, new_resps)
    end
  end

  defp do_handle_batchers(%__MODULE__{} = state) do
    known_brokers = ConnController.get_known_brokers(state.cluster_name)
    batchers_per_broker = state.batchers_count
    :ok = init_batchers(state, known_brokers, batchers_per_broker)
    :ok = update_topic_partition_metadata(state, batchers_per_broker)

    :ok
  end

  defp init_batchers(state, known_brokers, batchers_per_broker) do
    for broker_id <- known_brokers,
        batcher_id <- 0..(batchers_per_broker - 1) do
      result =
        DynamicSupervisor.start_child(
          via_tuple({BatcherSupervisor, state.cluster_name}),
          {Batcher, [{:broker_id, broker_id}, {:id, batcher_id}, {:producer_config, state}]}
        )

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp update_topic_partition_metadata(%__MODULE__{} = state, batchers_per_broker) do
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
          if batchers_per_broker > 1, do: rem(idx, batchers_per_broker), else: 0

        Map.put(val, :batcher_id, dipsatcher_id)
      end)
    end)
    |> List.flatten()
    |> Enum.each(fn %{topic_name: t_name, partition_idx: p_idx, batcher_id: b_id} ->
      # Used when a record is produced by a non default producer
      # in this case the proper batcher_id won't be present at
      # main metadata ets table, therefore we need a way to
      # find out it's value.
      put_batcher_id(cluster_name, producer_name, t_name, p_idx, b_id)

      if ProducerController.get_default_producer(cluster_name, t_name, p_idx) == producer_name do
        ProducerController.update_batcher_id(cluster_name, t_name, p_idx, b_id)
      end
    end)
  end

  defp put_batcher_id(cluster_name, producer_name, topic, partition, batcher_id) do
    :persistent_term.put(
      {__MODULE__, cluster_name, producer_name, topic, partition},
      batcher_id
    )
  end

  defp get_batcher_id(cluster_name, producer_name, topic, partition) do
    :persistent_term.get({__MODULE__, cluster_name, producer_name, topic, partition})
  end
end
