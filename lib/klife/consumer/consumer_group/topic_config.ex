defmodule Klife.Consumer.ConsumerGroup.TopicConfig do
  @opts [
    name: [
      type: :string,
      required: true,
      doc: "Name of the topic the consumer group will subscribe to"
    ],
    bytes_per_request: [
      type: :non_neg_integer,
      default: 500_000,
      doc:
        "The maximum amount of bytes to fetch in a single request. Must be lower than fetcher config `max_bytes_per_request`"
    ],
    fetcher_name: [
      type: {:or, [:atom, :string]},
      doc:
        "Fetcher name to be used by the consumers of this topic. Overrides the one defined on the consumer group."
    ]
  ]

  def get_opts, do: @opts
end
