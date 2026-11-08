defmodule Klife.ReleaseBenchmark.Scenarios.LongPollInterference do
  alias Klife.ReleaseBenchmark.Workload
  @compile {:no_warn_undefined, Workload}

  def title, do: "Long-poll interference"

  def cases(config) do
    for {max_wait_ms, level} <- Enum.with_index([0, 1_000, 5_000], 1),
        level in config.levels,
        profile <- config.profiles do
      %{
        module: __MODULE__,
        scenario: "long_poll_interference",
        variant: "sync_single",
        kind: :long_poll,
        operation: :single,
        level: level,
        profile: profile,
        callers: 8,
        batch: 1,
        max_wait_ms: max_wait_ms,
        scale: "idle_fetch_max_wait_ms=#{max_wait_ms},concurrent_callers=8"
      }
    end
  end

  def settings(%{profile: "default"}), do: %{}

  # The same producer tuning as heavy synchronous production, so only the long polls differ
  def settings(_c),
    do: %{
      producer: [max_in_flight_requests: 1, batchers_count: 1, linger_ms: 0],
      socket: [nodelay: true]
    }

  def run(c, context), do: Workload.long_poll(c, context)
end
