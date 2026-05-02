defmodule Klife.Consumer.ConsumerGroup.TopicConfig do
  @opts [
    name: [
      type: :string,
      required: true,
      doc: "Name of the topic the consumer group will consume records from"
    ],
    fetch_strategy: [
      type: {:custom, Klife.Consumer.ConsumerGroup, :validate_fetch_strategy, []},
      type_doc: "`{:exclusive, fetcher_options}` or `{:shared, fetcher_name}`",
      doc: """
      Overrides the fetch strategy defined at the consumer group level for this topic.

      The override semantics differ slightly from the group-level option:

      - `{:exclusive, fetcher_options}`: starts a new fetcher dedicated to this
        single topic (not shared with other topics in the group).
      - `{:shared, fetcher_name}`: uses the given pre-existing fetcher only for
        this topic.

      If not set, the topic uses the fetcher selected by the consumer group's
      `:fetch_strategy`.
      """
    ],
    isolation_level: [
      type: {:in, [:read_committed, :read_uncommitted]},
      doc: "May override the isolation level defined on the consumer group",
      default: :read_committed
    ],
    offset_reset_policy: [
      type: {:in, [:latest, :earliest]},
      default: :latest,
      doc:
        "Define from which offset the consumer will start processing records when no previous committed offset is found."
    ],
    fetch_max_bytes: [
      type: :non_neg_integer,
      default: 1_000_000,
      doc: """
      The maximum amount of bytes to fetch in a single request. Must be lower than fetcher config `max_bytes_per_request`.
      """
    ],
    max_queue_size: [
      type: :non_neg_integer,
      doc: """
      The maximum number of record batches that the consumer can keep on its internal queue.
      Defaults to 5 if `:handler_max_batch_size` is `:dynamic`, otherwise defaults to 20.
      """
    ],
    fetch_interval_ms: [
      type: :non_neg_integer,
      default: 1000,
      doc: """
      Time in milliseconds that the consumer will wait before trying to fetch new data from the broker after it runs out of records to process.

      The consumer always tries to optimize fetch requests wait times by issuing requests before it's internal queue is empty (the current threshold is
      1 batch). Therefore this option is only used for the wait time after a fetch request returns empty.
      """
    ],
    handler_cooldown_ms: [
      type: :non_neg_integer,
      default: 0,
      doc: """
      Time in milliseconds that the consumer will wait before handling new records. Can be overrided for one cycle by the handler return value.
      """
    ],
    handler_max_unacked_commits: [
      type: :non_neg_integer,
      default: 0,
      doc: """
      Controls how many records can be waiting for commit confirmation before the consumer stops processing new records.

      When this limit is reached, processing pauses until confirmations are received.

      Set it to 0 to process records one batch at a time so each processing cycle must be fully committed before starting the next.
      """
    ],
    handler_max_batch_size: [
      type: {:or, [:pos_integer, {:in, [:dynamic]}]},
      default: :dynamic,
      doc: """
      The maximum amount of records that will be delivered to the handler in each processing cycle. If `:dynamic` all records retrieved
      in the fetch request will be delivered as one single batch to the handler. If positive integer, retrieved records will be chunked
      into the provided size.
      """
    ]
    # TODO: Implement transactional true
    # handler_is_transactional: [
    #   type: :boolean,
    #   default: false,
    #   doc: """
    #   Determines whether producer calls are executed inside a transaction linked to the consumer's offset commit.

    #   * `true`: Producer calls are executed within a transaction. The transaction is committed together with the consumer's offset commit.
    #     Use this when following a **consume → process → produce** workflow (e.g., Kafka Streams) and you need offsets and produced records to be persisted atomically.
    #     Note: Transactions incur additional overhead, reducing throughput and resource efficiency in exchange for stronger consistency.

    #   * `false`: Producer calls run independently of the consumer. Produced records are not tied to offset commits.
    #     This can result in reprocessing of messages or duplicates if commit failures occur. To handle duplicates safely, implement application-level idempotency.
    #     This mode maximizes performance and minimizes resource usage.
    #   """
    # ]
  ]

  @moduledoc """
  Defines a topic configuration for a `Klife.Consumer.ConsumerGroup`.

  Each entry of the consumer group's `:topics` option is a `TopicConfig` keyword
  list, controlling how a single topic is consumed inside the group.

  ## Configuration options

  #{NimbleOptions.docs(@opts)}

  ## Configuration inheritance

  Each option resolves in the following order, from highest to lowest precedence:

  1. The value set directly on the topic entry inside `:topics`.
  2. The value set on the consumer group's `:default_topic_config`.
  3. The built-in default shown above.

  ## Tuning for throughput

  Effective throughput is the product of how many records each handler call
  processes (`:handler_max_batch_size`) and how often the handler runs. With
  the default `:handler_max_unacked_commits` of `0`, each batch must be fully
  committed before the next is delivered, so every batch incurs one commit
  roundtrip to the coordinator. This means small batches under the default
  commit policy degenerate into one network roundtrip per record.

  Two ways to keep throughput up:

  - Leave `:handler_max_batch_size` as `:dynamic` (the default) or a high value,
  amortizing the commit roundtrip across many records.
  - Raise `:handler_max_unacked_commits` when smaller, fixed-size batches are
  required for memory or latency reasons. The handler keeps processing while
  a commit is in flight, and pending higher offsets are coalesced into the
  next commit request, decoupling handler cadence from commit latency.

  `:max_queue_size` caps how many fetched batches the consumer may buffer
  in-process before throttling further fetches. Its default is paired with
  `:handler_max_batch_size`: `5` for dynamic batches (each can be large), `20`
  for fixed-size ones. Override it when you need a tighter memory bound or
  deeper prefetch.
  """

  defstruct Keyword.keys(@opts)

  @doc false
  def get_opts, do: @opts

  @doc false
  def get_opts_for_group, do: Keyword.drop(@opts, [:name])

  @doc false
  def from_map(map, cg_data) do
    to_merge = Map.take(map, Keyword.keys(@opts))

    base_tc = Map.merge(%__MODULE__{}, to_merge)

    base_tc
    |> Map.update!(:max_queue_size, fn v ->
      cond do
        v != nil -> v
        base_tc.handler_max_batch_size == :dynamic -> 5
        true -> 20
      end
    end)
    |> Map.update!(:fetch_strategy, fn v ->
      # At this point the consumer group fetch strategy is already parsed to
      # a name instead of a configuration, so it is safe to just reuse its value
      if v == nil, do: cg_data.fetch_strategy, else: v
    end)
  end
end
