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
      default: 1000,
      doc:
        "Time in milliseconds that the consumer will try to fetch new data from the broker after it runs out of records to process"
    ],
    fetch_threshold_count: [
      type: :non_neg_integer,
      default: 1,
      doc:
        "Lower bound of pending processing records before the consumer issue a new fetch request."
    ],
    handler_cooldown_ms: [
      type: :non_neg_integer,
      default: 0,
      doc:
        "Time in milliseconds that the consumer will wait before handling new records. Can be overrided by the handler return"
    ],
    handler_strategy: [
      type: {:or, [{:in, [:unit]}, {:tuple, [{:in, [:batch]}, :pos_integer]}]},
      default: :unit,
      doc: """
      Defines which callback will be used for handling records. `handle_record/3` when `:unit` or `handle_record_batch/3` when `{:batch, non_neg_integer}`.

      For the batch strategy the second item on the tuple is the maximum number of records that will be delivered to the handler each processing cycle
      """
    ],
    handler_max_pending_commits: [
      type: :non_neg_integer,
      default: 0,
      doc: """
      Defines the maximum number of uncommitted processing cycles allowed before pausing the processing of new records.

      If set to 0, each cycle will wait for the previous commit to be acknowledged by the server before continuing.
      """
    ]
  ]

  defstruct Keyword.keys(@opts)

  def get_opts, do: @opts

  def from_map(map) do
    to_merge = Map.take(map, Keyword.keys(@opts))
    Map.merge(%__MODULE__{}, to_merge)
  end
end
