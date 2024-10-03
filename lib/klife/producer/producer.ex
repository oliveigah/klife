defmodule Klife.Producer do
  @doc false
  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1, registry_lookup: 1]

  alias Klife.Record

  alias Klife.Producer.Batcher
  alias Klife.Producer.Controller, as: ProducerController
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController

  alias KlifeProtocol.Messages, as: M

  @producer_options [
    name: [
      type: :atom,
      required: true,
      doc: "Producer name. Can be used as an option on the producer api"
    ],
    client_id: [
      type: :string,
      doc:
        "String used on all requests for the client. If not provided the following string is used: \"klife_producer.{client_name}.{producer_name}\""
    ],
    acks: [
      type: {:in, [:all, 0, 1]},
      type_doc: "`:all`, 0 or 1",
      default: :all,
      doc:
        "The number of broker's acks the producer requires before considering a request complete. `:all` means all ISR(in sync replicas)"
    ],
    linger_ms: [
      type: :non_neg_integer,
      default: 0,
      doc:
        "The maximum time to wait for additional messages before sending a batch to the broker."
    ],
    batch_size_bytes: [
      type: :non_neg_integer,
      default: 512_000,
      doc:
        "The maximum size of the batch of messages that the producer will send to the broker in a single request."
    ],
    delivery_timeout_ms: [
      type: :non_neg_integer,
      default: :timer.minutes(1),
      doc:
        "The maximum amount of time the producer will retry to deliver a message before timing out and failing the send."
    ],
    request_timeout_ms: [
      type: :non_neg_integer,
      default: :timer.seconds(15),
      doc:
        "The maximum amount of time the producer will wait for a broker response to a request before considering it as failed."
    ],
    retry_backoff_ms: [
      type: :non_neg_integer,
      default: :timer.seconds(1),
      doc:
        "The amount of time that the producer waits before retrying a failed request to the broker."
    ],
    max_in_flight_requests: [
      type: :non_neg_integer,
      default: 1,
      doc:
        "The maximum number of unacknowledged requests per broker the producer will send before waiting for acknowledgments."
    ],
    batchers_count: [
      type: :pos_integer,
      default: 1,
      doc:
        "The number of batchers per broker the producer will start. See `Batchers Count` session for more details."
    ],
    enable_idempotence: [
      type: :boolean,
      default: true,
      doc:
        "Indicates if the producer will use kafka idempotency capabilities for exactly once semantics."
    ],
    compression_type: [
      type: {:in, [:none, :gzip, :snappy]},
      default: :none,
      type_doc: "`:none`, `:gzip` or `:snappy`",
      doc:
        "The compression algorithm to be used for compressing messages before they are sent to the broker."
    ]
  ]

  @moduledoc """
  Defines a producer.

  ## Configurations

  #{NimbleOptions.docs(@producer_options)}
  """

  defstruct Keyword.keys(@producer_options) ++
              [
                :producer_id,
                :producer_epoch,
                :epochs,
                :coordinator_id,
                :client_name,
                :txn_id,
                :txn_timeout_ms
              ]

  @doc false
  def get_opts(), do: @producer_options

  @doc false
  def start_link(args) do
    producer_name = args.name
    client_name = args.client_name

    GenServer.start_link(__MODULE__, args,
      name: via_tuple(get_process_name(client_name, producer_name))
    )
  end

  defp get_process_name(client, producer), do: {__MODULE__, client, producer}

  @doc false
  def init(validated_args) do
    args_map = Map.take(validated_args, Map.keys(%__MODULE__{}))

    base = %__MODULE__{
      client_id: "klife_producer.#{args_map.client_name}.#{args_map.name}",
      epochs: %{},
      # This is the only args that may not exist because
      # it is filtered out on non txn producers
      # in order to prevent confusion on the configuration
      txn_timeout_ms: Map.get(args_map, :txn_timeout_ms, 0)
    }

    state =
      base
      |> Map.merge(args_map)
      |> set_producer_id()

    :ok = handle_batchers(state)

    {:ok, state}
  end

  @doc false
  def new_epoch(client_name, producer_name, topic, partition) do
    {__MODULE__, client_name, producer_name}
    |> via_tuple()
    |> GenServer.call({:new_epoch, topic, partition})
  end

  @doc false
  def get_txn_pool_data(client_name, producer_name) do
    {__MODULE__, client_name, producer_name}
    |> via_tuple()
    |> GenServer.call(:get_txn_pool_data)
  end

  @doc false
  def get_pid(client_name, producer_name) do
    get_process_name(client_name, producer_name)
    |> registry_lookup()
    |> List.first()
  end

  @doc false
  def handle_info(:handle_change, %__MODULE__{} = state) do
    if maybe_find_coordinator(state) != state.coordinator_id do
      # If the coordinator has changed the easiest thing to do is
      # to restart everything through the supervisor.
      # This may only occur to transactional producer when
      # its previous coordinator is not available anymore
      # non transactional producers always have `:any` as
      # coordinator and therefore will not stop
      {:stop, :handle_change, state}
    else
      :ok = handle_batchers(state)
      {:noreply, state}
    end
  end

  @doc false
  def handle_call(:get_txn_pool_data, _from, %__MODULE__{txn_id: nil} = state) do
    {:reply, {:error, :not_txn_producer}, state}
  end

  @doc false
  def handle_call(:get_txn_pool_data, _from, %__MODULE__{} = state) do
    data = %{
      producer_id: state.producer_id,
      producer_epoch: state.producer_epoch,
      coordinator_id: state.coordinator_id,
      txn_id: state.txn_id,
      client_id: state.client_id
    }

    {:reply, {:ok, data}, state}
  end

  @doc false
  def handle_call(
        {:new_epoch, topic, partition},
        {called_pid, _tag},
        %__MODULE__{epochs: epochs} = state
      ) do
    case Map.get(epochs, {topic, partition}) do
      nil ->
        epoch = state.producer_epoch
        new_state = %{state | epochs: Map.put(epochs, {topic, partition}, {epoch, called_pid})}
        {:reply, epoch, new_state}

      {curr_epoch, last_known_pid} ->
        epoch = curr_epoch + 1
        new_state = %{state | epochs: Map.put(epochs, {topic, partition}, {epoch, called_pid})}

        if last_known_pid != called_pid do
          send(last_known_pid, {:remove_topic_partition, topic, partition})
        end

        {:reply, epoch, new_state}
    end
  end

  defp set_producer_id(%__MODULE__{enable_idempotence: false} = state),
    do: %{state | coordinator_id: maybe_find_coordinator(state)}

  defp set_producer_id(%__MODULE__{enable_idempotence: true} = state) do
    broker = maybe_find_coordinator(state)

    content = %{
      transactional_id: state.txn_id,
      transaction_timeout_ms: state.txn_timeout_ms
    }

    fun = fn ->
      case Broker.send_message(M.InitProducerId, state.client_name, broker, content) do
        {:ok, %{content: %{error_code: 0, producer_id: producer_id, producer_epoch: p_epoch}}} ->
          {producer_id, p_epoch}

        _data ->
          :retry
      end
    end

    {producer_id, p_epoch} = with_timeout(:timer.seconds(30), fun)

    %__MODULE__{
      state
      | producer_id: producer_id,
        producer_epoch: p_epoch,
        coordinator_id: broker
    }
  end

  defp maybe_find_coordinator(%__MODULE__{txn_id: nil}), do: :any

  defp maybe_find_coordinator(%__MODULE__{txn_id: txn_id} = state) do
    content = %{
      key_type: 1,
      coordinator_keys: [txn_id]
    }

    fun = fn ->
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content) do
        {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: broker_id}]}}} ->
          broker_id

        _data ->
          :retry
      end
    end

    with_timeout(:timer.seconds(30), fun)
  end

  @doc false
  def produce([%Record{} | _] = records, client_name, opts) do
    opt_producer = Keyword.get(opts, :producer)
    callback_pid = self()

    delivery_timeout_ms =
      records
      |> Enum.group_by(fn r -> {r.topic, r.partition} end)
      |> Enum.map(fn {{t, p}, recs} ->
        %{
          broker_id: broker_id,
          producer_name: default_producer,
          batcher_id: default_batcher_id
        } = ProducerController.get_topics_partitions_metadata(client_name, t, p)

        new_key =
          if opt_producer,
            do: {broker_id, opt_producer, get_batcher_id(client_name, opt_producer, t, p)},
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
            client_name,
            broker_id,
            producer,
            batcher_id,
            callback_pid
          )

        if acc < delivery_timeout_ms, do: delivery_timeout_ms, else: acc
      end)

    max_resps = List.last(records).__batch_index
    responses = wait_produce_response(delivery_timeout_ms, max_resps)

    records
    |> Enum.map(fn %Record{} = rec ->
      case Map.get(responses, rec.__batch_index) do
        {:ok, offset} ->
          {:ok, %{rec | offset: offset}}

        {:error, ec} ->
          {:error, %{rec | error_code: ec}}
      end
    end)
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

  defp handle_batchers(%__MODULE__{} = state) do
    known_brokers = ConnController.get_known_brokers(state.client_name)
    batchers_per_broker = state.batchers_count
    :ok = init_batchers(state, known_brokers, batchers_per_broker)
    :ok = update_topic_partition_metadata(state, batchers_per_broker)

    :ok
  end

  defp init_batchers(state, known_brokers, batchers_per_broker) do
    for broker_id <- known_brokers,
        batcher_id <- 0..(batchers_per_broker - 1) do
      result =
        Batcher.start_link([
          {:broker_id, broker_id},
          {:id, batcher_id},
          {:producer_config, state}
        ])

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp update_topic_partition_metadata(%__MODULE__{} = state, batchers_per_broker) do
    %__MODULE__{
      client_name: client_name,
      name: producer_name
    } = state

    client_name
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
      put_batcher_id(client_name, producer_name, t_name, p_idx, b_id)

      if ProducerController.get_default_producer(client_name, t_name, p_idx) == producer_name do
        ProducerController.update_batcher_id(client_name, t_name, p_idx, b_id)
      end
    end)
  end

  defp put_batcher_id(client_name, producer_name, topic, partition, batcher_id) do
    :persistent_term.put(
      {__MODULE__, client_name, producer_name, topic, partition},
      batcher_id
    )
  end

  defp get_batcher_id(client_name, producer_name, topic, partition) do
    :persistent_term.get({__MODULE__, client_name, producer_name, topic, partition})
  end

  defp with_timeout(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_with_timeout(deadline, fun)
  end

  defp do_with_timeout(deadline, fun) do
    if System.monotonic_time(:millisecond) < deadline do
      case fun.() do
        :retry ->
          Process.sleep(Enum.random(50..150))
          do_with_timeout(deadline, fun)

        val ->
          val
      end
    else
      raise "timeout while waiting for broker response"
    end
  end
end
