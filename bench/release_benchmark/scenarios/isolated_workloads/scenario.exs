defmodule Klife.ReleaseBenchmark.Scenarios.IsolatedWorkloads do
  alias Klife.ReleaseBenchmark.Workload
  @compile {:no_warn_undefined, Workload}

  @urgent_rate 100

  def title, do: "Isolated workloads"

  def cases(config) do
    for {window, level} <- Enum.with_index([0, 64, 1_024], 1),
        level in config.levels,
        variant <- ["shared", "dedicated_producer", "dedicated_connection"],
        profile <- config.profiles do
      %{
        module: __MODULE__,
        scenario: "isolated_workloads",
        variant: variant,
        kind: :isolation,
        strategy: :shared,
        rate: @urgent_rate,
        partitions: 1,
        window: window,
        urgent_producer: if(variant != "shared", do: :urgent_producer),
        level: level,
        profile: profile,
        scale: "urgent_records/s=#{@urgent_rate},bulk_outstanding_records=#{window}"
      }
    end
  end

  # The configuration guide's "Isolating workloads" example: a producer for the urgent
  # topics and, in the last variant, a connection of its own with TCP_NODELAY
  def settings(c), do: Map.merge(variant(c), profile(c), fn _key, a, b -> a ++ b end)

  defp variant(%{variant: "shared"}), do: %{}

  defp variant(%{variant: "dedicated_producer"} = c),
    do: %{producers: [[name: :urgent_producer] ++ urgent_producer(c)]}

  defp variant(%{variant: "dedicated_connection"} = c),
    do: %{
      requires: [:custom_connections],
      connection: [custom_connections: [[name: :urgent, socket_opts: [nodelay: true]]]],
      producers: [[name: :urgent_producer, connection: :urgent] ++ urgent_producer(c)]
    }

  defp urgent_producer(%{profile: "default"}), do: []

  defp urgent_producer(_c),
    do: [max_in_flight_requests: 5, batchers_count: 1, linger_ms: 0]

  defp profile(%{profile: "default"}), do: %{}

  # Bulk keeps the heavy asynchronous production tuning; delivery the latency tuning
  defp profile(_c),
    do: %{
      producer: [
        max_in_flight_requests: 1,
        batchers_count: 1,
        batch_size_bytes: 1_000_000,
        linger_ms: 0
      ],
      fetcher: [batchers_count: 1, max_wait_ms: 0, linger_ms: 0],
      topic: [fetch_interval_ms: 1, handler_max_unacked_commits: 100_000],
      socket: [nodelay: true]
    }

  def run(c, context), do: Workload.isolation(c, context)
end
