defmodule Klife.ReleaseBenchmark.Scenarios.HeavySyncProduction do
  alias Klife.ReleaseBenchmark.Workload
  @compile {:no_warn_undefined, Workload}

  def title, do: "Heavy synchronous production"

  def cases(config) do
    single_records(config) ++ batches(config)
  end

  defp single_records(config) do
    for {callers, level} <- Enum.with_index([1, 8, 64], 1),
        level in config.levels,
        profile <- config.profiles do
      %{
        module: __MODULE__,
        scenario: "heavy_sync_production",
        variant: "single",
        kind: :producer,
        operation: :single,
        level: level,
        profile: profile,
        callers: callers,
        batch: 1,
        scale: "concurrent_callers=#{callers}"
      }
    end
  end

  defp batches(config) do
    for {batch, level} <- Enum.with_index([1, 10, 100], 1),
        level in config.levels,
        profile <- config.profiles do
      %{
        module: __MODULE__,
        scenario: "heavy_sync_production",
        variant: "batch",
        kind: :producer,
        operation: :batch,
        level: level,
        profile: profile,
        callers: 16,
        batch: batch,
        scale: "records_per_call=#{batch},concurrent_callers=16"
      }
    end
  end

  def settings(%{profile: "default"}), do: %{}

  def settings(%{profile: "optimized", operation: :batch}),
    do: %{
      producer: [
        max_in_flight_requests: 1,
        batchers_count: 1,
        batch_size_bytes: 1_000_000,
        linger_ms: 0
      ],
      socket: [nodelay: true]
    }

  def settings(_c),
    do: %{
      producer: [
        max_in_flight_requests: 1,
        batchers_count: 1,
        linger_ms: 0
      ],
      socket: [nodelay: true]
    }

  def run(c, context), do: Workload.throughput(c, context)
end
