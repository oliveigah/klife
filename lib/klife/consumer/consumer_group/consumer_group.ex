defmodule Klife.Consumer.ConsumerGroup do
  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Connection.Controller, as: ConnController

  alias Klife.Consumer.Fetcher
  alias Klife.Connection.Broker

  alias Klife.Helpers

  alias KlifeProtocol.Messages, as: M

  alias Klife.Consumer.ConsumerGroup.TopicConfig

  alias Klife.Consumer.ConsumerGroup.Consumer

  alias Klife.Consumer.Committer

  alias Klife.MetadataCache

  @consumer_group_opts [
    client: [
      type: :atom,
      required: true,
      doc: "The name of the klife client to be used by the consumer group"
    ],
    topics: [
      type_doc: "List of ` Klife.Consumer.ConsumerGroup.TopicConfig` configurations",
      type: {:list, {:keyword_list, TopicConfig.get_opts()}},
      required: true,
      doc: "List of topic configurations that will be handled by the consumer group"
    ],
    group_name: [
      type: :string,
      required: true,
      doc: "Name of the consumer group"
    ],
    instance_id: [
      type: :string,
      doc: "Value to identify the consumer across restarts (static membership). See KIP-345"
    ],
    rebalance_timeout_ms: [
      type: :non_neg_integer,
      default: 30_000,
      doc:
        "The maximum time in milliseconds that the kafka broker coordinator will wait on the member to revoke it's partitions"
    ],
    fetch_strategy: [
      type: {:custom, __MODULE__, :validate_fetch_strategy, []},
      default: {:exclusive, []},
      doc: """
      Fetch strategy for this topic. Can be either:
      - `{:exclusive, fetcher_options}` - Will create an exclusive fetcher to be used for this consumer group
      - `{:shared, fetcher_name}` - Will use a pre existing fetcher that will batch requests from different sources
      """
    ],
    committers_count: [
      type: :pos_integer,
      default: 1,
      doc: "How many committer processes will be started for the consumer group"
    ],
    isolation_level: [
      type: {:in, [:read_committed, :read_uncommitted]},
      default: :read_committed,
      doc:
        "Define if the consumers of the consumer group will receive uncommitted transactional records"
    ]
  ]

  @moduledoc """
  Defines a consumer group.

  A consumer group coordinates the consumption of records across one or more topics,
  handling partition assignment, offset tracking, rebalancing, and fault tolerance
  automatically. It uses the Kafka consumer group protocol (KIP-848) to distribute
  partitions among members of the group.

  Consumer groups are the recommended way to consume records from Kafka with Klife.
  For lower-level, standalone consumption see the `Klife.Client` fetch API and
  `Klife.Consumer.Fetcher`.

  > #### `use Klife.Consumer.ConsumerGroup` {: .info}
  >
  > When you `use Klife.Consumer.ConsumerGroup`, it will extend your module to:
  >
  > - Implement a GenServer that manages the consumer group lifecycle (heartbeats,
  > rebalancing, consumer start/stop).
  > - Require implementing the callbacks defined below for handling records
  > (mandatory) and lifecycle events (optional).
  >
  > The `:client` option is required at compile time:
  >
  > ```elixir
  > use Klife.Consumer.ConsumerGroup, client: MyApp.MyClient
  > ```

  ## Getting started

  Define a consumer group module, implement `handle_record_batch/4`, and start it
  under your application's supervision tree:

  ```elixir
  defmodule MyApp.MyConsumerGroup do
    use Klife.Consumer.ConsumerGroup,
      client: MyApp.MyClient,
      group_name: "my_group",
      topics: [
        [name: "orders"],
        [name: "events", offset_reset_policy: :earliest]
      ]

    @impl true
    def handle_record_batch(_topic, _partition, _group_name, records) do
      Enum.map(records, fn record ->
        # process record...
        {:commit, record}
      end)
    end
  end
  ```

  Then add it to your supervision tree:

  ```elixir
  children = [
    MyApp.MyClient,
    MyApp.MyConsumerGroup
  ]
  ```

  With default settings, this consumer group will:

  - Process records one batch at a time, waiting for each commit to complete before processing
  the next batch (no duplicate risk from pipelining).
  - Start from the latest offset when no previous commit exists (new partitions skip
  existing data).
  - Use an exclusive fetcher with default settings.
  - Only deliver records from committed transactions (`isolation_level: :read_committed`).

  ## Consumer group configurations

  #{NimbleOptions.docs(@consumer_group_opts)}

  ## Topic configurations

  Each topic in the `:topics` list accepts its own set of options for controlling
  fetch behavior, batch sizes, cooldowns, and offset management.

  See the `Klife.Consumer.ConsumerGroup.TopicConfig` docs for the full list of
  topic-level options.

  ## Consistency guarantees

  The consumer group provides the following guarantees:

  - **No record is ever skipped.** Records are delivered in offset order within a
  partition. If a record fails and is retried, no subsequent record from that
  partition will be delivered until the retry succeeds.
  - **At-least-once delivery.** After a crash, the consumer restarts from the last
  committed offset, which means some records may be delivered again.

  The number of duplicate deliveries after a crash depends directly on how many
  records were processed but not yet committed. Three configurations control this:

  1. **`handler_max_unacked_commits: 0`** (default) — the consumer waits for each
  batch's offset to be committed before processing the next one. After a crash,
  at most one batch of records may be re-delivered. This is the safest setting.

  2. **`handler_max_unacked_commits: N`** (N > 0) — the consumer can process up to
  N additional batches while previous commits are still in flight. This pipelines
  processing and committing for higher throughput, but after a crash all uncommitted
  batches are re-delivered. For example, with `handler_max_unacked_commits: 3` the
  consumer can be up to 4 batches ahead of the last commit, so a crash could
  re-deliver up to 4 batches.

  3. **`committers_count`** — controls how many committer processes handle offset
  commits. Topic-partitions are distributed evenly across committers. A single
  committer (default) means all partitions share one commit pipeline, so a slow
  commit for one partition delays commits for others. Increasing `committers_count`
  adds parallelism but the impact on duplicates is indirect: faster commits mean
  less time for the gap between processed and committed to grow.

  If your application cannot tolerate duplicates, implement idempotent processing
  in your `handle_record_batch/4` callback (e.g. using a unique key per record to
  deduplicate on the consumer side).

  ### Per-record retry and offset advancement

  When using per-record return values (`{:commit, record}` / `{:retry, record}`),
  the committed offset advances to the **last committed record** in the batch. Retried
  records are re-delivered in the next batch before any new records.

  Consider this scenario:

  ```md
  - Batch contains records at offsets [10, 11, 12, 13, 14]
  - Handler returns: [{:commit, 10}, {:commit, 11}, {:retry, 12}, {:commit, 13}, {:commit, 14}]
  - Offset 14 is committed (the highest committed record)
  - Record 12 is re-delivered in the next batch with an incremented `consumer_attempts` counter
  ```

  This means that if the consumer crashes before record 12 is successfully processed,
  it will restart from offset 15 (since 14 was committed) and record 12 will be lost.
  Use per-record retry only when you are comfortable with this trade-off, for example
  when retried records are also written to a dead-letter topic on repeated failure.

  If you need to guarantee that record 12 is never lost, return `:retry` for the
  entire batch instead — this will not advance the offset and all records will be
  re-delivered.

  ## Performance tuning

  The default configuration prioritizes safety: one batch at a time, wait for commit,
  then process the next batch. For high-throughput workloads, several options can be
  tuned to increase performance at the cost of more duplicates after crashes.

  ### Pipelining processing and commits

  Set `handler_max_unacked_commits` to a value greater than 0 to allow the consumer to
  continue processing while previous commits are in flight. The consumer will process up
  to `handler_max_unacked_commits` additional batches ahead of the last confirmed commit.

  ```elixir
  topics: [
    [name: "events", handler_max_unacked_commits: 5]
  ]
  ```

  This is the single most impactful setting for throughput. A value of 5 is a good
  starting point for workloads where occasional duplicates are acceptable.

  ### Controlling batch sizes

  The `handler_max_batch_size` and `fetch_max_bytes` options together control how much
  data is delivered per callback invocation:

  - `fetch_max_bytes` controls how much data the fetcher requests from the broker per
  partition. Larger values mean fewer fetch round-trips. Must be lower than the
  fetcher's `max_bytes_per_request`.

  - `handler_max_batch_size: :dynamic` (default) delivers all records from a single
  fetch response as one batch. This minimizes per-batch overhead and is best for
  most workloads.

  - `handler_max_batch_size: N` (positive integer) chunks fetched records into batches
  of at most N records. Use this when your handler logic has a natural batch size limit
  (e.g. a database bulk insert that accepts at most 1000 rows).

  With `:dynamic`, `max_queue_size` defaults to 5. With a fixed batch size, it defaults
  to 20 to compensate for the smaller batches.

  ### Reducing fetch idle time

  The consumer pre-fetches the next batch when the internal queue drops to 3 or fewer
  entries. Two options control the timing:

  - `fetch_interval_ms` (default: 1000) — how long to wait before retrying when a fetch
  returns no records. Empty fetches use a progressive backoff up to this value: the first
  empty response waits `fetch_interval_ms / 10`, the second `fetch_interval_ms / 5`, and
  so on up to `fetch_interval_ms` after 10 consecutive empty responses. Lower values
  reduce latency for bursty topics at the cost of more broker requests during idle periods.

  - `max_queue_size` — the maximum number of record batches the consumer can buffer.
  Higher values let the consumer pre-fetch more aggressively, reducing the chance of
  the queue draining completely. But larger queues also mean more records in memory and
  a longer gap between fetched and committed data.

  ### Handler cooldown

  `handler_cooldown_ms` (default: 0) adds a fixed delay between processing cycles. This
  is rarely needed, but can be useful to throttle processing rate — for example, if your
  handler calls a rate-limited external API.

  The cooldown can also be dynamically overridden for one cycle by returning `callback_opts`
  from `handle_record_batch/4`. This enables backoff strategies:

  ```elixir
  def handle_record_batch(_topic, _partition, _group_name, records) do
    case process(records) do
      :ok -> :commit
      :transient_error -> {:retry, handler_cooldown_ms: 5_000}
    end
  end
  ```

  ## Fetch strategy

  The `fetch_strategy` option controls how the consumer group fetches records from
  Kafka. It can be set at the group level and overridden per topic.

  - `{:exclusive, fetcher_options}` (default) — creates a dedicated `Klife.Consumer.Fetcher`
  for this consumer group (or topic). The consumer group's fetch traffic is fully isolated
  from other consumers and standalone fetch calls. This is the default because consumer
  groups typically have predictable, continuous fetch patterns that benefit from dedicated
  resources.

  - `{:shared, fetcher_name}` — uses a pre-existing fetcher configured in the
  `Klife.Client`. Multiple consumer groups (or standalone consumers) sharing
  the same fetcher benefit from better batch efficiency since their requests
  are combined into fewer TCP calls. This is useful when you have many consumer
  groups with low throughput and want to minimize the number of fetcher processes.

  When overriding at the topic level, the topic gets its own dedicated fetcher even if the
  group uses a shared one. This is useful when a single topic has very different throughput
  or latency requirements from the rest of the group.

  See the `Klife.Consumer.Fetcher` docs for the available fetcher options and their
  trade-offs.

  ## Static membership

  By default, each time a consumer group process restarts it gets a new member identity.
  Kafka sees this as a new member joining and triggers a rebalance, which reassigns all
  partitions across the group — even if the same partitions end up assigned to the same
  members.

  Setting `instance_id` enables static membership (KIP-345). When a consumer restarts
  with the same `instance_id`, Kafka recognizes it as the same member and skips the
  rebalance. This significantly reduces partition shuffling during rolling deployments:

  ```elixir
  use Klife.Consumer.ConsumerGroup,
    client: MyApp.MyClient,
    group_name: "my_group",
    instance_id: "my-app-instance-1",
    topics: [[name: "orders"]]
  ```

  For deployments with multiple instances, each instance must have a unique `instance_id`.
  A common pattern is to derive it from the hostname or pod name.

  ## Isolation level

  The `isolation_level` option controls whether records from uncommitted transactions
  are delivered to the handler:

  - `:read_committed` (default) — only delivers records from committed transactions.
  Records from aborted transactions are automatically filtered out.
  - `:read_uncommitted` — delivers all records, including those from transactions that
  may later be aborted. Use this only when you need the lowest possible latency and
  your handler can tolerate processing records that were never committed by the producer.

  This can be overridden per topic via the topic-level `isolation_level` option in
  `Klife.Consumer.ConsumerGroup.TopicConfig`.
  """

  @type action :: :commit | :retry

  @type callback_opts :: [
          {:handler_cooldown_ms, non_neg_integer()}
        ]

  @doc """
  Called for each batch of records delivered to the consumer.

  Receives the topic name, partition, group name, and a list of `Klife.Record` structs.
  The return value controls what happens with the records.

  ## Batch-level control

  Return a single action to apply to the entire batch:

  - `:commit` — commits all records in the batch.
  - `:retry` — retries the entire batch.
  - `{action, callback_opts}` — same as above, with options.

  ## Per-record control

  Return a list of `{action, record}` tuples for fine-grained control. Records
  tagged with `:commit` have their offsets advanced; records tagged with `:retry`
  are re-delivered in the next batch.

  ```elixir
  def handle_record_batch(_topic, _partition, _group_name, records) do
    Enum.map(records, fn record ->
      case process(record) do
        :ok -> {:commit, record}
        :error -> {:retry, record}
      end
    end)
  end
  ```

  ## Callback options

  Both batch-level and per-record return values can be wrapped in a tuple with
  `callback_opts` as the second element. The available options:

  - `handler_cooldown_ms`: overrides the topic-level `handler_cooldown_ms` for the
    next processing cycle only. Useful for implementing backoff on transient failures.
  """
  @callback handle_record_batch(
              topic :: String.t(),
              partition :: integer,
              group_name :: String.t(),
              list(Klife.Record.t())
            ) ::
              action
              | {action, callback_opts}
              | list({action, Klife.Record.t()})
              | {list({action, Klife.Record.t()}), callback_opts}

  @doc """
  Called when a consumer process is started for a topic-partition after assignment.
  """
  @callback handle_consumer_start(
              topic :: String.t(),
              partition :: integer,
              group_name :: String.t()
            ) :: :ok

  @doc """
   Called when a consumer process is stopped for a topic-partition (due to revocation,
   shutdown, or crash). The revocation reason is
   `{:shutdown, {:assignment_revoked, topic_id, partition_index}}`.
  """
  @callback handle_consumer_stop(
              topic :: String.t(),
              partition :: integer,
              group_name :: String.t(),
              reason :: term
            ) :: :ok

  @optional_callbacks [handle_consumer_start: 3, handle_consumer_stop: 4]

  defstruct Keyword.keys(@consumer_group_opts) ++
              [
                :mod,
                :client_name,
                :coordinator_id,
                :member_id,
                :epoch,
                :heartbeat_interval_ms,
                :assigned_topic_partitions,
                :consumer_supervisor,
                :internal_supervisor,
                :consumers_monitor_map,
                :committers_distribution
              ]

  defmacro __using__(opts) do
    if !Keyword.has_key?(opts, :client) do
      raise ArgumentError, """
      client option is required when using Klife.Consumer.ConsumerGroup.

      use Klife.Consumer.ConsumerGroup, client: MyKlifeClient
      """
    end

    quote bind_quoted: [opts: opts] do
      use GenServer

      @behaviour Klife.Consumer.ConsumerGroup

      def klife_client(), do: unquote(opts[:client])

      def start_link(args) do
        cg_opts = unquote(opts)
        input_map_args = Map.new(args)
        cg_opts_map_args = Map.new(cg_opts)
        final_map_args = Map.merge(cg_opts_map_args, input_map_args)
        final_args = Map.to_list(final_map_args)

        Klife.Consumer.ConsumerGroup.start_link(__MODULE__, final_args)
      end

      def init(args), do: Klife.Consumer.ConsumerGroup.init(__MODULE__, args)

      def handle_info(:heartbeat, state) do
        Klife.Consumer.ConsumerGroup.handle_heartbeat(state)
      end

      def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
        Klife.Consumer.ConsumerGroup.handle_consumer_down(state, ref, reason)
      end

      def handle_info({:EXIT, _from, reason}, state) do
        exit(reason)
      end

      def handle_call(:member_epoch, _from, state) do
        Klife.Consumer.ConsumerGroup.handle_member_epoch(state)
      end

      def terminate(reason, state) do
        Klife.Consumer.ConsumerGroup.handle_terminate(state, reason)
      end
    end
  end

  def get_opts(), do: @consumer_group_opts

  def validate_fetch_strategy({:shared, fetcher_name}) when is_atom(fetcher_name) do
    {:ok, {:shared, fetcher_name}}
  end

  def validate_fetch_strategy({:exclusive, options}) when is_list(options) do
    # Name will be replaced on the maybe_start_group_fetcher function
    with_tmp_name = Keyword.put(options, :name, :tbd)

    case NimbleOptions.validate(with_tmp_name, Fetcher.get_opts()) do
      {:ok, validated_opts} -> {:ok, {:exclusive, validated_opts}}
      {:error, error} -> {:error, error}
    end
  end

  def validate_fetch_strategy(value) do
    {:error,
     "expected :fetch_strategy to be either {:shared, atom} or {:exclusive, keyword_list}, got: #{inspect(value)}"}
  end

  def start_link(cg_mod, args) do
    args =
      Keyword.put_new(
        args,
        :fetch_strategy,
        {:shared, cg_mod.klife_client().get_default_fetcher()}
      )

    base_validated_args =
      NimbleOptions.validate!(args, @consumer_group_opts)

    map_args = Helpers.keyword_list_to_map(base_validated_args)

    validated_args =
      %__MODULE__{}
      |> Map.from_struct()
      |> Map.merge(map_args)
      |> Map.put(:mod, cg_mod)
      |> Map.put(:member_id, UUID.uuid4())

    if ConnController.disabled_feature?(cg_mod.klife_client(), :consumer_group) do
      raise "Consumer Group was started but consumer_group feature is disabled for client #{inspect(cg_mod.klife_client())}. Check logs for details."
    end

    GenServer.start_link(cg_mod, validated_args,
      name: get_process_name(cg_mod.klife_client(), cg_mod, validated_args.group_name)
    )
  end

  defp get_process_name(client_name, cg_mod, group_name) do
    via_tuple({__MODULE__, client_name, cg_mod, group_name})
  end

  def get_member_epoch(cg_pid) do
    GenServer.call(cg_pid, :member_epoch)
  end

  def init(mod, args_map) do
    Process.flag(:trap_exit, true)

    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    :ets.new(get_acked_topic_partitions_table(mod.klife_client(), mod, args_map.group_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    init_state =
      %__MODULE__{
        mod: mod,
        group_name: args_map.group_name,
        instance_id: args_map.instance_id,
        rebalance_timeout_ms: args_map.rebalance_timeout_ms,
        client_name: mod.klife_client(),
        member_id: args_map.member_id,
        epoch: 0,
        heartbeat_interval_ms: 1_000,
        assigned_topic_partitions: [],
        consumer_supervisor: consumer_sup_pid,
        internal_supervisor: nil,
        consumers_monitor_map: %{},
        fetch_strategy: args_map.fetch_strategy,
        committers_count: args_map.committers_count,
        committers_distribution: %{}
      }
      |> get_coordinator!()

    {init_state, group_fetcher_specs} = build_group_fetcher_specs(init_state)

    {topics, topic_fetcher_specs} =
      args_map.topics
      |> Enum.map_reduce([], fn tc, acc_specs ->
        final_tc = TopicConfig.from_map(tc, init_state)
        {final_tc, specs} = build_topic_fetcher_specs(final_tc, init_state)
        {{tc.name, final_tc}, acc_specs ++ specs}
      end)

    init_state = %{init_state | topics: Map.new(topics)}

    {committers_distribution, committer_specs} = build_committer_specs(init_state)
    init_state = %{init_state | committers_distribution: committers_distribution}

    internal_children = group_fetcher_specs ++ topic_fetcher_specs ++ committer_specs

    {:ok, internal_sup_pid} =
      Supervisor.start_link(internal_children, strategy: :one_for_one)

    init_state = %{init_state | internal_supervisor: internal_sup_pid}

    send(self(), :heartbeat)

    Logger.info(
      "Starting consumer group #{init_state.group_name} with module #{init_state.mod}",
      client: init_state.client_name,
      group: init_state.group_name
    )

    {:ok, init_state}
  end

  defp get_acked_topic_partitions_table(client_name, cg_mod, cg_name),
    do: :"acked_topic_partitions.#{client_name}.#{cg_mod}.#{cg_name}"

  defp ack_topic_partition(client_name, cg_mod, topic_id, partition_idx, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.insert({{topic_id, partition_idx}})
  end

  defp unack_topic_partition(client_name, cg_mod, topic_id, partition_idx, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.delete({{topic_id, partition_idx}})
  end

  defp unack_all_topic_partitions(client_name, cg_mod, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.delete_all_objects()
  end

  def get_coordinator!(%__MODULE__{} = state) do
    content = %{
      key_type: 0,
      coordinator_keys: [state.group_name]
    }

    fun = fn ->
      case Broker.send_message(M.FindCoordinator, state.client_name, :any, content) do
        {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: broker_id}]}}} ->
          if state.coordinator_id != nil and state.coordinator_id != broker_id do
            Logger.info(
              "Coordinator changed from #{state.coordinator_id} to #{broker_id} for group #{state.group_name} running module #{state.mod}",
              client: state.client_name,
              group: state.group_name
            )

            Enum.each(state.committers_distribution, fn {commiter_id, _list} ->
              :ok =
                Committer.update_coordinator(
                  broker_id,
                  state.client_name,
                  state.mod,
                  state.group_name,
                  commiter_id
                )
            end)
          end

          %__MODULE__{state | coordinator_id: broker_id}

        {:ok, %{content: %{coordinators: [%{error_code: ec}]}}} ->
          Logger.error(
            "#{inspect(M.FindCoordinator)} failed with error code #{ec} for group #{state.group_name} running module #{state.mod}",
            client: state.client_name,
            group: state.group_name
          )

          {:retry, {:error, ec}}

        {:error, reason} ->
          Logger.error(
            "#{inspect(M.FindCoordinator)} failed unexpectedly with reason #{inspect(reason)} for group #{state.group_name} running module #{state.mod}",
            client: state.client_name,
            group: state.group_name
          )

          {:retry, {:error, reason}}
      end
    end

    Helpers.with_timeout!(fun, state.client_name.get_default_request_timeout_ms() * 2)
  end

  def processing_allowed?(client_name, cg_mod, topic_id, partition, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.member({topic_id, partition})
  end

  def handle_member_epoch(%__MODULE__{} = state) do
    {:reply, state.epoch, state}
  end

  def handle_heartbeat(%__MODULE__{} = state) do
    case do_heartbeat(state) do
      {:ok, new_state} ->
        new_state = handle_assignment(new_state)

        Process.send_after(self(), :heartbeat, new_state.heartbeat_interval_ms)

        {:noreply, new_state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp do_heartbeat(%__MODULE__{} = state) do
    tp_list = Map.values(state.consumers_monitor_map)

    content =
      %{
        group_id: state.group_name,
        member_id: state.member_id,
        member_epoch: state.epoch,
        instance_id: state.instance_id,
        rebalance_timeout_ms: state.rebalance_timeout_ms,
        subscribed_topic_names: Map.keys(state.topics),
        topic_partitions:
          tp_list
          |> Enum.group_by(fn {t_id, _p} -> t_id end, fn {_t_id, p} -> p end)
          |> Enum.map(fn {t_id, partitions} -> %{partitions: partitions, topic_id: t_id} end),
        # TODO: Implement later
        rack_id: nil,
        subscribed_topic_regex: nil,
        server_assignor: nil
      }

    case Broker.send_message(
           M.ConsumerGroupHeartbeat,
           state.client_name,
           state.coordinator_id,
           content,
           %{},
           timeout_ms: state.rebalance_timeout_ms
         ) do
      {:error, error} ->
        Logger.error(
          "Heartbeat error for group #{state.group_name} running module #{state.mod}: #{inspect(error)}",
          client: state.client_name,
          group: state.group_name,
          reason: inspect(error)
        )

        {:ok, get_coordinator!(state)}

      {:ok, %{content: %{error_code: 0} = resp}} ->
        if state.coordinator_id != nil and resp.member_epoch != state.epoch do
          Logger.info(
            "Epoch bumped from #{state.epoch} to #{resp.member_epoch} for group #{state.group_name} running module #{state.mod}",
            client: state.client_name,
            group: state.group_name
          )

          Enum.each(state.committers_distribution, fn {commiter_id, _list} ->
            :ok =
              Committer.update_epoch(
                resp.member_epoch,
                state.client_name,
                state.mod,
                state.group_name,
                commiter_id
              )
          end)
        end

        Enum.each(tp_list, fn {t_id, p} ->
          true =
            ack_topic_partition(
              state.client_name,
              state.mod,
              t_id,
              p,
              state.group_name
            )
        end)

        new_state =
          %__MODULE__{
            state
            | assigned_topic_partitions:
                get_in(resp, [:assignment, :topic_partitions]) || state.assigned_topic_partitions,
              heartbeat_interval_ms: resp.heartbeat_interval_ms,
              epoch: resp.member_epoch
          }

        {:ok, new_state}

      {:ok, %{content: %{error_code: ec, error_message: em}}} ->
        Logger.error(
          "Heartbeat error for group #{state.group_name} running module #{state.mod}: error_code=#{ec} error_message=#{em}",
          client: state.client_name,
          group: state.group_name,
          consumer_group_mod: state.mod,
          error_code: ec,
          error_message: em
        )

        coordinator_error? = ec in [14, 15, 16]
        static_membership_error? = ec in [111]

        cond do
          coordinator_error? ->
            {:ok, get_coordinator!(state)}

          static_membership_error? ->
            {:ok, state}

          # TODO: Check if there is ways to handle more error codes here!
          true ->
            Logger.error(
              "Unrecoverable heartbeat error for group #{state.group_name} running module #{state.mod}, restarting: error_code=#{ec} error_message=#{em}",
              client: state.client_name,
              group: state.group_name,
              error_code: ec,
              error_message: em
            )

            {:error, ec}
        end
    end
  end

  defp build_committer_specs(%__MODULE__{} = state) do
    1..state.committers_count
    |> Enum.map_reduce([], fn committer_id, acc_specs ->
      committer_args = [
        group_id: state.group_name,
        broker_id: state.coordinator_id,
        batcher_id: committer_id,
        member_id: state.member_id,
        member_epoch: state.epoch,
        client_name: state.client_name,
        consumer_group_mod: state.mod,
        group_intance_id: state.instance_id,
        cg_pid: self(),
        # TODO: Make config
        batcher_config: [
          {:batch_wait_time_ms, 0},
          # To have max_in_flight greater than 1, must think about
          # how to prevent lower offset values to override
          # higher ones on retries.
          #
          # Eg:
          # req 1 commit 10 (fail)
          # req 2 commit 20 (success)
          # req 1 retry, commit 10 (success)
          #
          # With max_in_flight 1 this is not a problem
          # because failed commits will be merged on
          # the waiting batch using the higher value
          {:max_in_flight, 1}
        ]
      ]

      spec = %{
        id: {Committer, committer_id},
        start: {Committer, :start_link, [committer_args]},
        restart: :permanent,
        type: :worker
      }

      {{committer_id, MapSet.new()}, acc_specs ++ [spec]}
    end)
    |> then(fn {dist_list, specs} -> {Map.new(dist_list), specs} end)
  end

  defp build_group_fetcher_specs(%__MODULE__{fetch_strategy: {:exclusive, opts}} = state)
       when is_list(opts) do
    name = Module.concat([__MODULE__, state.mod, state.group_name])

    args =
      opts
      |> Keyword.put(:client_name, state.client_name)
      |> Keyword.put(:name, name)
      |> Map.new()

    spec = %{
      id: {Fetcher, :group, name},
      start: {Fetcher, :start_link, [args]},
      restart: :permanent,
      type: :worker
    }

    {%{state | fetch_strategy: {:exclusive, name}}, [spec]}
  end

  defp build_group_fetcher_specs(%__MODULE__{} = state) do
    {state, []}
  end

  defp build_topic_fetcher_specs(
         %TopicConfig{fetch_strategy: {:exclusive, opts}} = tc,
         %__MODULE__{} = state
       )
       when is_list(opts) do
    name = Module.concat([__MODULE__, state.mod, state.group_name, tc.name])

    args =
      opts
      |> Keyword.put(:client_name, state.client_name)
      |> Keyword.put(:name, name)
      |> Map.new()

    spec = %{
      id: {Fetcher, :topic, name},
      start: {Fetcher, :start_link, [args]},
      restart: :permanent,
      type: :worker
    }

    {%{tc | fetch_strategy: {:exclusive, name}}, [spec]}
  end

  defp build_topic_fetcher_specs(%TopicConfig{} = tc, %__MODULE__{} = _state) do
    {tc, []}
  end

  defp get_init_offsets(%__MODULE__{} = state, tid_p_list) do
    tname_map =
      tid_p_list
      |> Enum.map(fn {tid, _p} -> tid end)
      |> Enum.uniq()
      |> Enum.map(fn tid ->
        tname = MetadataCache.get_topic_name_by_id!(state.client_name, tid)
        {tid, tname}
      end)
      |> Map.new()

    parsed_list =
      tid_p_list
      |> Enum.map(fn {tid, p} -> {tname_map[tid], p} end)
      |> Enum.group_by(fn {tname, _p} -> tname end, fn {_tname, p} -> p end)

    content = %{
      groups: [
        %{
          group_id: state.group_name,
          member_id: state.member_id,
          member_epoch: state.epoch,
          topics:
            Enum.map(parsed_list, fn {tname, p_list} ->
              %{
                name: tname,
                partition_indexes: p_list
              }
            end)
        }
      ],
      # TODO: should this always be true?
      require_stable: true
    }

    # TODO: Filter out successfull topic/partitions on retries!
    offset_fetch_result =
      Helpers.with_timeout!(
        fn ->
          case Broker.send_message(
                 M.OffsetFetch,
                 state.client_name,
                 state.coordinator_id,
                 content
               ) do
            {:ok, %{content: %{groups: [%{error_code: 0, topics: tdata}]}}} ->
              {results, errors} =
                for topic_resp <- tdata,
                    pdata <- topic_resp.partitions,
                    tp = {topic_resp.name, pdata.partition_index},
                    reduce: {%{}, []} do
                  {res_acc, err_acc} when pdata.error_code == 0 ->
                    {Map.put(res_acc, tp, pdata.committed_offset), err_acc}

                  {res_acc, err_acc} ->
                    {res_acc, [{tp, pdata.error_code} | err_acc]}
                end

              if errors == [] do
                results
              else
                {:retry, errors}
              end

            {:ok, %{content: %{groups: [%{error_code: ec}]}}} ->
              {:retry, [{:group, ec}]}
          end
        end,
        state.client_name.get_default_request_timeout_ms() * 2
      )

    missing_resp_tp =
      offset_fetch_result
      |> Enum.filter(fn {{_tname, _p}, offset} -> offset == -1 end)
      |> Enum.map(fn {{t, p}, -1} -> {t, p} end)

    reset_offset_map = get_reset_offset(missing_resp_tp, state.client_name, state.topics)

    tid_map = tname_map |> Enum.map(fn {tname, tid} -> {tid, tname} end) |> Map.new()

    Map.merge(offset_fetch_result, reset_offset_map)
    |> Enum.map(fn {{tname, p}, offset} -> {{tid_map[tname], p}, offset} end)
    |> Map.new()
  end

  def get_reset_offset(tname_p_list, client, tconfig_map) do
    grouped_by_broker =
      Enum.group_by(
        tname_p_list,
        fn {tname, p} ->
          MetadataCache.get_metadata_attribute(client, tname, p, :leader_id)
        end
      )

    contents =
      Enum.map(grouped_by_broker, fn {broker, tp_list} ->
        grouped_tp_list =
          Enum.group_by(tp_list, fn {tname, _p} -> tname end, fn {_tname, p} -> p end)

        content = %{
          replica_id: -1,
          isolation_level: 1,
          topics:
            Enum.map(grouped_tp_list, fn {tname, plist} ->
              %{
                name: tname,
                partitions:
                  Enum.map(plist, fn p ->
                    %{
                      partition_index: p,
                      timestamp:
                        case tconfig_map[tname].offset_reset_policy do
                          :earliest -> -2
                          :latest -> -1
                        end
                    }
                  end)
              }
            end)
        }

        {broker, content}
      end)

    timeout = client.get_default_request_timeout_ms() * 2

    Task.async_stream(
      contents,
      fn {broker, content} ->
        # TODO: Filter out successfull topic/partitions on retries!
        Helpers.with_timeout!(
          fn ->
            case Broker.send_message(M.ListOffsets, client, broker, content) do
              {:ok, %{content: %{topics: tdata}}} ->
                {results, errors} =
                  for topic_resp <- tdata,
                      pdata <- topic_resp.partitions,
                      tp = {topic_resp.name, pdata.partition_index},
                      reduce: {[], []} do
                    {res_acc, err_acc} when pdata.error_code == 0 ->
                      # Need the -1 so we do not skip the first record
                      {[{tp, pdata.offset - 1} | res_acc], err_acc}

                    {res_acc, err_acc} ->
                      {res_acc, [{tp, pdata.error_code} | err_acc]}
                  end

                if errors == [] do
                  results
                else
                  {:retry, errors}
                end

              {:error, reason} ->
                {:retry, reason}
            end
          end,
          timeout
        )
      end,
      timeout: timeout + :timer.seconds(5)
    )
    |> Enum.flat_map(fn {:ok, resp} -> resp end)
    |> Map.new()
  end

  defp handle_assignment(%__MODULE__{consumers_monitor_map: cm_map} = state) do
    assignment_keys =
      for %{partitions: p_data, topic_id: t_id} <- state.assigned_topic_partitions,
          partition <- p_data do
        {t_id, partition}
      end

    assigment_mapset = MapSet.new(assignment_keys)

    current_mapset =
      cm_map
      |> Map.values()
      |> MapSet.new()

    to_stop = MapSet.difference(current_mapset, assigment_mapset)
    to_start = MapSet.difference(assigment_mapset, current_mapset)

    # This may be needed if we receive a new topic/partition that is not on
    # the metadata yet! So we should filter them out for now until metadata
    # is updated!
    # TODO: Force metadata refresh here!
    #
    # Also there is still a chance for the consumer to start before the
    # fetcher can react to the metadata change, think how to solve this.
    to_start =
      to_start
      |> Enum.reject(fn {topic_id, partition} ->
        tname = MetadataCache.get_topic_name_by_id(state.client_name, topic_id)
        have_metadata? = MetadataCache.metadata_exists?(state.client_name, tname, partition)
        unknown_metadata? = tname == nil or have_metadata? == false

        if unknown_metadata? do
          Logger.warning(
            "Unkown metadata for #{tname}:#{partition} assigned for #{state.group_name} running module #{state.mod}",
            group: state.group_name
          )
        end

        unknown_metadata?
      end)
      |> MapSet.new()

    new_state =
      Enum.reduce(to_stop, state, fn {topic_id, partition}, acc_state ->
        stop_consumer(acc_state, topic_id, partition)
      end)

    if MapSet.size(to_start) != 0 do
      init_offsets_map = get_init_offsets(state, to_start)

      Enum.reduce(to_start, new_state, fn {topic_id, partition}, acc_state ->
        start_consumer(acc_state, topic_id, partition, init_offsets_map[{topic_id, partition}])
      end)
    else
      new_state
    end
  end

  def handle_consumer_down(%__MODULE__{consumers_monitor_map: cmap} = state, monitor_ref, reason) do
    case Map.get(cmap, monitor_ref) do
      nil ->
        Logger.error(
          "Unexpected consumer DOWN message received for #{state.group_name} running module #{state.mod} (client=#{inspect(state.client_name)}, group=#{state.group_name})",
          client: state.client_name,
          group: state.group_name,
          reason: inspect(reason)
        )

        {:stop, reason, state}

      {_topic_id, _partition} ->
        new_cmap = Map.delete(cmap, monitor_ref)
        {:noreply, %__MODULE__{state | consumers_monitor_map: new_cmap}}
    end
  end

  def handle_terminate(%__MODULE__{} = state, reason) do
    true = unack_all_topic_partitions(state.client_name, state.mod, state.group_name)

    Logger.info(
      "Terminating consumer group #{state.group_name} running module #{state.mod}: #{inspect(reason)}",
      client: state.client_name,
      group: state.group_name
    )

    # TODO: Maybe we should also use the termination reason to define leaving epoch
    leaving_epoch = if state.instance_id != nil, do: -2, else: -1

    # TODO: make timeout a config
    state.consumers_monitor_map
    |> Task.async_stream(
      fn {_k, {tid, p}} ->
        :ok = Consumer.revoke_assignment(state.client_name, state.mod, tid, p, state.group_name)
      end,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.to_list()

    exit_state = %__MODULE__{state | consumers_monitor_map: %{}, epoch: leaving_epoch}

    case do_heartbeat(exit_state) do
      {:ok, exit_state} ->
        exit_state

      {:error, reason} ->
        Logger.error(
          "Error while terminating consumer group #{state.group_name} running module #{state.mod}: #{inspect(reason)}",
          client: state.client_name,
          group: state.group_name
        )

        exit_state
    end
  end

  defp stop_consumer(%__MODULE__{} = state, topic_id, partition) do
    true =
      unack_topic_partition(state.client_name, state.mod, topic_id, partition, state.group_name)

    :ok =
      Consumer.revoke_assignment_async(
        state.client_name,
        state.mod,
        topic_id,
        partition,
        state.group_name
      )

    topic_name = MetadataCache.get_topic_name_by_id!(state.client_name, topic_id)

    Logger.info(
      "Assignment revoked #{topic_name}:#{partition} for consumer group #{state.group_name} running module #{state.mod}}",
      client: state.client_name,
      group: state.group_name
    )

    remove_entry_from_committers_map(state, topic_id, partition)
  end

  defp start_consumer(
         %__MODULE__{consumers_monitor_map: cm_map} = state,
         topic_id,
         partition,
         init_offset
       ) do
    committer_id = get_next_committer_id(state.committers_distribution)
    topic_name = MetadataCache.get_topic_name_by_id!(state.client_name, topic_id)

    consumer_args = [
      consumer_group_mod: state.mod,
      topic_id: topic_id,
      partition_idx: partition,
      committer_id: committer_id,
      topic_config: state.topics[topic_name],
      client_name: state.client_name,
      consumer_group_name: state.group_name,
      consumer_group_member_id: state.member_id,
      consumer_group_epoch: state.epoch,
      consumer_group_coordinator_id: state.coordinator_id,
      consumer_group_pid: self(),
      init_offset: init_offset
    ]

    spec = %{
      id: {topic_id, partition},
      start: {Consumer, :start_link, [consumer_args]},
      # I think temporary behaviour is the best approach here
      # because the consumer group process is in charge of restarts
      # and the dynamic supervisor may not have proper state to
      # automatically restart the consumer (ie. init_offset may
      # have been moved forward and auto restart might lead to double consume)
      restart: :temporary,
      type: :worker
    }

    {:ok, pid} =
      case DynamicSupervisor.start_child(state.consumer_supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

    new_committer_dist =
      Map.update!(state.committers_distribution, committer_id, fn curr_ms ->
        MapSet.put(curr_ms, {topic_id, partition})
      end)

    ref = Process.monitor(pid)

    Logger.info(
      "Assignment received #{topic_name}:#{partition} for consumer group #{state.group_name} running module #{state.mod}}",
      client: state.client_name,
      group: state.group_name
    )

    %__MODULE__{
      state
      | committers_distribution: new_committer_dist,
        consumers_monitor_map: Map.put(cm_map, ref, {topic_id, partition})
    }
  end

  defp get_next_committer_id(committer_distribution_map) do
    committer_distribution_map
    |> Enum.sort_by(fn {_committer_id, tp_ms} -> MapSet.size(tp_ms) end)
    |> List.first()
    |> elem(0)
  end

  defp remove_entry_from_committers_map(%__MODULE__{} = state, topic, partition) do
    state.committers_distribution
    |> Enum.find(fn {_committer_id, tp_ms} -> MapSet.member?(tp_ms, {topic, partition}) end)
    |> case do
      nil ->
        state

      {committer_id, ms} ->
        new_ms = MapSet.delete(ms, {topic, partition})
        new_commiter_map = Map.replace!(state.committers_distribution, committer_id, new_ms)

        %{state | committers_distribution: new_commiter_map}
    end
  end
end
