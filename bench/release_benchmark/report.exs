defmodule Klife.ReleaseBenchmark.Report do
  alias Klife.ReleaseBenchmark.{Config, Stats}

  @metrics [
    :records_s,
    :mib_s,
    :ack_p50_ms,
    :ack_p95_ms,
    :ack_p99_ms,
    :e2e_p50_ms,
    :e2e_p95_ms,
    :e2e_p99_ms,
    :dispatch_p99_ms,
    :startup_ms,
    :catchup_ms,
    :delivery_drain_ms,
    :commit_drain_ms,
    :dropped
  ]
  @columns [
             :version,
             :sample,
             :scenario,
             :variant,
             :profile,
             :level,
             :scale,
             :status,
             :records,
             :elapsed_s,
             :initial_lag_records,
             :remaining_lag_records
           ] ++ @metrics

  def start(config, args) do
    Config.write(manifest_path(config), %{
      status: :running,
      started_at: timestamp(),
      finished_at: nil,
      arguments: args,
      options: config,
      error: nil
    })

    write(config, console: false)
  end

  def finish(config, status, error \\ nil) do
    manifest = Config.read(manifest_path(config))

    Config.write(manifest_path(config), %{
      manifest
      | status: status,
        finished_at: timestamp(),
        error: error
    })

    if error, do: File.write!(Path.join(config.output, "failure.txt"), error)
    write(config, console: status == :complete)
  end

  def save_sample(path, job) do
    Config.write(path, job)
    write_sample(path, job)
  end

  def write(config, opts \\ []) do
    jobs =
      Path.wildcard(Path.join(config.output, "sample-*.etf"))
      |> Enum.map(fn path ->
        job = Config.read(path)
        write_sample(path, job)
        job
      end)

    manifest =
      if File.exists?(manifest_path(config)), do: Config.read(manifest_path(config)), else: %{}

    rows =
      Enum.flat_map(jobs, fn job ->
        Enum.map(job.results, &Map.merge(&1, %{version: job.version, sample: job.sample}))
      end)

    groups = Enum.group_by(rows, &{&1.scenario, &1.variant, &1.profile, &1.level})
    csv = Enum.map_join(@columns, ",", &to_string/1)

    lines =
      Enum.map(rows, fn row ->
        Enum.map_join(@columns, ",", fn key -> csv_value(Map.get(row, key)) end)
      end)

    File.write!(Path.join(config.output, "samples.csv"), Enum.join([csv | lines], "\n") <> "\n")

    report =
      overview(config, manifest, jobs) <>
        scenario_overview(config, groups) <>
        summary(config, groups) <>
        "\n## Run parameters\n\n```elixir\n#{pretty(config)}\n```\n" <>
        "\n## Sample reports\n\n" <> sample_index(config, jobs)

    File.write!(Path.join(config.output, "report.md"), report)

    if Keyword.get(opts, :console, true) do
      console(config, groups)
      IO.puts("Detailed report: #{Path.join(config.output, "report.md")}")
    end
  end

  defp overview(config, manifest, jobs) do
    expected_jobs = config.samples * if(config.baseline, do: 2, else: 1)
    completed = Enum.count(jobs, &Map.get(&1, :complete, false))

    versions =
      jobs
      |> Enum.uniq_by(&{&1.version, Map.get(&1, :commit), Map.get(&1, :dirty)})
      |> Enum.map_join("", fn job ->
        "| #{job.version} | #{Map.get(job, :commit, "unknown")} | #{Map.get(job, :dirty, "unknown")} |\n"
      end)

    error = if manifest[:error], do: "\n## Failure\n\n```text\n#{manifest.error}\n```\n", else: ""

    """
    # Release benchmark

    - Status: **#{manifest[:status] || :unknown}**
    - Workload version: #{config.workload_version}
    - Started (UTC): #{manifest[:started_at] || "unavailable"}
    - Finished (UTC): #{manifest[:finished_at] || "in progress"}
    - Samples completed: **#{completed}/#{expected_jobs}**
    - Results recorded: #{Enum.sum(Enum.map(jobs, &length(&1.results)))}/#{length(Config.cases(config)) * expected_jobs}
    - CLI arguments: `#{inspect(manifest[:arguments] || [])}`

    ## Versions

    | Version | Commit | Uncommitted changes |
    |---|---|---|
    #{versions}
    Values below are medians [min–max] across samples; sample counts are baseline/candidate.
    Positive throughput change is better; negative latency change is better.
    Missing samples remain incomplete. Dropped offers invalidate latency comparisons;
    deltas are omitted when samples are missing or overloaded. Short runs are setup checks.
    Unchanged means within +/-5% throughput or +/-10% latency. Larger changes require
    non-overlapping sample ranges; overlapping ranges are inconclusive. Mixed means
    some primary metrics improved while others degraded. These labels are descriptive,
    not a statistical significance test or an automatic release decision.
    #{error}
    """
  end

  defp scenario_overview(config, groups) do
    header =
      "\n## Scenario overview\n\nCounts refer to primary metrics: completion throughput and acknowledgment p99 for heavy production, catch-up time and delivery throughput for backlog recovery, acknowledgment and delivery p99 for latency-sensitive records.\n\n| Scenario | Assessment | Improved | Degraded | Unchanged | Inconclusive | Pending |\n|---|---|---:|---:|---:|---:|---:|\n"

    rows =
      for scenario <- config.scenarios do
        results =
          for c <- Config.cases(config),
              c.scenario == scenario,
              metric <- primary_metrics(c),
              do: result_status(Map.get(groups, key(c), []), metric, config)

        counts = Enum.frequencies(results)

        cells =
          for status <- [:improved, :degraded, :unchanged, :inconclusive, :pending],
              do: Map.get(counts, status, 0)

        "| [#{Config.title(scenario)}](##{scenario}) | **#{label(overall(results))}** | #{Enum.join(cells, " | ")} |\n"
      end

    header <> Enum.join(rows)
  end

  defp summary(config, groups) do
    Enum.map_join(config.scenarios, "\n", fn scenario ->
      cases = Enum.filter(Config.cases(config), &(&1.scenario == scenario))

      quick_header =
        "\n<a id=\"#{scenario}\"></a>\n\n## #{Config.title(scenario)}\n\n| Variant | Profile | Scale | Records/s | Catch-up ms | Ack p99 | Delivery p99 | Assessment |\n|---|---|---|---|---|---|---|---|\n"

      quick_rows =
        for c <- cases do
          samples = Map.get(groups, key(c), [])

          cells =
            for metric <- [:records_s, :catchup_ms, :ack_p99_ms, :e2e_p99_ms] do
              if metric in primary_metrics(c) do
                {old, new} = populations(samples, metric)

                if config.baseline do
                  "#{median(old)} → #{median(new)} · #{label(result_status(samples, metric, config))} (#{delta(samples, old, new, config.samples)})"
                else
                  median(new)
                end
              else
                "—"
              end
            end

          status =
            primary_metrics(c) |> Enum.map(&result_status(samples, &1, config)) |> overall()

          "| #{c.variant} | #{c.profile} | #{c.scale} | #{Enum.join(cells, " | ")} | **#{label(status)}** |\n"
        end

      header =
        "\n<details>\n<summary>All metrics and sample ranges</summary>\n\n| Variant | Profile | Scale | Metric | Samples | Baseline | Candidate | Change | Assessment |\n|---|---|---|---|---|---:|---:|---:|---|\n"

      rows =
        for c <- cases, metric <- @metrics do
          samples = Map.get(groups, key(c), [])
          {old, new} = populations(samples, metric)

          if old != [] or new != [] do
            "| #{c.variant} | #{c.profile} | #{c.scale} | #{metric} | #{length(old)}/#{length(new)} | #{display(old)} | #{display(new)} | #{delta(samples, old, new, config.samples)} | #{label(result_status(samples, metric, config))} |\n"
          end
        end

      quick_header <> Enum.join(quick_rows) <> header <> Enum.join(rows) <> "\n</details>\n"
    end)
  end

  defp primary_metrics(%{kind: :consumer}), do: [:records_s, :catchup_ms]
  defp primary_metrics(%{kind: :latency}), do: [:ack_p99_ms, :e2e_p99_ms]
  defp primary_metrics(_), do: [:records_s, :ack_p99_ms]

  defp result_status(samples, metric, config) do
    if config.baseline, do: assessment(samples, metric, config.samples), else: :not_compared
  end

  defp overall(results) do
    cond do
      :improved in results and :degraded in results -> :mixed
      :degraded in results -> :degraded
      :pending in results -> :pending
      :inconclusive in results -> :inconclusive
      :improved in results -> :improved
      :unchanged in results -> :unchanged
      true -> :not_compared
    end
  end

  # Descriptive tolerance/range check, not a confidence interval.
  def assessment(samples, metric, expected) do
    {old, new} = populations(samples, metric)

    cond do
      length(old) != expected or length(new) != expected ->
        :pending

      Enum.any?(samples, &(&1.status != :ok)) ->
        :inconclusive

      Stats.median(old) == 0 and Stats.median(new) == 0 ->
        :unchanged

      Stats.median(old) == 0 ->
        :inconclusive

      true ->
        percent = Float.round((Stats.median(new) / Stats.median(old) - 1) * 100, 8)
        throughput? = metric in [:records_s, :mib_s]
        tolerance = if throughput?, do: 5, else: 10
        overlap? = Enum.min(old) <= Enum.max(new) and Enum.min(new) <= Enum.max(old)

        cond do
          abs(percent) <= tolerance -> :unchanged
          overlap? -> :inconclusive
          (throughput? and percent > 0) or (not throughput? and percent < 0) -> :improved
          true -> :degraded
        end
    end
  end

  defp label(status),
    do: status |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp sample_index(config, jobs) do
    for version <- if(config.baseline, do: ["baseline", "candidate"], else: ["candidate"]),
        sample <- 1..config.samples do
      case Enum.find(jobs, &(&1.version == version and &1.sample == sample)) do
        nil ->
          "- #{version} sample #{sample}: pending / not run\n"

        job ->
          "- [#{version} sample #{sample}](sample-#{version}-#{sample}.md): #{sample_status(job)}, #{length(job.results)} results\n"
      end
    end
    |> Enum.join()
  end

  defp write_sample(path, job) do
    environment =
      Map.take(job, [
        :commit,
        :dirty,
        :elixir,
        :otp,
        :os,
        :schedulers,
        :build_env,
        :dependencies,
        :lock_sha256,
        :options
      ])

    sections =
      job.results
      |> Enum.chunk_by(& &1.scenario)
      |> Enum.map_join("\n", fn rows ->
        "## #{Map.get(hd(rows), :title, hd(rows).scenario)}\n\n" <>
          Enum.map_join(rows, "\n", fn row ->
            values =
              for metric <-
                    [:records, :elapsed_s, :initial_lag_records, :remaining_lag_records] ++
                      @metrics,
                  value = Map.get(row, metric),
                  not is_nil(value),
                  do: "| #{metric} | #{scalar(value)} |\n"

            settings = Map.take(row, [:settings, :overrides, :client_config, :workload_topics])

            """
            ### #{row.variant} — #{row.profile} — level #{row.level}

            Scale: `#{row.scale}`. Status: **#{row.status}**.
            Started (UTC): #{row[:started_at] || "unavailable"}. Finished (UTC): #{row[:finished_at] || "unavailable"}.

            | Metric | Value |
            |---|---:|
            #{Enum.join(values)}
            #### Effective configuration

            ```elixir
            #{pretty(settings)}
            ```
            """
          end)
      end)

    error = if job[:error], do: "\n## Failure\n\n```text\n#{job.error}\n```\n", else: ""

    document = """
    # #{job.version} — sample #{job.sample}

    - Status: **#{sample_status(job)}**
    - Started (UTC): #{job[:started_at] || "unavailable"}
    - Finished (UTC): #{job[:finished_at] || "in progress"}
    - [All results](report.md) · [CSV](samples.csv) · [Raw sample](#{Path.basename(path)})

    Latencies are milliseconds; elapsed time is seconds. Throughput counts successfully
    acknowledged or consumed records. MiB/s counts value bytes. Batch acknowledgment
    latency is per batch; consumer delivery ends at callback invocation. Missing metrics
    are not applicable. Overloaded or incomplete results do not establish a release pass.

    ## Runtime and inputs

    ```elixir
    #{pretty(environment)}
    ```
    #{error}
    #{sections}
    """

    File.write!(Path.rootname(path) <> ".md", document)
  end

  defp console(config, groups) do
    IO.puts("\nWorkload/profile/level | Records/s | Catch-up ms | Ack p99 ms | Delivery p99 ms")

    for c <- Config.cases(config) do
      samples = Map.get(groups, key(c), [])

      cells =
        for metric <- [:records_s, :catchup_ms, :ack_p99_ms, :e2e_p99_ms] do
          {old, new} = populations(samples, metric)

          case {old, new} do
            {[], []} ->
              "—"

            {[], new} ->
              number(Stats.median(new))

            {old, []} ->
              "#{number(Stats.median(old))} -> pending"

            {old, new} ->
              "#{number(Stats.median(old))} -> #{number(Stats.median(new))} (#{delta(samples, old, new, config.samples)})"
          end
        end

      IO.puts(Enum.join(["#{c.title}/#{c.variant}/#{c.profile}/#{c.level}" | cells], " | "))
    end
  end

  defp populations(samples, metric) do
    values = fn version ->
      for row <- samples,
          row.version == version,
          value = Map.get(row, metric),
          not is_nil(value),
          do: value
    end

    {values.("baseline"), values.("candidate")}
  end

  defp delta(samples, old, new, expected) do
    if length(old) == expected and length(new) == expected and
         Enum.all?(samples, &(&1.status == :ok)) and Stats.median(old) != 0,
       do: "#{number((Stats.median(new) / Stats.median(old) - 1) * 100)}%",
       else: "—"
  end

  defp sample_status(job) do
    cond do
      job[:error] -> :failed
      not Map.get(job, :complete, false) -> :incomplete
      Enum.any?(job.results, &(&1.status != :ok)) -> :overloaded
      true -> :complete
    end
  end

  defp key(c), do: {c.scenario, c.variant, c.profile, c.level}
  defp median([]), do: "—"
  defp median(values), do: number(Stats.median(values))
  defp display([]), do: "—"

  defp display(values),
    do:
      "#{number(Stats.median(values))} [#{number(Enum.min(values))}–#{number(Enum.max(values))}]"

  defp scalar(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 6)
  defp scalar(value), do: to_string(value)
  defp number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp pretty(value),
    do: inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity, width: 90)

  defp csv_value(value), do: "\"#{value |> to_string() |> String.replace("\"", "\"\"")}\""
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp manifest_path(config), do: Path.join(config.output, "run.etf")
end
