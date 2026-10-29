defmodule Klife.ReleaseBenchmark.Scenarios.CatchupLag do
  alias Klife.ReleaseBenchmark.Workload
  @compile {:no_warn_undefined, Workload}

  def title, do: "Catch-up lag"

  def cases(config) do
    for {partitions, level} <- Enum.with_index([1, 6, 24], 1),
        level in config.levels,
        strategy <- [:shared, :exclusive],
        profile <- config.profiles do
      %{
        module: __MODULE__,
        scenario: "catchup_lag",
        variant: to_string(strategy),
        kind: :consumer,
        strategy: strategy,
        partitions: partitions,
        records_per_partition: config.records_per_partition,
        level: level,
        profile: profile,
        scale:
          "partitions_per_topic=#{partitions},records_per_partition=#{config.records_per_partition}"
      }
    end
  end

  def settings(%{profile: "default"}), do: %{}

  def settings(_c),
    do: %{
      fetcher: [
        batchers_count: min(8, max(1, ceil(System.schedulers_online() / 3))),
        max_bytes_per_request: 20_000_000,
        max_wait_ms: 0
      ],
      topic: [
        fetch_interval_ms: 1,
        handler_max_unacked_commits: 100_000,
        fetch_max_bytes: 4_000_000,
        max_queue_size: 10
      ],
      socket: [nodelay: true]
    }

  def run(c, context), do: Workload.catchup(c, context)

  # Kafka commits the next offset; a missing commit (-1) still leaves the whole backlog.
  def remaining_lag(topics, target, response) do
    expected = for {topic, partitions} <- topics, p <- 0..(partitions - 1), do: {topic, p}

    observed =
      for topic <- response,
          partition <- topic.partitions,
          do: {{topic.name, partition.partition_index}, partition}

    keys = Enum.map(observed, &elem(&1, 0))

    unless length(keys) == length(expected) and MapSet.new(keys) == MapSet.new(expected),
      do: raise("Incomplete committed-offset response in catch-up workload")

    Enum.reduce(observed, 0, fn {_tp, partition}, acc ->
      %{error_code: 0, committed_offset: offset} = partition

      unless is_integer(offset) and offset >= -1 and offset <= target,
        do: raise("Unexpected committed offset in catch-up workload")

      acc + target - max(offset, 0)
    end)
  end
end
