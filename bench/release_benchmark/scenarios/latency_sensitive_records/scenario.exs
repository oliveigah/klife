defmodule Klife.ReleaseBenchmark.Scenarios.LatencySensitiveRecords do
  alias Klife.ReleaseBenchmark.Workload
  @compile {:no_warn_undefined, Workload}

  def title, do: "Latency-sensitive records"

  def cases(config) do
    for {rate, level} <- Enum.with_index([10, 100, 1_000], 1),
        level in config.levels,
        strategy <- [:shared, :exclusive],
        profile <- config.profiles do
      %{
        module: __MODULE__,
        scenario: "latency_sensitive_records",
        variant: to_string(strategy),
        kind: :latency,
        strategy: strategy,
        rate: rate,
        partitions: 1,
        level: level,
        profile: profile,
        scale: "offered_records/s=#{rate},partitions_per_topic=1"
      }
    end
  end

  def settings(%{profile: "default"}), do: %{}

  def settings(_c),
    do: %{
      producer: [max_in_flight_requests: 5, batchers_count: 1, linger_ms: 0],
      fetcher: [batchers_count: 1, max_wait_ms: 0, linger_ms: 0],
      topic: [
        fetch_interval_ms: 1,
        handler_max_unacked_commits: 100_000
      ],
      socket: [nodelay: true]
    }

  def run(c, context), do: Workload.latency(c, context)
end
