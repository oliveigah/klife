defmodule Mix.Tasks.ReleaseBenchmark do
  use Mix.Task

  @shortdoc "Compare Klife releases using production, catch-up and latency workloads"
  @moduledoc """
  Runs real application workloads: catch-up lag, heavy synchronous production
  (single and batch), heavy asynchronous production and latency-sensitive records.
  Each has default and workload-optimized configurations. No dependency on `mix benchmark` or the test client.

      mix release_benchmark --start-kafka
      mix release_benchmark --baseline v1.2.0
      mix release_benchmark --seconds 1 --warmup 0 --samples 1 --levels 1

  Options:

    * `--baseline REF` — compare a Git revision with this checkout, alternating
      version order each sample. Uses the same harness with each revision's deps.
    * `--start-kafka` — start the existing test Compose cluster; leaves it running.
    * `--kafka 4.4` — Compose version (default 4.4).
    * `--brokers HOST:PORT,...` — plaintext endpoints (default localhost ports
      19092,29092,39092). The cluster needs at least two brokers and Kafka 4+.
    * `--profile both|default|optimized` — default both.
    * `--scenario catchup_lag|heavy_sync_production|heavy_async_production|latency_sensitive_records` — run one scenario (default all).
    * `--levels 1,2,3` — increasing scale levels (default all).
    * `--seconds 5`, `--warmup 1`, `--samples 5` — per timed case/sample.
    * `--record-bytes 1024`, `--records-per-partition 10000` — consumer preload size.
    * `--output DIR` — result directory (default: a new timestamped folder under
      Git-ignored `bench/results/`). Includes `report.md`, per-sample Markdown,
      effective settings, CSV and raw samples; partial reports survive failures.

  Catch-up ends when broker-stored committed offsets reach the backlog end.
  Latency-sensitive records use low fixed arrival rates and measure scheduled-send to producer
  acknowledgment AND consumer callback, including queueing. Heavy production cases
  measure actual completions, including drain. See bench/README.md for scales,
  profile settings, units and limitations. Runs use separate production VMs.
  """

  @requirements ["compile"]
  # Shared with old revisions by loading the same support script at runtime.
  @compile {:no_warn_undefined, [Klife.ReleaseBenchmark.Config, Klife.ReleaseBenchmark.Report]}
  @root Path.expand("../../..", __DIR__)

  @impl true
  def run(args) do
    if "--help" in args do
      Mix.shell().info(@moduledoc)
    else
      Code.require_file(Path.join(@root, "bench/release_benchmark/support.exs"))

      for path <-
            Path.wildcard(Path.join(@root, "bench/release_benchmark/scenarios/*/scenario.exs")),
          do: Code.require_file(path)

      config = Klife.ReleaseBenchmark.Config.parse(args)
      cases = Klife.ReleaseBenchmark.Config.cases(config)
      versions = if config.baseline, do: 2, else: 1

      seconds =
        Enum.count(cases, &(&1.kind != :consumer)) * (config.seconds + config.warmup) *
          config.samples * versions

      Mix.shell().info(
        "#{length(cases)} variants × #{config.samples} samples × #{versions} version(s); #{seconds}s of producer/latency phases, plus consumer setup and drains"
      )

      if File.exists?(config.output), do: Mix.raise("Output already exists: #{config.output}")
      File.mkdir_p!(config.output)

      baseline = if config.baseline, do: Path.join(config.output, "baseline-checkout")

      Klife.ReleaseBenchmark.Report.start(config, args)

      try do
        try do
          if config.start_kafka do
            file = Path.join(@root, "test/compose_files/docker-compose-kafka-#{config.kafka}.yml")

            command!(
              "docker",
              ["compose", "-f", file, "up", "-d", "--wait", "--wait-timeout", "180"],
              @root
            )
          end

          if baseline do
            command!("git", ["worktree", "add", "--detach", baseline, config.baseline], @root)
            prepare(baseline)
          end

          prepare(@root)

          for sample <- 1..config.samples do
            versions =
              if baseline,
                do: [{"baseline", baseline}, {"candidate", @root}],
                else: [{"candidate", @root}]

            versions = if rem(sample, 2) == 0, do: Enum.reverse(versions), else: versions

            for {version, checkout} <- versions do
              path = Path.join(config.output, "job.etf")

              Klife.ReleaseBenchmark.Config.write(
                path,
                Map.merge(config, %{version: version, sample: sample})
              )

              command!(
                "mix",
                ["run", "--no-start", Path.join(@root, "bench/release_benchmark/run.exs"), path],
                checkout
              )

              Klife.ReleaseBenchmark.Report.write(config, console: false)
            end
          end
        after
          if baseline && File.dir?(baseline) do
            command!("git", ["worktree", "remove", "--force", baseline], @root)
          end
        end

        Klife.ReleaseBenchmark.Report.finish(config, :complete)
      catch
        kind, reason ->
          trace = __STACKTRACE__

          Klife.ReleaseBenchmark.Report.finish(
            config,
            :failed,
            Exception.format(kind, reason, trace)
          )

          :erlang.raise(kind, reason, trace)
      end
    end
  end

  defp prepare(checkout) do
    command!("mix", ["deps.get", "--only", "prod"], checkout)
    command!("mix", ["compile"], checkout)
  end

  defp command!(program, args, directory) do
    {_, status} =
      System.cmd(program, args,
        cd: directory,
        env: [{"MIX_ENV", "prod"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0,
      do:
        Mix.raise(
          "#{program} #{Enum.join(args, " ")} failed (#{status}); artifacts: #{directory}"
        )
  end
end
