defmodule Klife.ReleaseBenchmark.Config do
  @scenarios [
    {"catchup_lag", Klife.ReleaseBenchmark.Scenarios.CatchupLag},
    {"heavy_sync_production", Klife.ReleaseBenchmark.Scenarios.HeavySyncProduction},
    {"heavy_async_production", Klife.ReleaseBenchmark.Scenarios.HeavyAsyncProduction},
    {"latency_sensitive_records", Klife.ReleaseBenchmark.Scenarios.LatencySensitiveRecords}
  ]

  def parse(args) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [
          baseline: :string,
          output: :string,
          brokers: :string,
          kafka: :string,
          start_kafka: :boolean,
          profile: :string,
          scenario: :string,
          levels: :string,
          seconds: :integer,
          warmup: :integer,
          samples: :integer,
          record_bytes: :integer,
          records_per_partition: :integer,
          help: :boolean
        ]
      )

    if rest != [], do: raise(ArgumentError, "Unexpected arguments: #{inspect(rest)}")

    profiles =
      case Keyword.get(opts, :profile, "both") do
        "both" -> ["default", "optimized"]
        p when p in ["default", "optimized"] -> [p]
        p -> raise ArgumentError, "Unknown profile: #{p}"
      end

    levels =
      Keyword.get(opts, :levels, "1,2,3") |> String.split(",") |> Enum.map(&String.to_integer/1)

    unless levels != [] and levels == Enum.sort(Enum.uniq(levels)) and
             Enum.all?(levels, &(&1 in 1..3)),
           do: raise(ArgumentError, "--levels must be increasing unique levels from 1,2,3")

    scenarios =
      if opts[:scenario], do: [opts[:scenario]], else: Enum.map(@scenarios, &elem(&1, 0))

    unless Enum.all?(scenarios, &List.keymember?(@scenarios, &1, 0)),
      do:
        raise(
          ArgumentError,
          "--scenario must be one of: #{Enum.map_join(@scenarios, ", ", &elem(&1, 0))}"
        )

    config = %{
      baseline: opts[:baseline],
      workload_version: 2,
      output:
        Path.expand(
          Keyword.get(
            opts,
            :output,
            "bench/results/#{DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")}"
          )
        ),
      brokers:
        Keyword.get(opts, :brokers, "localhost:19092,localhost:29092,localhost:39092")
        |> String.split(","),
      kafka: Keyword.get(opts, :kafka, "4.4"),
      start_kafka: opts[:start_kafka] || false,
      profiles: profiles,
      scenarios: Enum.uniq(scenarios),
      levels: levels,
      seconds: Keyword.get(opts, :seconds, 5),
      warmup: Keyword.get(opts, :warmup, 1),
      samples: Keyword.get(opts, :samples, 5),
      record_bytes: Keyword.get(opts, :record_bytes, 1_024),
      records_per_partition: Keyword.get(opts, :records_per_partition, 10_000)
    }

    for key <- [:seconds, :samples, :records_per_partition],
        config[key] <= 0,
        do: raise(ArgumentError, "--#{key} must be positive")

    if config.warmup < 0, do: raise(ArgumentError, "--warmup must be nonnegative")
    if config.record_bytes < 24, do: raise(ArgumentError, "--record-bytes must be at least 24")

    unless Enum.all?(config.brokers, &Regex.match?(~r/^[^:\s]+:[0-9]+$/, &1)),
      do: raise(ArgumentError, "--brokers must contain host:port endpoints")

    config
  end

  def cases(config) do
    Enum.flat_map(config.scenarios, fn name ->
      {_, module} = List.keyfind(@scenarios, name, 0)
      Enum.map(module.cases(config), &Map.put(&1, :title, module.title()))
    end)
  end

  def title(scenario) do
    {_, module} = List.keyfind(@scenarios, scenario, 0)
    module.title()
  end

  def write(path, value) do
    File.write!(path, :erlang.term_to_binary(value, [:compressed]))

    if String.starts_with?(Path.basename(path), "sample-") do
      File.write!(
        path <> ".txt",
        inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)
      )
    end
  end

  # These files are produced by this task and contain configuration atoms from both revisions.
  def read(path), do: path |> File.read!() |> :erlang.binary_to_term()
end

defmodule Klife.ReleaseBenchmark.Stats do
  def new, do: :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
  def add(t, key, n), do: :ets.update_counter(t, key, {2, n}, {key, 0})

  def get(t, key) do
    case :ets.lookup(t, key) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  def observe(t, metric, us), do: add(t, {metric, max(0, us)}, 1)

  def percentiles(t, metric) do
    histogram = for {{^metric, us}, n} <- :ets.tab2list(t), do: {us, n}
    histogram = Enum.sort(histogram)
    total = Enum.reduce(histogram, 0, fn {_, n}, acc -> acc + n end)

    for p <- [50, 95, 99], into: %{} do
      target = ceil(total * p / 100)

      {value, _} =
        Enum.reduce_while(histogram, {nil, 0}, fn {us, n}, {_, count} ->
          if count + n >= target,
            do: {:halt, {us / 1_000, count + n}},
            else: {:cont, {nil, count + n}}
        end)

      {p, value}
    end
  end

  def median(values) do
    values = Enum.sort(values)
    n = length(values)

    if rem(n, 2) == 1,
      do: Enum.at(values, div(n, 2)),
      else: (Enum.at(values, div(n, 2) - 1) + Enum.at(values, div(n, 2))) / 2
  end
end

Code.require_file("report.exs", __DIR__)
