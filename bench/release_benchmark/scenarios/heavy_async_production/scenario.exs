defmodule Klife.ReleaseBenchmark.Scenarios.HeavyAsyncProduction do
  alias Klife.ReleaseBenchmark.Workload
  @compile {:no_warn_undefined, Workload}

  def title, do: "Heavy asynchronous production"

  def cases(config) do
    # "pipelined" tries the configuration guide's high-throughput example (more batchers and
    # requests in flight) against the optimized profile's single batcher and request;
    # "pipelined_linger" adds the guide's 1 ms linger for few pending records
    for {window, level} <- Enum.with_index([1, 32, 1_024], 1),
        level in config.levels,
        variant <- ["callback", "pipelined", "pipelined_linger"],
        profile <- config.profiles,
        variant == "callback" or profile == "optimized" do
      %{
        module: __MODULE__,
        scenario: "heavy_async_production",
        variant: variant,
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

  def settings(%{variant: "pipelined"}),
    do: %{
      producer: [
        max_in_flight_requests: 3,
        batchers_count: 4,
        batch_size_bytes: 1_000_000,
        linger_ms: 0
      ],
      socket: [nodelay: true]
    }

  def settings(%{variant: "pipelined_linger"} = c),
    do: put_in(settings(%{c | variant: "pipelined"}), [:producer, :linger_ms], 1)

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
