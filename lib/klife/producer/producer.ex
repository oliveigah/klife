defmodule Klife.Producer do
  @doc false
  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1, registry_lookup: 1]

  require Logger

  alias Klife.Record

  alias Klife.Producer.Batcher
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Connection.MessageVersions, as: MV

  alias Klife.Helpers

  alias KlifeProtocol.Messages, as: M

  alias Klife.MetadataCache

  alias Klife.PubSub

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
      default: :timer.seconds(30),
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
        "The number of batchers per broker the producer will start. See `Batchers Count` section for more details."
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
    ],
    connection: [
      type: :atom,
      doc:
        "Name of the client connection used for every request of this producer. Defaults to the client's `default_connection`. See [Connections](guides/examples/client_configuration.md#connections)."
    ]
  ]

  @moduledoc """
  Defines a producer.

  A producer is responsible for batching and sending records to Kafka brokers. Klife groups
  all topics and partitions that share the same broker leader into the same producer batcher,
  so most requests are sent as a single batched TCP call per broker, maximizing network efficiency.

  Producers are configured as part of `Klife.Client` setup and interacted with through the client's
  produce API.

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
  - Records produced by a producer with `max_in_flight_requests` > 1 and `enable_idempotence` set to `false`
  may be out of order due to network failures and retries.
  - Any records produced by a producer with `max_in_flight_requests` = 1 have guaranteed ordering.
  - Any records produced by a producer with `enable_idempotence` = `true` have guaranteed ordering.

  These guarantees have one exception, during partition leader changes. When a partition's leader
  changes, the producer hands the partition's pending records from the old leader's batcher to the
  new one's, keeping their order. A produce call that reaches the old batcher after the handoff is
  sent on to the new one, and may be overtaken by a later call that went straight to the new one.
  This only affects calls that overlap in time, like `produce_async` calls or concurrent `produce`
  calls: if `produce(rec1)` returns before `produce(rec2)` is called, `rec1` is stored first.

  ## Dynamic batching

  Klife’s producer uses dynamic batching, which automatically accumulates records that cannot be sent
  immediately due to `max_in_flight_requests` limitations. As a result, it is rarely necessary
  to set `linger_ms` to a value greater than zero.

  Typically, increasing `linger_ms` can improve batching efficiency, which benefits high-throughput topics.
  However, if your topic already has high throughput, dynamic batching will likely handle batching
  effectively without adjusting `linger_ms`.

  Increasing `linger_ms` may be helpful only if you set a very high value for `max_in_flight_requests` or
  if you need to limit request rates to the broker for specific reasons.

  ## Batchers Count

  Each Klife producer starts a configurable number of batchers for each broker in the Kafka cluster.
  Each topic and partition is managed by one of its leader's batchers, picked from the topic and
  partition alone, so it keeps its batcher until its leader changes.

  By default, Klife initializes only one batcher per broker, which optimizes batch efficiency but
  may underutilize CPU resources on high-core systems.

  Consider the following setup:

  - A Kafka cluster with 3 brokers
  - An application running on a machine with 64 cores
  - `batchers_count` = 1

  In this scenario, the application could encounter a performance bottleneck due to having only
  three batchers handling all record production requests. Increasing parallelism by adjusting `batchers_count`
  can help resolve this issue.

  For instance, increasing `batchers_count` from 1 to 5 would create 15 batchers (5 per broker), potentially improving
  parallelism and CPU utilization.

  #### Some caveats:

  - The same topic and partition are always handled by the same batcher.
  - Higher batcher counts reduce batch efficiency, which may lower overall throughput.
  - The ideal setting may vary depending on your workload, so it's best to measure and
  adjust `batchers_count` based on your specific performance needs.

  ## Retries and error handling

  When a produce request fails, the producer automatically retries using the following flow:

  1. A batch is dispatched to the broker. The broker must respond within `request_timeout_ms`
  2. If the request times out or returns a retryable error, the producer waits `retry_backoff_ms` before retrying.
  3. Steps 1-2 repeat until the total time since the original send exceeds `delivery_timeout_ms`, at which point remaining records fail with a `:timeout` error.

  Some broker errors are non-retryable. In those cases the affected records are immediately discarded with the corresponding error code, without retrying.

  When a partition's leader changes, its pending records, including those being retried, are handed
  to a batcher of the new leader and go on from there, within the same `delivery_timeout_ms`.
  The handoff keeps the partition's producer epoch, so transactions are not affected by the move.
  If the old leader's batcher does not hand them over within `request_timeout_ms`, they fail with
  `:handoff_expired`, and the partition goes on with a new epoch.

  Since retries happen at the dispatcher level, they interact with `max_in_flight_requests`:
  a retry occupies an in-flight slot, which may delay other batches waiting to be sent. See the
  "How many producers?" section for strategies to isolate critical topics from this behavior.

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
                :txn_timeout_ms,
                :batcher_supervisor,
                :latest_metadata_sync_ts,
                # Each partition's producer leader, the batcher that owns
                # it, published with producer_leader_map_version
                :producer_leader_map,
                :producer_leader_map_version,
                :handoffs,
                :handoff_tps,
                :reconcile_timer
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
  @impl true
  def init(validated_args) do
    args_map = Map.take(validated_args, Map.keys(%__MODULE__{}))
    client = args_map.client_name

    connection =
      Map.get(args_map, :connection) || ConnController.get_default_connection(client)

    :ok = ConnController.validate_connection!(client, connection)
    args_map = Map.put(args_map, :connection, connection)
    {:ok, batcher_sup_pid} = DynamicSupervisor.start_link([])

    # Versions keep growing across restarts, so batchers never take a map
    # read before a restart for a newer one
    {map_version, _map} = get_producer_leader_map(args_map.client_name, args_map.name)

    base = %__MODULE__{
      client_id: "klife_producer.#{args_map.client_name}.#{args_map.name}",
      epochs: %{},
      producer_leader_map: %{},
      producer_leader_map_version: map_version,
      handoffs: %{},
      handoff_tps: %{},
      # This is the only args that may not exist because
      # it is filtered out on non txn producers
      # in order to prevent confusion on the configuration
      txn_timeout_ms: Map.get(args_map, :txn_timeout_ms, 0),
      batcher_supervisor: batcher_sup_pid
    }

    state =
      base
      |> Map.merge(args_map)
      |> set_producer_id()

    :ok = PubSub.subscribe({:metadata_updated, args_map.client_name})
    # Although tecnicaly we could just listen to metadata changes
    # cluster changes happens faster than metadata ones and in
    # order to be able to react faster we must also subscribe to
    # cluster change events.
    :ok = PubSub.subscribe({:cluster_change, args_map.client_name})

    {:ok, handle_batchers(state)}
  end

  @doc false
  def new_epoch(client_name, producer_name, topic, partition) do
    {__MODULE__, client_name, producer_name}
    |> via_tuple()
    |> GenServer.call({:new_epoch, topic, partition})
  end

  @doc false
  def bump_epoch(client_name, producer_name, topic, partition) do
    {__MODULE__, client_name, producer_name}
    |> via_tuple()
    |> GenServer.call({:bump_epoch, topic, partition})
  end

  @doc false
  def handoff_prepared(client_name, producer_name, ref) do
    {__MODULE__, client_name, producer_name}
    |> via_tuple()
    |> GenServer.cast({:handoff_prepared, ref})
  end

  @doc false
  def claim_handoff(client_name, producer_name, ref, claims) do
    {__MODULE__, client_name, producer_name}
    |> via_tuple()
    |> GenServer.call({:claim_handoff, ref, claims})
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

  defp sync_metadata_cache(client, producer) do
    client
    |> get_process_name(producer)
    |> via_tuple()
    |> GenServer.call({:sync_metadata_cache, System.monotonic_time()})
  end

  @impl true
  def handle_info(
        {{:metadata_updated, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    handle_cluster_or_metadata_changes(state)
  end

  def handle_info(
        {{:cluster_change, client_name}, _event_data, _callback_data},
        %__MODULE__{client_name: client_name} = state
      ) do
    handle_cluster_or_metadata_changes(state)
  end

  def handle_info({:handoff_timeout, ref}, %__MODULE__{} = state) do
    {:noreply, expire_handoff(state, ref, :timeout)}
  end

  def handle_info({:DOWN, mon_ref, :process, _pid, reason}, %__MODULE__{} = state) do
    case Enum.find(state.handoffs, fn {_ref, h} -> mon_ref in h.monitors end) do
      {ref, _handoff} -> {:noreply, expire_handoff(state, ref, {:batcher_down, reason})}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:reconcile_producer_leaders, %__MODULE__{} = state) do
    {:noreply, reconcile_producer_leaders(%{state | reconcile_timer: nil})}
  end

  @impl true
  def handle_cast({:handoff_prepared, ref}, %__MODULE__{} = state) do
    case Map.get(state.handoffs, ref) do
      %{stage: :preparing} = handoff ->
        handoffs = Map.put(state.handoffs, ref, %{handoff | stage: :prepared})
        {:noreply, execute_prepared_handoffs(%{state | handoffs: handoffs})}

      # Aborted
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:reconcile_producer_leaders, %__MODULE__{} = state) do
    {:noreply, reconcile_producer_leaders(state)}
  end

  defp handle_cluster_or_metadata_changes(state) do
    if maybe_find_coordinator(state) != state.coordinator_id do
      # If the coordinator has changed the easiest thing to do is
      # to restart everything through the supervisor.
      # This may only occur to transactional producer when
      # its previous coordinator is not available anymore
      # non transactional producers always have `:any` as
      # coordinator and therefore will not stop
      {:stop, {:shutdown, {:coordinator_change, state.coordinator_id}}, state}
    else
      state = handle_batchers(state)
      {:noreply, %{state | latest_metadata_sync_ts: System.monotonic_time()}}
    end
  end

  @impl true
  def handle_call({:sync_metadata_cache, ts}, _from, %__MODULE__{} = state) do
    if ts < state.latest_metadata_sync_ts do
      {:reply, :ok, state}
    else
      case handle_cluster_or_metadata_changes(state) do
        {:noreply, state} ->
          {:reply, :ok, state}

        resp ->
          resp
      end
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
      client_id: state.client_id,
      connection: state.connection
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

  # Only the batcher that last claimed the partition may bump its epoch. A bump
  # from any other batcher is stale: the partition moved and the new batcher
  # claimed it. Honoring it would take the partition back from the batcher
  # receiving its records, resetting its sequences mid-batch.
  def handle_call(
        {:bump_epoch, topic, partition},
        {called_pid, _tag},
        %__MODULE__{epochs: epochs} = state
      ) do
    case Map.get(epochs, {topic, partition}) do
      {curr_epoch, ^called_pid} ->
        epoch = curr_epoch + 1
        new_state = %{state | epochs: Map.put(epochs, {topic, partition}, {epoch, called_pid})}
        {:reply, {:ok, epoch}, new_state}

      _other_owner ->
        {:reply, {:error, :stale}, state}
    end
  end

  # The handoff's destination has the work and takes the partitions the
  # source still owned, with the epoch it gave, so their sequences go on.
  # Replies with the claimed partitions; the others were claimed with a new
  # epoch in the meantime, by the destination itself after an abort or by
  # another batcher.
  def handle_call({:claim_handoff, ref, claims}, {dest_pid, _tag}, %__MODULE__{} = state) do
    case Map.get(state.handoffs, ref) do
      %{dest_pid: ^dest_pid, source_pid: source_pid} ->
        {claimed, epochs} =
          Enum.reduce(claims, {MapSet.new(), state.epochs}, fn {tp, epoch}, {acc, acc_epochs} ->
            case Map.get(acc_epochs, tp) do
              {^epoch, ^source_pid} ->
                {MapSet.put(acc, tp), Map.put(acc_epochs, tp, {epoch, dest_pid})}

              # Never produced to, or not idempotent
              nil when epoch == nil ->
                {MapSet.put(acc, tp), acc_epochs}

              _ ->
                {acc, acc_epochs}
            end
          end)

        new_state = retire_handoff(%{state | epochs: epochs}, ref)
        {:reply, claimed, new_state, {:continue, :reconcile_producer_leaders}}

      _ ->
        {:reply, MapSet.new(), state}
    end
  end

  defp set_producer_id(%__MODULE__{enable_idempotence: false} = state),
    do: %{state | coordinator_id: maybe_find_coordinator(state)}

  defp set_producer_id(%__MODULE__{enable_idempotence: true} = state) do
    if ConnController.disabled_feature?(state.client_name, :producer_idempotence) do
      raise "Producer idempotence feature is disabled but producer #{state.name} has idempotence enabled. Please check for API versions problems or disable idempotence on this producer (client=#{inspect(state.client_name)}, producer=#{state.name})"
    end

    broker = maybe_find_coordinator(state)

    content = %{
      transactional_id: state.txn_id,
      transaction_timeout_ms: state.txn_timeout_ms
    }

    fun = fn ->
      case Broker.send_message(M.InitProducerId, state.client_name, broker, content, %{},
             connection: state.connection
           ) do
        {:ok, %{content: %{error_code: 0, producer_id: producer_id, producer_epoch: p_epoch}}} ->
          {producer_id, p_epoch}

        {:ok, %{content: %{error_code: ec}}} ->
          Logger.error(
            "#{inspect(M.InitProducerId)} failed with error code #{ec} (client=#{inspect(state.client_name)}, producer=#{state.name})",
            client: state.client_name,
            producer: state.name,
            error_code: ec,
            broker_id: broker
          )

          :retry

        err ->
          {:retry, err}
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
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content, %{},
             connection: state.connection
           ) do
        # vsn <= 3
        {:ok, %{content: %{error_code: 0, node_id: broker_id}}} ->
          broker_id

        {:ok, %{content: %{error_code: ec}}} ->
          Logger.error(
            "#{inspect(M.FindCoordinator)} failed with error code #{ec} (client=#{inspect(state.client_name)}, producer=#{state.name})",
            client: state.client_name,
            producer: state.name,
            txn_id: txn_id,
            error_code: ec
          )

          :retry

        # vsn > 3
        {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: broker_id}]}}} ->
          broker_id

        {:ok, %{content: %{coordinators: [%{error_code: ec}]}}} ->
          Logger.error(
            "#{inspect(M.FindCoordinator)} failed with error code #{ec} (client=#{inspect(state.client_name)}, producer=#{state.name})",
            client: state.client_name,
            producer: state.name,
            txn_id: txn_id,
            error_code: ec
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
    # This ref prevents stale produce response messages from a previous
    # timed-out call being consumed by a subsequent call, which would
    # cause responses to be matched to the wrong records.
    produce_ref = make_ref()
    now = System.monotonic_time(:millisecond)

    delivery_timeout_ms =
      records
      |> group_records_by_batcher(client_name, opt_producer)
      |> Enum.reduce(client_name.get_default_request_timeout_ms(), fn {key, {map_version, recs}},
                                                                      acc ->
        {broker_id, producer, batcher_id} = key

        recs =
          Enum.map(recs, fn %Record{} = rec ->
            %Record{rec | __callback: {callback_pid, produce_ref}, __arrival_ms: now}
          end)

        # The try/catch here is important to prevent
        # partial writes on raises. If a broker dies in the middle
        # of this reduce some messages would still be produced
        # but the user would see an exception and naturally think
        # that all the records failed. That why we catch so we can
        # deliver any problem as "normal" errors to the user
        produce_resp =
          try do
            Batcher.produce(recs, client_name, broker_id, producer, batcher_id, map_version)
          catch
            kind, reason ->
              :ok = sync_metadata_cache(client_name, producer)
              {:error, {kind, reason}}
          end

        case produce_resp do
          {:ok, delivery_timeout_ms} ->
            if acc < delivery_timeout_ms, do: delivery_timeout_ms, else: acc

          # This is a hack to simplify error handling
          # instead of hanlding possible errors on this step
          # we send to self errors as messages, exactly
          # the same way the Dispatcher would do in case of
          # a normal error.
          {:error, reason} ->
            Enum.each(recs, fn %Record{} = rec ->
              send(
                self(),
                {:klife_produce, produce_ref, {:error, inspect(reason)}, rec.__batch_index}
              )
            end)

            acc
        end
      end)

    max_resps = List.last(records).__batch_index
    responses = wait_produce_response(produce_ref, delivery_timeout_ms, max_resps)

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

  @doc false
  def produce_async([%Record{} | _] = records, client_name, opts) do
    opt_producer = Keyword.get(opts, :producer)
    callback = Keyword.get(opts, :callback)
    now = System.monotonic_time(:millisecond)

    records
    |> group_records_by_batcher(client_name, opt_producer)
    |> Enum.each(fn {key, {map_version, recs}} ->
      {broker_id, producer, batcher_id} = key

      recs =
        Enum.map(recs, fn %Record{} = rec ->
          %Record{rec | __callback: callback, __arrival_ms: now}
        end)

      # The try/catch here is important to prevent
      # partial writes on raises. If a broker dies in the middle
      # of this reduce some messages would still be produced
      # but the user would see an exception and naturally think
      # that all the records failed. That why we catch so we can
      # deliver any problem as "normal" errors to the user
      produce_resp =
        try do
          Batcher.produce_async(recs, client_name, broker_id, producer, batcher_id, map_version)
        catch
          kind, reason ->
            :ok = sync_metadata_cache(client_name, producer)
            {:error, {kind, reason}}
        end

      case produce_resp do
        :ok ->
          :ok

        {:error, reason} ->
          Enum.each(recs, fn %Record{} = rec ->
            case callback do
              nil ->
                :noop

              {m, f, a} ->
                rec = %{rec | error_code: inspect(reason)}
                Task.start(m, f, [{:error, rec} | a])

              fun when is_function(fun) ->
                rec = %{rec | error_code: inspect(reason)}
                Task.start(fn -> fun.({:error, rec}) end)
            end
          end)
      end
    end)
  end

  # Each request carries the oldest producer leader map version its
  # partitions were read from, so a batcher can tell when it may get records
  # for partitions it has handed off.
  defp group_records_by_batcher(records, client_name, opt_producer) do
    records
    |> Enum.group_by(fn r -> {r.topic, r.partition} end)
    |> Enum.reduce(%{}, fn {{t, p}, recs}, acc ->
      {:ok, %{default_producer: default_producer}} = MetadataCache.get_metadata(client_name, t, p)
      producer = opt_producer || default_producer
      {map_version, {broker_id, batcher_id}} = get_producer_leader(client_name, producer, t, p)

      Map.update(acc, {broker_id, producer, batcher_id}, {map_version, recs}, fn {version,
                                                                                  acc_recs} ->
        {min(version, map_version), recs ++ acc_recs}
      end)
    end)
  end

  defp wait_produce_response(produce_ref, timeout_ms, max_resps) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_produce_response(produce_ref, deadline, max_resps, 0, %{})
  end

  defp do_wait_produce_response(_produce_ref, _deadline, max_resps, max_resps, resps), do: resps

  defp do_wait_produce_response(produce_ref, deadline, max_resps, counter, resps) do
    now = System.monotonic_time(:millisecond)

    if deadline > now do
      receive do
        {:klife_produce, ^produce_ref, resp, batch_idx} ->
          new_resps = Map.put(resps, batch_idx, resp)
          new_counter = counter + 1
          do_wait_produce_response(produce_ref, deadline, max_resps, new_counter, new_resps)

        {:klife_produce, _produce_ref, resp, _batch_idx} ->
          Logger.warning(
            "Unkown ref received on producer call! Unkown produce response is: #{inspect(resp)}"
          )

          do_wait_produce_response(produce_ref, deadline, max_resps, counter, resps)
      after
        deadline - now ->
          do_wait_produce_response(produce_ref, deadline, max_resps, counter, resps)
      end
    else
      new_resps =
        Enum.reduce(1..max_resps, resps, fn idx, acc ->
          Map.put_new(acc, idx, {:error, :timeout})
        end)

      do_wait_produce_response(produce_ref, deadline, max_resps, max_resps, new_resps)
    end
  end

  defp handle_batchers(%__MODULE__{} = state) do
    known_brokers = ConnController.get_known_brokers(state.client_name)
    :ok = init_batchers(state, known_brokers, state.batchers_count)
    reconcile_producer_leaders(state)
  end

  defp init_batchers(state, known_brokers, batchers_per_broker) do
    for broker_id <- known_brokers,
        batcher_id <- 0..(batchers_per_broker - 1) do
      args = [
        {:broker_id, broker_id},
        {:id, batcher_id},
        {:producer_config, state},
        {:batcher_config, build_batcher_config(state)}
      ]

      spec = %{
        id: {__MODULE__, Batcher, state.client_name, state.name, broker_id, batcher_id},
        start: {Batcher, :start_link, [args]},
        restart: :transient,
        type: :worker
      }

      case DynamicSupervisor.start_child(state.batcher_supervisor, spec) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok
      end
    end

    :ok
  end

  defp build_batcher_config(%__MODULE__{} = state) do
    [
      {:batch_wait_time_ms, state.linger_ms},
      {:max_in_flight, state.max_in_flight_requests},
      {:max_batch_size, state.batch_size_bytes}
    ]
  end

  # Producer leaders follow each partition's leader. A new partition gets its
  # producer leader right away. A partition whose leader changed is handed off from its current
  # batcher to the new one, grouped by batcher pair, one handoff at a time
  # per partition. Changes found while a partition is being handed off are
  # picked up when the handoff ends.
  defp reconcile_producer_leaders(%__MODULE__{} = state) do
    %__MODULE__{client_name: client_name, batchers_count: batchers_count} = state

    {direct, moves, retry?} =
      for %{key: tp, leader_id: leader_id} <- MetadataCache.get_all_metadata(client_name),
          not is_map_key(state.handoff_tps, tp),
          reduce: {%{}, %{}, false} do
        {direct, moves, retry?} = acc ->
          dest = {leader_id, :erlang.phash2(tp, batchers_count)}

          case Map.get(state.producer_leader_map, tp) do
            ^dest ->
              acc

            source ->
              cond do
                # New partition, or nothing left to hand off
                source == nil or batcher_pid(state, source) == nil ->
                  {Map.put(direct, tp, dest), moves, retry?}

                # A batcher being restarted, or of a broker not known yet
                batcher_pid(state, dest) == nil ->
                  {direct, moves, true}

                true ->
                  {direct, Map.update(moves, {source, dest}, [tp], &[tp | &1]), retry?}
              end
          end
      end

    state =
      if map_size(direct) > 0,
        do:
          publish_producer_leader_map(%{
            state
            | producer_leader_map: Map.merge(state.producer_leader_map, direct)
          }),
        else: state

    # Tried again later, unless a retry is already due
    state =
      if retry? and state.reconcile_timer == nil,
        do: %{
          state
          | reconcile_timer:
              Process.send_after(self(), :reconcile_producer_leaders, state.retry_backoff_ms)
        },
        else: state

    Enum.reduce(moves, state, fn {{source, dest}, tps}, acc ->
      ref = make_ref()
      source_pid = batcher_pid(acc, source)
      dest_pid = batcher_pid(acc, dest)

      :ok = Batcher.prepare_to_receive_handoff(dest_pid, ref, tps)

      handoff = %{
        tps: tps,
        dest: dest,
        source_pid: source_pid,
        dest_pid: dest_pid,
        stage: :preparing,
        monitors: [Process.monitor(source_pid), Process.monitor(dest_pid)],
        timer: Process.send_after(self(), {:handoff_timeout, ref}, acc.request_timeout_ms)
      }

      %{
        acc
        | handoffs: Map.put(acc.handoffs, ref, handoff),
          handoff_tps: Enum.reduce(tps, acc.handoff_tps, &Map.put(&2, &1, ref))
      }
    end)
  end

  # Waits for every destination preparing to ack, so a burst of handoffs
  # publishes its producer leader map once. Then the sources are asked to
  # execute.
  defp execute_prepared_handoffs(%__MODULE__{} = state) do
    prepared = for {ref, %{stage: :prepared} = h} <- state.handoffs, do: {ref, h}

    if prepared == [] or Enum.any?(state.handoffs, fn {_ref, h} -> h.stage == :preparing end) do
      state
    else
      leader_map =
        Enum.reduce(prepared, state.producer_leader_map, fn {_ref, h}, acc ->
          Enum.reduce(h.tps, acc, &Map.put(&2, &1, h.dest))
        end)

      state = publish_producer_leader_map(%{state | producer_leader_map: leader_map})

      Enum.reduce(prepared, state, fn {ref, h}, acc ->
        :ok =
          Batcher.execute_handoff_to_new_leader(
            h.source_pid,
            ref,
            h.tps,
            acc.producer_leader_map_version,
            h.dest_pid
          )

        %{acc | handoffs: Map.put(acc.handoffs, ref, %{h | stage: :executing})}
      end)
    end
  end

  # Aborts a handoff whose source or destination did not get through in
  # time, or died. The destination inserts its held records as for any new
  # partition, which claims it with a new epoch, and fails the work if it
  # ever arrives. A handoff aborted before its producer leader was published is tried
  # again.
  defp expire_handoff(%__MODULE__{} = state, ref, reason) do
    case Map.get(state.handoffs, ref) do
      nil ->
        state

      handoff ->
        Logger.warning(
          "Partition handoff aborted (reason=#{inspect(reason)}) (client=#{inspect(state.client_name)}, producer=#{state.name})",
          client: state.client_name,
          producer: state.name,
          partitions: handoff.tps
        )

        :ok = Batcher.abort_handoff(handoff.dest_pid, ref)

        state
        |> retire_handoff(ref)
        |> execute_prepared_handoffs()
        |> reconcile_producer_leaders()
    end
  end

  defp retire_handoff(%__MODULE__{} = state, ref) do
    {handoff, handoffs} = Map.pop!(state.handoffs, ref)
    Process.cancel_timer(handoff.timer)
    Enum.each(handoff.monitors, &Process.demonitor(&1, [:flush]))

    %{state | handoffs: handoffs, handoff_tps: Map.drop(state.handoff_tps, handoff.tps)}
  end

  defp publish_producer_leader_map(%__MODULE__{} = state) do
    map_version = state.producer_leader_map_version + 1

    :persistent_term.put(
      {__MODULE__, :producer_leader_map, state.client_name, state.name},
      {map_version, state.producer_leader_map}
    )

    %{state | producer_leader_map_version: map_version}
  end

  defp batcher_pid(%__MODULE__{} = state, {broker_id, batcher_id}) do
    case registry_lookup({Batcher, state.client_name, broker_id, state.name, batcher_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # The producer leader map, with its version: each partition's producer
  # leader, the batcher that owns it, as {broker_id, batcher_id}
  @doc false
  def get_producer_leader_map(client_name, producer_name) do
    :persistent_term.get({__MODULE__, :producer_leader_map, client_name, producer_name}, {0, %{}})
  end

  @doc false
  def get_producer_leader(client_name, producer_name, topic, partition) do
    {map_version, leader_map} = get_producer_leader_map(client_name, producer_name)

    case Map.get(leader_map, {topic, partition}) do
      nil ->
        :ok = sync_metadata_cache(client_name, producer_name)
        {map_version, leader_map} = get_producer_leader_map(client_name, producer_name)
        {map_version, Map.fetch!(leader_map, {topic, partition})}

      producer_leader ->
        {map_version, producer_leader}
    end
  end
end
