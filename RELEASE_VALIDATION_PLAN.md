# Release validation

Use this checklist for any release. Run commands from the candidate checkout's
root unless noted. Capture commands, output, exit codes and actual durations;
missing or inconclusive evidence does not count as a pass.

1. **Choose the versions and budget.** Pin the candidate commit and previous
   released tag. Record the harness revision, toolchains and lockfiles; save any
   uncommitted source patch with the report. Take the supported test matrix from
   [.github/workflows/ci.yml](.github/workflows/ci.yml). Set required coverage,
   resource limits, parallelism, time budgets and comparison tolerances before
   starting. The benchmark task creates its own baseline checkout and dependencies.

2. **Run the tests.** Follow the CI build/test commands for every supported
   combination, using [test/compose_files](test/compose_files). Ensure changed
   behavior has focused coverage. Also run
   `elixir bench/release_benchmark/test.exs`; from `simulator/`, run `mix deps.get`
   and `mix test --no-start` with the simulator's declared toolchain.

3. **Compare performance.** On an idle host and dedicated cluster, without
   concurrent tests or simulations, follow [bench/README.md](bench/README.md) and
   [the task](lib/mix/tasks/release_benchmark.ex). Run
   `mix release_benchmark --baseline <released-tag> --samples 5`; add
   `--start-kafka` if needed. Defaults cover all workloads, variants, scales and
   both profiles; consult each scenario's **Main metrics to observe** and add
   workloads for changed paths. The task uses the same current harness for both
   versions, builds their own dependencies, warms up and alternates version order.
   Match host, runtime, brokers, data and explicit settings; compare matching
   workload versions, variants, scales and profiles. Check completion counts,
   zero dropped offers and zero remaining committed catch-up lag. Compare
   completed records/s, acknowledgment/delivery p95/p99 and committed catch-up
   time. Use matched load for latency/resource comparisons. Collect CPU, memory
   and queue growth separately; the task does not measure these.
   Default tolerances: at most 5% throughput loss or 10% latency/resource increase.
   Review the reports yourself: task completion does not enforce release gates.
   Increase warmup, `--seconds`, backlog or sample count when needed; overlapping
   ranges beyond tolerance or insufficient tail samples remain inconclusive.
   Smoke checks do not establish release performance. Rerun both versions after
   workload changes; keep all reports and raw samples under `bench/results/`.

4. **Run simulations.** Follow [simulator/README.md](simulator/README.md) and
   [the Mix task](simulator/lib/mix/tasks/simulate.ex). From `simulator/`, run
   `mix simulate --parallel <N> --run-seconds 900 --total-seconds <worker-budget>`
   with explicit resource limits, Kafka version and `--image <candidate-image>`.
   Build that image from the candidate checkout. Each worker owns a cluster;
   [MultiRunner](simulator/lib/simulator/multi_runner.ex) checks its time budget
   between simulations. First smoke-test startup, isolation, useful traffic,
   logs and shutdown. Default coverage is 20 full fifteen-minute fresh runs:
   ten with `FORCE_STABLE=true`, ten with `FORCE_STABLE=false` (the default).
   Unpinned clients/token lifetimes vary per simulation; resources stay fixed per
   worker. Verify actual durations/completion from logs and Kafka/client/consumer
   coverage from saved [configs](simulator/lib/simulator/engine/config.ex).
   Smoke checks, failures and replays do not replace fresh-run coverage.
   Replay relevant previous failures
   with `mix simulate --rerun simulations_data/<worker>/<run> --image <candidate-image>`.
   Replay restores workload, seeds and Docker settings; Docker flags and
   `--run-seconds` override saved values. Verify the resulting image and config.
   Also replay a mixed-client config with `--run-seconds 3600` for a one-hour soak.

5. **Inspect every run.** Under `simulator/simulations_data/`, review each worker's
   `compose.log` and every run's config/resources/seeds, runtime/broker logs,
   events and invariants. Require zero invariant violations and unexplained
   crashes/errors, including startup, transitions and shutdown. Correlate faults
   with the event log; verify production/consumption progress and recovery.
   Collect additional drain/delivery evidence before automatic teardown removes
   the cluster and volumes; a successful exit does not prove a full drain.
   Missing evidence is inconclusive. Investigate failures and record their
   resolutions; a passing rerun alone is not a resolution. Preserve failures
   and replays alongside successful runs. Verify cleanup; follow the README's
   manual cleanup instructions for interrupted workers.

6. **Report and publish the evidence.** Write `report.md` for the ZIP root with
   versions, commands, coverage, run IDs, failures/resolutions, benchmark deltas
   and relative artifact links. Mark PASS only when the final candidate meets all required
   checks and tolerances; use FAIL for unresolved violations and INCONCLUSIVE for
   missing or noisy evidence. Record accepted exceptions separately from a clean
   PASS. After source changes, repeat affected checks against the final candidate.
   Bundle the report, source patches, command/test logs, campaign folders from
   `bench/results/` and complete worker folders from `simulator/simulations_data/`,
   including failures and replays, into `release-validation-<tag>.zip`. Preserve relative
   paths and verify archive contents and links. Attach it to the GitHub release
   whose tag contains the exact validated source, and link it from the release notes.
