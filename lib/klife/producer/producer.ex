defmodule Klife.Producer do
  @doc false
  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1, registry_lookup: 1]

  require Logger

  alias Klife.Record

  alias Klife.Producer.Batcher
  alias Klife.Producer.Controller, as: ProducerController
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Connection.MessageVersions, as: MV

  alias Klife.Helpers

  alias KlifeProtocol.Messages, as: M

  @producer_options [
    name: [
      type: {:or, [:atom, :string]},
      required: true,
      doc:
        "Producer name. Must be unique per client. Can be used as an option on the producer api"
    ],
    client_id: [
      type: :string,
      doc:
        "String used on all requests. If not provided the following string is used: \"klife_producer.{client_name}.{producer_name}\""
    ],
    acks: [
      type: {:in, [:all, 1]},
      type_doc: "`:all`, 1",
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

  ## Client configurations

  #{NimbleOptions.docs(@producer_options)}

  ## Interacting with producers

  When configuring `Klife.Client`, users can specify a list of producers to be initialized for sending records to the Kafka cluster.

  Once configured, users can interact with these producers through the `Klife.Client` producer API.

  ## How many producers?

  By default, all records are produced using a single default producer configured with standard settings, maximizing batch efficiency.

  There are two main reasons to consider using multiple producers:

  - Different configurations for specific topics: Some topics may require unique settings.
  In this case, you can assign topics with similar configuration needs to the same producer.

  - Fault isolation: Each producer has an independent queue of messages.
  Using multiple producers can help isolate issues in one topic from affecting the performance of others.

  Let's dive in an example of fault isolation. Consider this scenario:

  ```md
  - A producer batches messages for topics A and B into a single request to the broker leader.
  - For some reason, topic B is temporarily unavailable and fails, but topic A remains functional.
  - The producer is configured with in_flight_requests = 1 and delivery_timeout_ms = 1 minute.
  - This means the producer will retry sending records for topic B for up to one minute.
  - Because in_flight_requests is set to 1, all other records, including those for topic A, must wait
  until retries for topic B are exhausted.
  ```
  In this situation, issues with one topic can delay other topics handled by the same producer,
  as the retry mechanism occupies the single in-flight request slot.

  If this scenario presents a potential issue for your use case, consider creating multiple producers
  and dedicating some of them to critical topics. However, note that this approach may slightly reduce
  batch efficiency in normal operation to improve resilience in specific failure scenarios, which may
  be infrequent.

  ## Order guarantees

  Kafka guarantees message order only within the same topic and partition so this is the maximum
  level of ordering that the producer can provide as well.

  However, certain scenarios can lead to records being produced to Kafka out of order. In this context,
  "out of order" means the following:

  ```markdown
  1. `rec1` and `rec2` are produced to the same topic and partition.
  2. The user calls produce(rec1) before calling produce(rec2).
  3. Both produce calls complete successfully.
  4. `rec1` is stored in the broker after `rec2`, resulting in `rec1.offset > rec2.offset`.
  ```

  In this case, rec1 and rec2 are considered "out of order."

  The ordering behavior for producers depends on their configuration:

  - Records produced by different producers (even if targeting the same topic and partition) may
  be out of order since each producer operates independently and in parallel.
  - Records produced by a producer with `max_in_flight_requests` > 1 and `enable_idempotence` set to false
  may be out of order due to network failures and retries.
  - Any records produced by a producer with `max_in_flight_requests` = 1 have guaranteed ordering.
  - Any records produced by a producer with `enable_idempotence` = true have guaranteed ordering.

  ## Dynamic batching

  Klife’s producer uses dynamic batching, which automatically accumulates records that cannot be sent
  immediately due to in_flight_request limitations. As a result, it is rarely necessary
  to set linger_ms to a value greater than zero.

  Typically, increasing `linger_ms` can improve batching efficiency, which benefits high-throughput topics.
  However, if your topic already has high throughput, dynamic batching will likely handle batching
  effectively without adjusting `linger_ms`.

  Increasing linger_ms may be helpful only if you set a very high value for in_flight_request or
  if you need to limit request rates to the broker for specific reasons.

  ## Batchers Count

  Each Klife producer starts a configurable number of batchers for each broker in the Kafka cluster.
  Topics and partitions with the same leader are managed by the same batcher.

  By default, Klife initializes only one batcher per broker, which optimizes batch efficiency but
  may underutilize CPU resources on high-core systems.

  Consider the following setup:

  - A Kafka cluster with 3 brokers
  - An application running on a machine with 64 cores
  - `batchers_count` = 1

  In this scenario, the application could encounter a performance bottleneck due to having only
  three batchers handling all record production requests. Increasing parallelism by adjusting `batcher_count`
  can help resolve this issue.

  For instance, increasing batcher_count from 1 to 5 would create 15 batchers (5 per broker), potentially improving
  parallelism and CPU utilization.

  #### Some caveats:

  - The same topic and partition are always handled by the same batcher.
  - Higher batcher counts reduce batch efficiency, which may lower overall throughput.
  - The ideal setting may vary depending on your workload, so it's best to measure and
  adjust batcher_count based on your specific performance needs.

  ## Topic default producer

  Each topic has a designated default producer, which is used by the producer client API
  for regular produce calls. While this default producer can be overridden with options
  in the client API, be mindful that doing so may affect order guarantees.

  ## Client default producer

  If a produce call is made to a topic without a predefined default producer,
  the client default producer is used. The client default producer can be configured as part
  of the overall `Klife.Client` setup. Refer to `Klife.Client` documentation for more details.

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
    if ConnController.disabled_feature?(state.client_name, :producer_idempotence) do
      raise """
        Producer idempotence feature is disabled but producer #{state.name} has idempotence enabled.
        Please check for API versions problems or disable idempotence on this producer.
      """
    end

    broker = maybe_find_coordinator(state)

    content = %{
      transactional_id: state.txn_id,
      transaction_timeout_ms: state.txn_timeout_ms
    }

    fun = fn ->
      case Broker.send_message(M.InitProducerId, state.client_name, broker, content) do
        {:ok, %{content: %{error_code: 0, producer_id: producer_id, producer_epoch: p_epoch}}} ->
          {producer_id, p_epoch}

        {:ok, %{content: %{error_code: ec}}} ->
          Logger.error(
            "Error code #{ec} returned from broker for client #{inspect(state.client_name)} on #{inspect(M.InitProducerId)} call"
          )

          :retry

        _ ->
          :retry
      end
    end

    {producer_id, p_epoch} = Helpers.with_timeout!(fun, :timer.seconds(30))

    %__MODULE__{
      state
      | producer_id: producer_id,
        producer_epoch: p_epoch,
        coordinator_id: broker
    }
  end

  defp maybe_find_coordinator(%__MODULE__{txn_id: nil}), do: :any

  defp maybe_find_coordinator(%__MODULE__{txn_id: txn_id} = state) do
    content =
      if MV.get(state.client_name, M.FindCoordinator) <= 3 do
        %{
          key_type: 1,
          key: txn_id
        }
      else
        %{
          key_type: 1,
          coordinator_keys: [txn_id]
        }
      end

    fun = fn ->
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content) do
        # vsn <= 3
        {:ok, %{content: %{error_code: 0, node_id: broker_id}}} ->
          broker_id

        {:ok, %{content: %{error_code: ec}}} ->
          Logger.error(
            "Error code #{ec} returned from broker for client #{inspect(state.client_name)} on #{inspect(M.FindCoordinator)} call"
          )

          :retry

        # vsn > 3
        {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: broker_id}]}}} ->
          broker_id

        {:ok, %{content: %{coordinators: [%{error_code: ec}]}}} ->
          Logger.error(
            "Error code #{ec} returned from broker for client #{inspect(state.client_name)} on #{inspect(M.FindCoordinator)} call"
          )

          :retry

        _data ->
          :retry
      end
    end

    Helpers.with_timeout!(fun, :timer.seconds(30))
  end

  @doc false
  def produce([%Record{} | _] = records, client_name, opts) do
    opt_producer = Keyword.get(opts, :producer)
    callback_pid = self()

    delivery_timeout_ms =
      records
      |> group_records_by_batcher(client_name, opt_producer)
      |> Enum.reduce(0, fn {key, recs}, acc ->
        {broker_id, producer, batcher_id} = key
        recs = Enum.map(recs, fn %Record{} = rec -> %Record{rec | __callback: callback_pid} end)

        {:ok, delivery_timeout_ms} =
          Batcher.produce(
            recs,
            client_name,
            broker_id,
            producer,
            batcher_id
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

  def produce_async([%Record{} | _] = records, client_name, opts) do
    opt_producer = Keyword.get(opts, :producer)
    callback = Keyword.get(opts, :callback)

    records
    |> group_records_by_batcher(client_name, opt_producer)
    |> Enum.each(fn {key, recs} ->
      {broker_id, producer, batcher_id} = key
      recs = Enum.map(recs, fn %Record{} = rec -> %Record{rec | __callback: callback} end)

      :ok =
        Batcher.produce_async(
          recs,
          client_name,
          broker_id,
          producer,
          batcher_id
        )
    end)
  end

  defp group_records_by_batcher(records, client_name, opt_producer) do
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
          {:producer_config, state},
          {:batcher_config, build_batcher_config(state)}
        ])

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp build_batcher_config(%__MODULE__{} = state) do
    [
      {:batch_wait_time_ms, state.linger_ms},
      {:max_in_flight, state.max_in_flight_requests},
      {:batch_max_size, state.batch_size_bytes},
      {:batch_max_count, :infinity}
    ]
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
end
