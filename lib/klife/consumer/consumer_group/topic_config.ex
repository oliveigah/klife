defmodule Klife.Consumer.ConsumerGroup.TopicConfig do
  @opts [
    name: [
      type: :string,
      required: true,
      doc: "Name of the topic the consumer group will consume records from"
    ],
    fetch_strategy: [
      type: {:custom, Klife.Consumer.ConsumerGroup, :validate_fetch_strategy, []},
      doc: """
      May override the fetch_strategy defined on the consumer group
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
  Defines per-topic configuration for a `Klife.Consumer.ConsumerGroup`.

  Each entry in the consumer group's `:topics` list is validated against these options.
  Topic-level settings override the corresponding group-level defaults when provided
  (e.g. `fetch_strategy`, `isolation_level`).

  ## Options

  #{NimbleOptions.docs(@opts)}

  ## Fetch strategy override

  By default each topic inherits the consumer group's `fetch_strategy`. Setting it
  at the topic level creates (or shares) a fetcher exclusively for that topic,
  which is useful when a single topic has very different throughput or latency
  requirements from the rest of the group.

  ## Batch size and queue depth

  The `handler_max_batch_size` and `max_queue_size` options work together to control
  memory usage and processing granularity:

  - With `handler_max_batch_size: :dynamic` (default), the consumer delivers all
  records from a single fetch response as one batch, and `max_queue_size` defaults
  to 5.
  - With a fixed `handler_max_batch_size`, fetched records are chunked into smaller
  batches, and `max_queue_size` defaults to 20 to compensate for the smaller batches.

  ## Pipelining with `handler_max_unacked_commits`

  Setting `handler_max_unacked_commits` to a value greater than 0 allows the consumer
  to process new batches while previous commits are still in flight. This increases
  throughput but means more records may be re-processed after a crash, since uncommitted
  offsets are lost.

  With the default of `0`, each batch must be fully committed before the next one is
  processed — the safest option.
  """

  defstruct Keyword.keys(@opts)

  def get_opts, do: @opts

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
      if v == nil, do: cg_data.fetch_strategy, else: v
    end)
  end
end
