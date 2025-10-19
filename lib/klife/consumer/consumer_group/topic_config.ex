defmodule Klife.Consumer.ConsumerGroup.TopicConfig do
  @opts [
    name: [
      type: :string,
      required: true,
      doc: "Name of the topic the consumer group will consume records from"
    ],
    fetcher_name: [
      type: {:or, [:atom, :string]},
      doc:
        "Fetcher name to be used by the consumers of this topic. Overrides the one defined on the consumer group."
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
      The maximum number of items the consumer can keep on its internal queue. Defaults to `100 * handler_max_batch_size`
      """
    ],
    fetch_interval_ms: [
      type: :non_neg_integer,
      default: 5000,
      doc: """
      Time in milliseconds that the consumer will wait before trying to fetch new data from the broker after it runs out of records to process.

      The consumer always tries to optimize fetch requests wait times by issuing requests before it's internal queue is empty (the current threshold is
      2 * handler_max_batch_size). Therefore this option is only used for the wait time after a fetch request returns empty.
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
      type: :pos_integer,
      default: 10,
      doc:
        "The maximum amount of records that will be delivered to the handler in each processing cycle."
    ],
    # TODO: Implement transactional true
    handler_is_transactional: [
      type: :boolean,
      default: false,
      doc: """
      Determines whether producer calls are executed inside a transaction linked to the consumer’s offset commit.

      * `true` — Producer calls are executed within a transaction. The transaction is committed together with the consumer’s offset commit.
        Use this when following a **consume → process → produce** workflow (e.g., Kafka Streams) and you need offsets and produced records to be persisted atomically.
        Note: Transactions incur additional overhead, reducing throughput and resource efficiency in exchange for stronger consistency.

      * `false` — Producer calls run independently of the consumer. Produced records are not tied to offset commits.
        This can result in reprocessing of messages or duplicates if commit failures occur. To handle duplicates safely, implement application-level idempotency.
        This mode maximizes performance and minimizes resource usage.
      """
    ]
  ]

  defstruct Keyword.keys(@opts)

  def get_opts, do: @opts

  def from_map(map, cg_data) do
    to_merge = Map.take(map, Keyword.keys(@opts))

    base_tc = Map.merge(%__MODULE__{}, to_merge)

    base_tc
    |> Map.update!(:max_queue_size, fn v ->
      if v == nil, do: base_tc.handler_max_batch_size * 100, else: v
    end)
    |> Map.update!(:fetcher_name, fn v ->
      if v == nil, do: cg_data.fetcher_name, else: v
    end)
  end
end
