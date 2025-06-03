defmodule Klife.Consumer.ConsumerGroup.TopicConfig do
  @opts [
    name: [
      type: :string,
      required: true,
      doc: "Name of the topic the consumer group will subscribe to"
    ],
    fetcher_name: [
      type: {:or, [:atom, :string]},
      doc:
        "Fetcher name to be used by the consumers of this topic. Overrides the one defined on the consumer group."
    ],
    fetch_max_bytes: [
      type: :non_neg_integer,
      default: 500_000,
      doc:
        "The maximum amount of bytes to fetch in a single request. Must be lower than fetcher config `max_bytes_per_request`"
    ],
    fetch_interval_ms: [
      type: :non_neg_integer,
      default: 5000,
      doc: """
      Time in milliseconds that the consumer will try to fetch new data from the broker after it runs out of records to process.

      The consumer always tries to optimize fetch requests wait times by issuing requests before it's internal queue is empty. Therefore
      this option is only used for the wait time after a fetch request returns empty.
      """
    ],
    handler_cooldown_ms: [
      type: :non_neg_integer,
      default: 0,
      doc: """
      Time in milliseconds that the consumer will wait before handling new records. Can be overrided for one cycle by the handler return value.
      """
    ],
    handler_max_pending_commits: [
      type: :non_neg_integer,
      default: 0,
      doc: """
      Defines the maximum number of uncommitted processing cycles allowed before pausing the processing of new records.

      If set to 0, a new processing cycle will start only after the previous one is fully commited on the broker.
      """
    ],
    handler_max_batch_size: [
      type: :pos_integer,
      default: 10,
      doc:
        "The maximum amount of records that will be delivered to the handler in each processing cycle."
    ]
  ]

  defstruct Keyword.keys(@opts)

  def get_opts, do: @opts

  def from_map(map) do
    to_merge = Map.take(map, Keyword.keys(@opts))
    Map.merge(%__MODULE__{}, to_merge)
  end
end
