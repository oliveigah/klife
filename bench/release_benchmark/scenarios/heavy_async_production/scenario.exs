defmodule Klife.ReleaseBenchmark.Scenarios.HeavyAsyncProduction do
  alias Klife.ReleaseBenchmark.Workload
  @compile {:no_warn_undefined, Workload}

  def title, do: "Heavy asynchronous production"

  def cases(config) do
    for {window, level} <- Enum.with_index([1, 32, 1_024], 1),
        level in config.levels,
        profile <- config.profiles do
      %{
        module: __MODULE__,
        scenario: "heavy_async_production",
        variant: "callback",
        kind: :producer,
        operation: :async,
        level: level,
        profile: profile,
        callers: 1,
        window: window,
        scale: "outstanding_records=#{window}"
      }
    end
  end

  def settings(%{profile: "default"}), do: %{}

  def settings(_c),
    do: %{
      producer: [
        max_in_flight_requests: 1,
        batchers_count: 1,
        batch_size_bytes: 1_000_000,
        linger_ms: 0
      ],
      socket: [nodelay: true]
    }

  def run(c, context), do: Workload.throughput(c, context)
end
