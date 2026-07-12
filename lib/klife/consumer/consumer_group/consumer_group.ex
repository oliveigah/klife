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
      doc:
        "The name of the klife client to be used by the consumer group. May be set on " <>
          "`use` (binding the module at compile time) or passed to `start_link/1` " <>
          "(binding it on first start). See \"Consumer group module bindings\" in the moduledoc."
    ],
    topics: [
      type_doc: "List of `Klife.Consumer.ConsumerGroup.TopicConfig` configurations",
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
    # The reason to have a fetch_strategy in the consumer group level and not just set it on the topic config default is so we can
    # allow for 2 different goals. The consumer group level config allow for the automatic creation of a fetcher
    # that is intended to be used for all topics, while topic level one would create one specific for the topic.
    #
    # So this fetch strategy is not the same as the one defined on the "default_topic_config", because if you pass {:exclusive, opts} here
    # it will create only one fetcher and try to reuse it for every topic, but if you use {:exclusive, opts} inside the default_topic_config
    # it would start a new fetcher for every topic on the group.
    fetch_strategy: [
      type: {:custom, __MODULE__, :validate_fetch_strategy, []},
      type_doc: "`{:exclusive, fetcher_options}` or `{:shared, fetcher_name}`",
      doc: """
      Defines which `Klife.Consumer.Fetcher` is used by topics in this group that
      do not override the strategy in their own `Klife.Consumer.ConsumerGroup.TopicConfig`.

      - `{:exclusive, fetcher_options}`: starts a new fetcher dedicated to this group.
        `fetcher_options` follows `Klife.Consumer.Fetcher` configuration (`:name` is
        managed automatically and cannot be set here).
      - `{:shared, fetcher_name}`: reuses an existing fetcher (one already started
        by the client). All topics that do not override their strategy share it.

      Defaults to `{:shared, <client default fetcher>}`.
      """
    ],
    committers_count: [
      type: :pos_integer,
      default: 1,
      doc: "How many committer processes will be started for the consumer group"
    ],
    default_topic_config: [
      type: :keyword_list,
      required: false,
      keys: Klife.Consumer.ConsumerGroup.TopicConfig.get_opts_for_group(),
      default: [],
      doc:
        "`Klife.Consumer.ConsumerGroup.TopicConfig` that will serve as default for every topic on the group that does not explicitly set it."
    ]
  ]

  @moduledoc """
  Defines a consumer group.

  A consumer group coordinates the consumption of one or more topics across a set
  of cooperating member processes. Klife implements the new
  [KIP-848 rebalance protocol](https://cwiki.apache.org/confluence/display/KAFKA/KIP-848%3A+The+Next+Generation+of+the+Consumer+Rebalance+Protocol)
  introduced in Kafka 4.0, so partition assignment, heartbeats, and rebalances are
  handled by the broker coordinator and do not require any user-managed state machine.

  Each `use Klife.Consumer.ConsumerGroup` defines one consumer group module. The
  module is started under your supervision tree and, once running, the broker
  coordinator assigns it topic-partitions. For each assigned partition, the group
  starts a dedicated consumer process that fetches records and delivers them to
  your `c:handle_record_batch/4` callback.

  ## Defining a consumer group

  ```elixir
  defmodule MyApp.MyConsumerGroup do
    use Klife.Consumer.ConsumerGroup,
      client: MyApp.MyClient,
      group_name: "my_group_name",
      topics: [
        [name: "my_topic_1"],
        [name: "my_topic_2"]
      ]

    @impl true
    def handle_record_batch(_topic, _partition, _group_name, records) do
      Enum.each(records, &IO.inspect(&1.value))
      :commit
    end
  end
  ```

  > #### `use Klife.Consumer.ConsumerGroup` {: .info}
  >
  > When you `use Klife.Consumer.ConsumerGroup`, it will extend your module in two ways:
  >
  > - Implement the `Klife.Consumer.ConsumerGroup` behaviour, requiring at least
  > the `c:handle_record_batch/4` callback.
  >
  > - Define it as a `GenServer` that runs the consumer group machinery (heartbeats,
  > assignment handling, fetcher and committer lifecycle) and can be started under
  > your application's supervision tree.

  All options passed to `use` are merged with the options passed to `start_link/1`,
  with `start_link/1` arguments taking precedence. This allows the most common
  configuration to live alongside the module definition while still enabling
  per-instance overrides at startup time.

  ## Consumer group module bindings

  A consumer group module relates very differently to the `group_name` it runs
  under and the `Klife.Client` it talks to: the group name can vary freely from
  one start to the next, while the client is fixed for the life of the module.

  ### Group name: one module, many groups

  A module is not tied to a single group name. The `:group_name` may be set on
  `use` or passed to `start_link/1` (which takes precedence), and you can start
  the same module more than once with a different `:group_name` each time. Each
  instance runs as an independent group member with its own process, keyed by
  `{client, module, group_name}`, and its own assignments, consumer, and
  committer processes. This lets a single module definition serve several
  independently tracked groups (each group has its own committed offsets in
  Kafka) without defining a new module per group.

  ### Client: one module, one client

  Every consumer group module is bound to exactly one `Klife.Client`, exposed
  through the generated `klife_client/0`. There are two ways to establish the binding:

  - **At compile time**, passing `:client` to `use` as in the example above.
    `klife_client/0` is then a constant function.

  - **At start time**, omitting `:client` from `use` and passing it to
    `start_link/1` instead. On the first start the module is bound to that
    client through a [persistent term](`:persistent_term`) whose key is
    `{Klife.Consumer.ConsumerGroup, YourModule}`, and `klife_client/0` reads
    it (returning `nil` before the first start). This exists so libraries can
    ship a single consumer group module that works with whatever client the
    host application configures (e.g. `broadway_klife`). Do not write to that
    persistent term yourself.

  Unlike the group name, this binding is permanent: starting the module with a
  `:client` different from the one it is bound to raises an `ArgumentError`,
  since the running machinery and the module wrappers would otherwise disagree
  about which client to talk to. To consume through a different client, define
  another consumer group module.

  ## Configuration options

  #{NimbleOptions.docs(@consumer_group_opts)}

  ## Topic configuration

  Each entry of `:topics` is a `Klife.Consumer.ConsumerGroup.TopicConfig`. The
  group's `:default_topic_config` provides defaults applied to every topic that
  does not explicitly override them:

  ```elixir
  use Klife.Consumer.ConsumerGroup,
    client: MyApp.MyClient,
    group_name: "my_group",
    default_topic_config: [
      handler_max_unacked_commits: 100,
      offset_reset_policy: :earliest
    ],
    topics: [
      [name: "topic_a"],
      [name: "topic_b", offset_reset_policy: :latest]
    ]
  ```

  Above, `topic_a` inherits both defaults, while `topic_b` overrides
  `:offset_reset_policy` and inherits `:handler_max_unacked_commits`.

  ## Delivery semantics

  Klife provides at-least-once delivery: every record is guaranteed to be
  delivered to `c:handle_record_batch/4` at least once, but may be delivered
  more than once after a hard failure (member crash, network split, liveness
  timeout). Handlers must be idempotent to tolerate duplicates.

  Graceful partition revocation does not cause reprocessing: the consumer
  waits for every in-flight record to be committed before releasing the
  partition. Reprocessing only occurs when the consumer is unable to commit
  before losing the assignment.

  The window of records exposed to reprocessing is bounded by
  `:handler_max_unacked_commits` (a `TopicConfig` option):

  - `0` (default): each batch must be fully committed before the next is
  delivered. Reprocessing on failure is limited to the records of the most
  recent in-flight batch.
  - `N > 0`: up to `N` processed records may be waiting for commit at any
  time. This unlocks commit pipelining and higher throughput, but on a hard
  failure those records may be redelivered.

  ### Retrying records

  Klife's per-record `:commit`/`:retry` control on `c:handle_record_batch/4`
  is more granular than what Kafka itself tracks: Kafka stores a single
  committed offset per partition for each consumer group, and on resume the
  consumer always picks up from there.

  This gap leaves room for a misuse pattern where a batch returns `:commit`
  for a record and `:retry` for one with a lower offset in the same
  partition. For example, committing record `2` while asking record `1`
  to be retried. While the consumer is running, Klife keeps `1` in its
  in-process queue and re-delivers it on the next cycle. But if the
  consumer restarts or the partition is revoked before `1` is committed,
  the broker only knows about the commit of `2`: the retry queue is lost
  and `1` would be silently skipped. To prevent this, Klife detects the
  pattern and raises.

  To stay aligned with Kafka semantics, never retry a record whose offset
  is lower than any record committed in the same batch. When a record
  fails, choose one of:

  - Retry the failing record together with every successful record after
  it, accepting that the successful ones will be reprocessed once the
  failing one eventually succeeds.
  - Commit the failing record and route it elsewhere (e.g. a dead-letter
  topic) so processing can move forward.

  ## Fetch strategies

  Every partition consumer fetches records through a `Klife.Consumer.Fetcher`,
  and which fetcher serves a topic is decided in two layers: the consumer
  group's `:fetch_strategy` sets a default for all its topics, and any
  `TopicConfig` can override that default for itself.

  The same two strategies, `{:shared, fetcher_name}` and
  `{:exclusive, fetcher_options}`, are accepted at both levels, but the
  *scope* of `:exclusive` differs:

  - `{:exclusive, opts}` at the **group level** starts one new fetcher
  dedicated to the consumer group. Every topic that does not override the
  strategy shares it.
  - `{:exclusive, opts}` at the **topic level** starts one new fetcher
  dedicated to that single topic, not shared with anything else.

  `{:shared, fetcher_name}` behaves identically at both levels: it reuses an
  existing fetcher (one already started by the client) for whatever scope it
  is set on.

  When the group's `:fetch_strategy` is unset, it falls back to
  `{:shared, <client default fetcher>}`, so topics in the group share the
  client's default fetcher with every other consumer of it.

  Override at the group level when the entire group needs an isolated fetch
  pipeline (e.g. its own batchers or `max_bytes_per_request`). Override at
  the topic level when a single noisy or latency-sensitive topic should not
  share its fetcher with the rest of the group.

  ## How many committers?

  Offset commits are dispatched by dedicated committer processes shared across
  the partitions of the group. A single committer is enough for most workloads.

  Before raising `:committers_count`, check whether the apparent bottleneck is
  committer dispatch or simply commit RTT pacing the handler, see
  [Tuning for throughput](`m:Klife.Consumer.ConsumerGroup.TopicConfig#tuning-for-throughput`).
  Raising `:handler_max_unacked_commits` decouples handler cadence from commit
  latency and resolves most apparent "commit bottleneck" symptoms without
  adding parallelism.

  Increase `:committers_count` only when the committer process itself can't
  keep up, typically a group with many actively committing partitions where
  profiling shows the committer as the bottleneck. This comes at the cost of
  per-commit batching efficiency, since partitions are split across committers.
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

  - `:commit`: commits all records in the batch.
  - `:retry`: retries the entire batch.
  - `{action, callback_opts}`: same as above, with options.

  ## Per-record control

  Return a list of `{action, record}` tuples for fine-grained control. Records
  tagged with `:commit` have their offsets advanced; records tagged with `:retry`
  are re-delivered in the next batch.

  The list must not commit any record at a higher offset than a retried one
  in the same batch — Klife raises in that case. See
  [Retrying records](`m:Klife.Consumer.ConsumerGroup#module-retrying-records`)
  in the moduledoc for the rationale and safe patterns. The example below
  applies the standard "stop on first failure" shape:

  ```elixir
  def handle_record_batch(_topic, _partition, _group_name, records) do
    case Enum.split_while(records, fn record -> process(record) == :ok end) do
      {_ok, []} ->
        :commit

      {ok, retry} ->
        Enum.map(ok, &{:commit, &1}) ++ Enum.map(retry, &{:retry, &1})
    end
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
  Called when a consumer process is stopped for a topic-partition.

  The `reason` reflects why the consumer terminated and depends on the trigger:

  - On a partition revocation initiated by the group, the reason is
    `{:shutdown, {:assignment_revoked, topic_id, partition_index}}`.
  - On a normal group shutdown, it follows the standard GenServer termination
    semantics (e.g. `:normal`, `:shutdown`).
  - On unexpected termination (callback raise, liveness timeout, internal error),
    it carries the underlying exit reason.
  """
  @callback handle_consumer_stop(
              topic :: String.t(),
              partition :: integer,
              group_name :: String.t(),
              reason :: term
            ) :: :ok

  @optional_callbacks [handle_record_batch: 4, handle_consumer_start: 3, handle_consumer_stop: 4]

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
    quote bind_quoted: [opts: opts] do
      use GenServer

      @behaviour Klife.Consumer.ConsumerGroup

      # klife_client/0 is called on every pull/commit/assigned_partitions, so
      # it must stay cheap. When :client is given to `use` it is a constant
      # function; otherwise it reads the persistent term populated by the first
      # start_link/1 (nil until then), so a single module can be bound to a
      # client chosen at runtime. See "Consumer group module bindings" in the moduledoc.
      if opts[:client] do
        def klife_client(), do: unquote(opts[:client])
      else
        def klife_client(),
          do: :persistent_term.get({Klife.Consumer.ConsumerGroup, __MODULE__}, nil)
      end

      @doc """
      Pulls the next buffered batch from a `:manual` mode topic-partition.

      See `Klife.Consumer.ConsumerGroup.pull/6`. The client and consumer group
      module are filled in automatically.
      """
      def pull(group_name, topic, partition, opts \\ []) do
        Klife.Consumer.ConsumerGroup.pull(
          klife_client(),
          __MODULE__,
          group_name,
          topic,
          partition,
          opts
        )
      end

      @doc """
      Commits an offset for a `:manual` mode topic-partition.

      See `Klife.Consumer.ConsumerGroup.commit/6`. The client and consumer group
      module are filled in automatically.
      """
      def commit(group_name, topic, partition, offset) do
        Klife.Consumer.ConsumerGroup.commit(
          klife_client(),
          __MODULE__,
          group_name,
          topic,
          partition,
          offset
        )
      end

      @doc """
      Returns the `{topic, partition}` tuples currently assigned to this node.

      See `Klife.Consumer.ConsumerGroup.assigned_partitions/3`. The client and
      consumer group module are filled in automatically.
      """
      def assigned_partitions(group_name) do
        Klife.Consumer.ConsumerGroup.assigned_partitions(
          klife_client(),
          __MODULE__,
          group_name
        )
      end

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

  @doc false
  def get_opts(), do: @consumer_group_opts

  @doc false
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

  @doc false
  def start_link(cg_mod, args) do
    group_defaults = Keyword.get(args, :default_topic_config, [])

    # This has to be done here, because nimble options populate the defaults automatically on validate!
    args =
      Keyword.update!(args, :topics, fn tc_list ->
        Enum.map(tc_list, fn tc_kw ->
          Keyword.merge(group_defaults, tc_kw)
        end)
      end)

    base_validated_args =
      NimbleOptions.validate!(args, @consumer_group_opts)

    client = Keyword.fetch!(base_validated_args, :client)

    validate_topic_modes!(cg_mod, base_validated_args)

    :ok = bind_client!(cg_mod, client)

    base_validated_args =
      Keyword.put_new_lazy(base_validated_args, :fetch_strategy, fn ->
        {:shared, client.get_default_fetcher()}
      end)

    map_args = Helpers.keyword_list_to_map(base_validated_args)

    validated_args =
      %__MODULE__{}
      |> Map.from_struct()
      |> Map.merge(map_args)
      |> Map.put(:mod, cg_mod)
      |> Map.put(:member_id, UUID.uuid4())

    if ConnController.disabled_feature?(client, :consumer_group) do
      raise "Consumer Group was started but consumer_group feature is disabled for client #{inspect(client)}. Check logs for details."
    end

    GenServer.start_link(cg_mod, validated_args,
      name: get_process_name(client, cg_mod, validated_args.group_name)
    )
  end

  # :auto mode delivers records through handle_record_batch/4, so it only makes
  # sense when the consumer group module actually implements it. Callback-less
  # modules (e.g. the one broadway_klife ships) are manual-only.
  defp validate_topic_modes!(cg_mod, validated_args) do
    non_manual_topics =
      validated_args
      |> Keyword.fetch!(:topics)
      |> Enum.reject(fn tc -> tc[:mode] == :manual end)
      |> Enum.map(fn tc -> tc[:name] end)

    cond do
      non_manual_topics == [] ->
        :ok

      not handle_record_batch_exported?(cg_mod) ->
        raise ArgumentError,
              "#{inspect(cg_mod)} does not implement handle_record_batch/4, which is " <>
                "required to consume topics in :auto mode " <>
                "(#{inspect(non_manual_topics)}). Implement the callback or set " <>
                "mode: :manual on these topics."

      true ->
        :ok
    end
  end

  defp handle_record_batch_exported?(cg_mod) do
    Code.ensure_loaded?(cg_mod) and function_exported?(cg_mod, :handle_record_batch, 4)
  end

  # A consumer group module is permanently bound to a single client: everything
  # the group runs resolves the client through klife_client/0, so accepting a
  # divergent :client at start would split the group between two clients.
  defp bind_client!(cg_mod, client) do
    case cg_mod.klife_client() do
      nil ->
        :persistent_term.put({__MODULE__, cg_mod}, client)

      ^client ->
        :ok

      # There is a bug here! If 2 processes run start_link at the same time
      # passing different clients, this validation wont catch it! This should be very unlikely
      # to happen and documentation is already explicit that this should not be done and this
      # check is just a guardrail so I wont solve the problem now.
      other_client ->
        raise ArgumentError,
              "#{inspect(cg_mod)} is already bound to the client " <>
                "#{inspect(other_client)} and cannot be started with client: " <>
                "#{inspect(client)}. A consumer group module is permanently bound " <>
                "to a single client; define another consumer group module to " <>
                "consume through a different client."
    end
  end

  defp get_process_name(client_name, cg_mod, group_name) do
    via_tuple({__MODULE__, client_name, cg_mod, group_name})
  end

  @doc """
  Pulls the next buffered batch of records from a `:manual` mode topic-partition consumer.

  Only valid for topic-partitions whose `Klife.Consumer.ConsumerGroup.TopicConfig`
  has `mode: :manual`.

  Pulled records must be committed via `commit/6` once processed. The consumer's
  revoke handshake waits for all pulled offsets to be committed or timeout before releasing
  the partition, this behaviour may lead to slower rebalances if not handled correctly.

  ## Ownership

  Pulled records exist only in the receiving process memory until their offsets
  are committed, so the consumer treats them as leased to an owner process:

  - The owner defaults to the calling process and can be overridden with the
    `:owner` option (e.g. pull from a helper process while a long-lived process
    owns the lease and issues the commits).
  - The consumer monitors the owner. If the owner dies while the lease has
    uncommitted offsets, the consumer restarts and the records are redelivered
    from the last committed offset (at-least-once is preserved). If the owner
    dies with everything committed, the lease is simply released.
  - One owner per topic-partition at a time: pulling from a new owner while a
    previous owner still has uncommitted offsets restarts the consumer the same
    way, returning `{:error, :restarting}` to the new owner.

  ## Options

  - `:owner` - pid that owns the pulled records lease. Defaults to the caller.
  """
  @spec pull(
          client :: atom(),
          cg_mod :: module(),
          group_name :: String.t(),
          topic :: String.t(),
          partition :: integer(),
          opts :: [{:owner, pid()}]
        ) :: {:ok, [Klife.Record.t()] | :empty} | {:error, :restarting}
  def pull(client_name, cg_mod, group_name, topic_name, partition, opts \\ []) do
    topic_id =
      MetadataCache.get_metadata_attribute(client_name, topic_name, partition, :topic_id)

    client_name
    |> Consumer.get_process_name(cg_mod, topic_id, partition, group_name)
    |> GenServer.call({:pull, opts})
  end

  @doc """
  Commits an offset for a `:manual` mode topic-partition consumer.

  Only valid for topic-partitions whose `Klife.Consumer.ConsumerGroup.TopicConfig`
  has `mode: :manual`. The commit is dispatched through the consumer group's
  shared `Klife.Consumer.Committer` and is fire-and-forget from the caller's
  perspective — there is no synchronous confirmation that the offset reached
  the coordinator. The returned `:ok` only means the commit request was queued.

  The committed offset must not exceed the highest offset returned by `pull/5`
  for this partition; passing an unprocessed offset will leak commits ahead of
  what was actually processed.
  """
  @spec commit(
          client :: atom(),
          cg_mod :: module(),
          group_name :: String.t(),
          topic :: String.t(),
          partition :: integer(),
          offset :: integer()
        ) :: :ok
  def commit(client_name, cg_mod, group_name, topic_name, partition, offset) do
    topic_id =
      MetadataCache.get_metadata_attribute(client_name, topic_name, partition, :topic_id)

    client_name
    |> Consumer.get_process_name(cg_mod, topic_id, partition, group_name)
    |> GenServer.call({:commit, offset})
  end

  @doc """
  Returns the `{topic_name, partition}` tuples currently assigned to this node
  for the given consumer group.
  """
  @spec assigned_partitions(
          client :: atom(),
          cg_mod :: module(),
          group_name :: String.t()
        ) :: [{String.t(), integer()}]
  def assigned_partitions(client_name, cg_mod, group_name) do
    table = get_acked_topic_partitions_table(client_name, cg_mod, group_name)

    case :ets.whereis(table) do
      :undefined ->
        []

      tid ->
        tid
        |> :ets.tab2list()
        |> Enum.map(fn {{topic_id, partition}} ->
          {MetadataCache.get_topic_name_by_id!(client_name, topic_id), partition}
        end)
    end
  end

  @doc false
  def get_member_epoch(cg_pid) do
    GenServer.call(cg_pid, :member_epoch)
  end

  @doc false
  def init(mod, args_map) do
    Process.flag(:trap_exit, true)

    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    :ets.new(get_acked_topic_partitions_table(args_map.client, mod, args_map.group_name), [
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
        client_name: args_map.client,
        member_id: args_map.member_id,
        epoch: 0,
        heartbeat_interval_ms: 1_000,
        assigned_topic_partitions: [],
        consumer_supervisor: consumer_sup_pid,
        internal_supervisor: nil,
        consumers_monitor_map: %{},
        fetch_strategy: args_map.fetch_strategy,
        committers_count: args_map.committers_count,
        committers_distribution: %{},
        default_topic_config: args_map.default_topic_config
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

  @doc false
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

  @doc false
  def processing_allowed?(client_name, cg_mod, topic_id, partition, cg_name) do
    client_name
    |> get_acked_topic_partitions_table(cg_mod, cg_name)
    |> :ets.member({topic_id, partition})
  end

  @doc false
  def handle_member_epoch(%__MODULE__{} = state) do
    {:reply, state.epoch, state}
  end

  @doc false
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

    # OffsetFetch returns offsets on the Kafka convention (the next offset to
    # be consumed), while internally the consumer tracks the last processed
    # one, so committed values are shifted back by 1. Entries without a
    # committed offset (-1) are replaced by the reset map on the merge below.
    parsed_offset_fetch_result =
      Map.new(offset_fetch_result, fn
        {tp, offset} when offset >= 0 -> {tp, offset - 1}
        {tp, offset} -> {tp, offset}
      end)

    tid_map = tname_map |> Enum.map(fn {tname, tid} -> {tid, tname} end) |> Map.new()

    Map.merge(parsed_offset_fetch_result, reset_offset_map)
    |> Enum.map(fn {{tname, p}, offset} -> {{tid_map[tname], p}, offset} end)
    |> Map.new()
  end

  @doc false
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

  @doc false
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

  @doc false
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
        try do
          :ok =
            Consumer.revoke_assignment(state.client_name, state.mod, tid, p, state.group_name)
        catch
          # The consumer is already gone (e.g. stopped after its puller died) or
          # died mid-handshake. There is nothing left to wait for and the leave
          # heartbeat below must still go out, so treat it as revoked.
          :exit, _reason -> :ok
        end
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
      "Assignment revoked #{topic_name}:#{partition} for consumer group #{state.group_name} running module #{state.mod}",
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
      "Assignment received #{topic_name}:#{partition} for consumer group #{state.group_name} running module #{state.mod}",
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
