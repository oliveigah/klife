# Release validation

Use this checklist for any release. Record what was actually run; incomplete or
inconclusive checks do not count as a pass.

1. **Choose the versions and budget.** Pin the candidate commit and previous
   released tag. Use separate checkouts with their own dependencies. Take the
   supported Kafka/Elixir/OTP matrix from [.github/workflows/ci.yml](.github/workflows/ci.yml).
   Set a run count and time limit before starting.

2. **Run the tests.** Follow the build and test commands in the CI workflow for
   every supported combination. Cluster definitions are in
   [test/compose_files](test/compose_files). Review changes since the previous
   release and ensure affected behavior has focused test coverage.

3. **Compare performance.** Use [benchmarks.md](benchmarks.md),
   [the benchmark task](lib/mix/tasks/benchmark.ex) and
   [the async benchmark](test/support/async_producer_benchmark.ex) as starting points;
   verify they support the comparison and metrics required. Compare sync/batch/async
   production and shared/exclusive consumption, adding workloads for changed paths.
   Keep host, runtime, brokers, data and settings identical. Warm up, then run at
   least five samples per version, alternating order. Measure successful throughput,
   p95/p99 latency at matched load, CPU, memory and queue growth. Validate completion
   counts; randomized simulation rates and enqueue rates are insufficient.
   Default tolerances: at most 5% throughput loss or 10% latency/resource increase.
   Investigate repeatable regressions; noisy results remain inconclusive.

4. **Run simulations.** Read [simulator/README.md](simulator/README.md) for
   startup, stable/chaos modes, client selection and replay controls.
   Use the simulator's Docker launcher for independent parallel stacks and
   configurable resource limits.
   [EngineConfig](simulator/lib/simulator/engine/config.ex) defines randomized
   workloads; [MultiRunner](simulator/lib/simulator/multi_runner.ex) controls batch
   limits. Default to 20 fifteen-minute runs, split evenly between stable and
   chaos, plus one one-hour mixed-client run. Distribute coverage across supported
   Kafka versions, clients and consumer configurations; emphasize changed paths.
   Replay relevant previous failures with `RERUN_TS`, then use fresh configurations.
   First smoke-test startup, useful production/consumption, actual cluster
   selection, log capture and shutdown. Inspect
   [Engine](simulator/lib/simulator/engine/engine.ex) and
   [EventExecutor](simulator/lib/simulator/engine/event_executor.ex) when checking
   these; do not assume an environment variable overrides saved or hardcoded settings.

5. **Inspect every run.** Preserve configuration, seeds, application/broker logs,
   events and invariant results from `simulator/simulations_data/`. Require zero
   invariant violations and unexplained crashes/errors. Distinguish injected
   failures from implementation failures using the event log. Restore the cluster,
   allow outstanding work to drain, and verify delivery and recovery before
   declaring success. Process exit status alone is insufficient. Preserve and
   investigate failures; a passing rerun does not erase them.

6. **Report the decision.** Save versions, commands, coverage, run IDs, failures,
   benchmark results/deltas and artifact locations. Mark PASS only when tests,
   simulations and performance checks pass. List unresolved issues, missing checks
   and any explicitly accepted exceptions. After a code fix, repeat affected
   checks and validate the final candidate.
