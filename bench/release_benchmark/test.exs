Code.require_file("support.exs", __DIR__)

for path <- Path.wildcard(Path.join(__DIR__, "scenarios/*/scenario.exs")),
    do: Code.require_file(path)

ExUnit.start()

defmodule Klife.ReleaseBenchmarkTest do
  use ExUnit.Case, async: true
  alias Klife.ReleaseBenchmark.{Config, Report, Stats}

  test "percentiles weight repeated observations and keep metric populations separate" do
    table = Stats.new()
    on_exit(fn -> if :ets.info(table) != :undefined, do: :ets.delete(table) end)
    for _ <- 1..99, do: Stats.observe(table, :ack, 1_000)
    Stats.observe(table, :ack, 100_000)
    Stats.observe(table, :e2e, 250_000)
    assert Stats.percentiles(table, :ack) == %{50 => 1.0, 95 => 1.0, 99 => 1.0}
    assert Stats.percentiles(table, :e2e) == %{50 => 250.0, 95 => 250.0, 99 => 250.0}
    assert Stats.percentiles(table, :missing) == %{50 => nil, 95 => nil, 99 => nil}
    assert Stats.median([1, 2, 3, 100]) == 2.5
  end

  test "selection runs only the requested scenario; all variants stay in its module" do
    all = Config.cases(Config.parse([]))

    assert all |> Enum.map(& &1.scenario) |> Enum.uniq() ==
             ~w(catchup_lag heavy_sync_production heavy_async_production latency_sensitive_records)

    selected = Config.cases(Config.parse(["--scenario", "catchup_lag", "--levels", "1,3"]))
    assert length(selected) == 8
    assert Enum.all?(selected, &(&1.module == Klife.ReleaseBenchmark.Scenarios.CatchupLag))
    assert selected |> Enum.map(& &1.partitions) |> Enum.uniq() == [1, 24]
    sync = Config.cases(Config.parse(["--scenario", "heavy_sync_production"]))
    assert length(sync) == 12
    assert Enum.map(sync, & &1.operation) |> Enum.uniq() == [:single, :batch]
    assert Enum.all?(sync, &(&1.module == Klife.ReleaseBenchmark.Scenarios.HeavySyncProduction))
    urgent = Config.cases(Config.parse(["--scenario", "latency_sensitive_records"]))
    assert Enum.map(urgent, & &1.rate) |> Enum.uniq() == [10, 100, 1000]
    assert Enum.all?(urgent, &(&1.partitions == 1 and &1.title == "Latency-sensitive records"))
    assert_raise ArgumentError, fn -> Config.parse(["--scenario", "typo"]) end
    assert_raise ArgumentError, fn -> Config.parse(["--levels", "3,1"]) end
    assert_raise ArgumentError, fn -> Config.parse(["--seconds", "0"]) end
  end

  test "catch-up requires every partition to reach its broker-stored committed offset" do
    alias Klife.ReleaseBenchmark.Scenarios.CatchupLag
    topics = [{"events", 2}]

    response = fn a, b ->
      [
        %{
          name: "events",
          partitions: [
            %{partition_index: 0, error_code: 0, committed_offset: a},
            %{partition_index: 1, error_code: 0, committed_offset: b}
          ]
        }
      ]
    end

    assert CatchupLag.remaining_lag(topics, 100, response.(100, 100)) == 0
    assert CatchupLag.remaining_lag(topics, 100, response.(100, 90)) == 10
    assert CatchupLag.remaining_lag(topics, 100, response.(-1, 90)) == 110
    assert_raise RuntimeError, fn -> CatchupLag.remaining_lag(topics, 100, []) end

    incomplete = [
      %{name: "events", partitions: [%{partition_index: 0, error_code: 0, committed_offset: 100}]}
    ]

    assert_raise RuntimeError, fn -> CatchupLag.remaining_lag(topics, 100, incomplete) end

    assert_raise RuntimeError, fn ->
      CatchupLag.remaining_lag(topics, 100, response.(101, 100))
    end
  end

  test "reports compare each strategy and profile separately, with ranges across samples" do
    path = Path.join(System.tmp_dir!(), "klife-report-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    config =
      Config.parse([
        "--scenario",
        "latency_sensitive_records",
        "--levels",
        "1",
        "--samples",
        "2",
        "--baseline",
        "release",
        "--output",
        path
      ])

    Report.start(config, ["--scenario", "latency_sensitive_records"])

    for {version, factor} <- [{"baseline", 1}, {"candidate", 2}], sample <- 1..2 do
      rows =
        for c <- Config.cases(config) do
          n = if c.variant == "shared", do: 100, else: 1_000

          Map.merge(c, %{
            status: :ok,
            records: n,
            elapsed_s: 1,
            records_s: (n + sample) * factor,
            ack_p99_ms: 2 / factor,
            e2e_p99_ms: if(c.profile == "default", do: 10, else: 5),
            dropped: 0,
            ack_p50_ms: 0.5,
            ack_p95_ms: 1.5,
            e2e_p50_ms: 3.0,
            e2e_p95_ms: 4.0,
            settings: %{producer: [acks: :all], topic: [fetch_interval_ms: 1]},
            started_at: "2026-10-29T13:00:00Z",
            finished_at: "2026-10-29T13:00:01Z"
          })
        end

      Config.write(Path.join(path, "sample-#{version}-#{sample}.etf"), %{
        version: version,
        sample: sample,
        commit: "#{version}-sha",
        dirty: false,
        elixir: "1.19.4",
        otp: "28",
        complete: true,
        results: rows
      })
    end

    ExUnit.CaptureIO.capture_io(fn -> Report.finish(config, :complete) end)
    report = File.read!(Path.join(path, "report.md"))
    assert report =~ "101.50 [101.00–102.00]"
    assert report =~ "1001.50 [1001.00–1002.00]"
    assert report =~ "100.00%"
    assert report =~ "-50.00%"
    assert report =~ "Status: **complete**"
    assert report =~ "Samples completed: **4/4**"
    assert report =~ "## Scenario overview"
    assert report =~ "## Latency-sensitive records"
    assert report =~ "**Improved**"
    assert report =~ "2.00 → 1.00 · Improved (-50.00%)"
    assert report =~ "Unchanged (0.00%)"
    assert report =~ "<summary>All metrics and sample ranges</summary>"
    assert report =~ "[candidate sample 1](sample-candidate-1.md)"
    detail = File.read!(Path.join(path, "sample-candidate-1.md"))
    assert detail =~ "candidate-sha"
    assert detail =~ "ack_p50_ms"
    assert detail =~ "ack_p95_ms"
    assert detail =~ "ack_p99_ms"
    assert detail =~ "e2e_p99_ms"
    assert detail =~ "acks: :all"
    assert detail =~ "fetch_interval_ms: 1"
    assert detail =~ "2026-10-29T13:00:00Z"
    assert detail =~ "## Latency-sensitive records"
    assert detail =~ "### shared — default — level 1"

    assert length(String.split(File.read!(Path.join(path, "samples.csv")), "\n", trim: true)) ==
             17

    Report.write(%{config | baseline: nil}, console: false)
    solo = File.read!(Path.join(path, "report.md"))
    assert solo =~ "| — | — | 1.00 | 10.00 | **Not compared** |"
    assert solo =~ "Workload version: 2"
  end

  test "failure reports retain partial samples and suppress overloaded comparisons" do
    path =
      Path.join(System.tmp_dir!(), "klife-failed-report-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    config =
      Config.parse([
        "--scenario",
        "latency_sensitive_records",
        "--levels",
        "1",
        "--profile",
        "default",
        "--samples",
        "1",
        "--baseline",
        "release",
        "--output",
        path
      ])

    Report.start(config, [])
    initial = File.read!(Path.join(path, "report.md"))
    assert initial =~ "Status: **running**"
    assert initial =~ "pending / not run"
    c = hd(Config.cases(config))

    for {version, status, value} <- [{"baseline", :ok, 10}, {"candidate", :overloaded, 20}] do
      Report.save_sample(Path.join(path, "sample-#{version}-1.etf"), %{
        version: version,
        sample: 1,
        complete: false,
        error: "Callback timeout",
        results: [
          Map.merge(c, %{
            status: status,
            records: value,
            elapsed_s: 1,
            records_s: value,
            ack_p99_ms: 2.0,
            dropped: if(status == :ok, do: 0, else: 2)
          })
        ]
      })
    end

    Report.finish(config, :failed, "Child VM failed")
    report = File.read!(Path.join(path, "report.md"))
    assert report =~ "Status: **failed**"
    assert report =~ "Samples completed: **0/2**"
    assert report =~ "Results recorded: 2/4"
    assert report =~ "Child VM failed"
    refute report =~ "100.00%"
    detail = File.read!(Path.join(path, "sample-candidate-1.md"))
    assert detail =~ "Callback timeout"
    assert detail =~ "overloaded"
    assert detail =~ "| dropped | 2 |"
    assert File.read!(Path.join(path, "failure.txt")) == "Child VM failed"
  end

  test "assessments respect metric direction, tolerance boundaries, noise and incomplete samples" do
    samples = fn old, new ->
      for {version, values} <- [{"baseline", old}, {"candidate", new}], value <- values do
        %{version: version, status: :ok, records_s: value, ack_p99_ms: value}
      end
    end

    assert Report.assessment(samples.([99, 101], [119, 121]), :records_s, 2) == :improved
    assert Report.assessment(samples.([99, 101], [119, 121]), :ack_p99_ms, 2) == :degraded
    assert Report.assessment(samples.([99, 101], [79, 81]), :ack_p99_ms, 2) == :improved
    assert Report.assessment(samples.([100, 100], [105, 105]), :records_s, 2) == :unchanged
    assert Report.assessment(samples.([100, 100], [110, 110]), :ack_p99_ms, 2) == :unchanged
    assert Report.assessment(samples.([90, 110], [100, 130]), :records_s, 2) == :inconclusive
    assert Report.assessment(samples.([100], [120]), :records_s, 2) == :pending

    overloaded =
      samples.([100, 100], [120, 120]) |> List.update_at(3, &%{&1 | status: :overloaded})

    assert Report.assessment(overloaded, :records_s, 2) == :inconclusive
  end
end
