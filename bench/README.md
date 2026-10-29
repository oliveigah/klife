# Release benchmarks

`mix release_benchmark` runs all scenarios, both configuration profiles and all
three increasing scale levels. It is independent of the old `mix benchmark`, its
test clients and other Kafka libraries. No new dependencies are needed.

```sh
# Start the existing three-broker Kafka cluster and benchmark this checkout.
mix release_benchmark --start-kafka

# Compare the previous release against this checkout.
mix release_benchmark --baseline v1.2.0

# Run just one scenario, including all its variants.
mix release_benchmark --scenario latency_sensitive_records

# Short smoke check of every scenario; not a release performance result.
mix release_benchmark --seconds 1 --warmup 0 --samples 1 --levels 1 \
  --records-per-partition 100
```

An already running Kafka 4+ cluster with at least two brokers is sufficient.
Default plaintext endpoints are `localhost:19092,localhost:29092,localhost:39092`;
override with `--brokers host:port,...`. `--start-kafka --kafka 4.0` selects the
other supported test Compose cluster. The task leaves that cluster running.
Use an idle, dedicated cluster and host when collecting release numbers.

## Workloads and real use cases

Each workload owns a module and a README under `release_benchmark/scenarios/`.
The READMEs explain real application examples, the main metrics to observe,
timing boundaries, variants and tradeoffs.

| `--scenario` | Real use case | Increasing levels | Main metrics |
|---|---|---|---|
| [catchup_lag](release_benchmark/scenarios/catchup_lag/README.md) | Resume paused readers or clear a bulk-import lag spike | 1 / 6 / 24 partitions per topic, 10,000 records per partition by default | Committed catch-up ms; delivery records/s |
| [heavy_sync_production](release_benchmark/scenarios/heavy_sync_production/README.md) | Migration/import workers that wait for successful writes | Single API: 1 / 8 / 64 callers; batch API: 1 / 10 / 100 records with 16 callers | Completed records/s; call acknowledgment p99 |
| [heavy_async_production](release_benchmark/scenarios/heavy_async_production/README.md) | Telemetry or export pipelines with bounded pending work | 1 / 32 / 1,024 outstanding records | Acknowledged records/s; callback p99 |
| [latency_sensitive_records](release_benchmark/scenarios/latency_sensitive_records/README.md) | Urgent order/payment updates, alerts and interactive events | 10 / 100 / 1,000 records/s across three single-partition topics | Scheduled-send to acknowledgment and delivery p99 |

`--levels 1,2` selects a subset. Synchronous single and batch production are
variants of one workload, in the same module. Shared/exclusive fetchers are
variants of catch-up and latency-sensitive delivery.

Heavy production uses three topics with twelve partitions each. Catch-up
increases partition count; latency-sensitive delivery uses three topics with
one partition each. All topics have replication factor two. Default values are
1,024-byte binaries with reproducible filler and 50-byte keys. Partitions are
explicit, so measurements focus on delivery rather than partitioner choice.
MiB/s counts value bytes, excluding keys and Kafka protocol overhead.

These are **workload version 2**, recorded in every run's configuration. Older
reports keep their original scenario names, topology and timing. Use a fresh
comparison to evaluate these changed workloads across Klife versions.

## Default and optimized configurations

Every level runs `default` and `optimized`; select one with `--profile default`
or `--profile optimized`. Default leaves producer/fetcher/handler tuning options
at the tested Klife version's built-in defaults. Setup disables unused
transaction pools and supplies the benchmark connection and topics.

Optimized settings are explicit in each scenario module, aimed at that workload:

- Producer throughput: TCP_NODELAY, zero linger, one in-flight request and one
  batcher per broker to preserve batching efficiency; larger byte batches for
  batch/async workloads. Short local scale checks found additional pipelining
  and batchers reduced throughput for these workloads.
- Consumer throughput: larger fetches and prefetch queues, an explicit fetch
  batcher count, and a bounded allowance for records awaiting commit confirmation.
- Latency: a single fetch batcher per broker, short empty-poll intervals, zero
  linger and allowance for unconfirmed commits to reduce delivery delays.

Both profiles retain `acks: :all`, idempotence, no compression and committed
reads. Optimized is a workload-specific tuning profile, not a guarantee that
every setting wins on every host; inspect both profiles at each scale. Change
the scenario's settings to tune for your hardware. A comparison applies the same
explicit optimized overrides to both Klife versions. Each saved sample contains
the overrides and resolved settings, including calculated fetch batcher counts.

## Measurement and comparison

Default timed phases are five seconds after a one-second warmup, repeated five
times (`--seconds`, `--warmup`, `--samples`). Producer partitions are initialized
before timing. Bulk production measures actual completions, including final
acknowledgment drain. Batch acknowledgment latency is per call, including the
whole batch.

Catch-up preloads 10,000 records per partition (`--records-per-partition`), checks
every write, and starts the recovery clock when the first partition activates,
before fetching any records. Delivery throughput and final committed catch-up
time are reported separately; completion requires every partition's Kafka-stored
offset to reach its backlog end. Group preparation before that first activation
is outside recovery time and reported as startup. All fetches, decoding and
subsequent partition activation are timed. A nonzero warmup performs one additional
full recovery pass; `--seconds` does not control a fixed-backlog run.

Latency-sensitive records follow a fixed arrival schedule independent of
responses. Both acknowledgment and delivery timing begin at the planned send,
including sender delay and queueing. The benchmark reports dispatch lateness
and counts offers beyond the 4,096-record pending cap as dropped/overloaded.
Accepted records must all be acknowledged and delivered. Consumer delivery ends
at callback entry, before application processing and commit confirmation.
At sparse rates, short phases contain few tail samples; increase `--seconds`
when collecting meaningful p99 numbers. Zero warmup can include group activation.

The full suite has 42 combinations per version. With default phase durations and
five samples, timed phases alone take about 15 minutes per version, plus setup
and catch-up passes. Use `--samples 1` for shorter iterations or the smoke command
above to check setup. Every workload validates completion counts; errors and
unexpected/missing delivery or commit offsets fail the run.

With `--baseline REF`, the task creates a temporary detached worktree, builds
each version with its own lockfile, and runs the **same current harness** in
separate production VMs. Version order alternates each sample. The baseline
worktree is removed afterward; the candidate includes current uncommitted edits.
The host's Elixir/OTP and dependency native build toolchain must support both
versions. Runtime, revision, dirty status and dependency lock hash are recorded.
On this Fedora/GCC 16 host, v1.2.0's pinned `crc32cer` 1.1.3 needs position-independent
C++ code: prefix the command with `CXXFLAGS=-fPIC`. This builds its original
lockfile successfully; the build environment is recorded in the sample.

Every invocation gets a new, timestamped directory under **`bench/results/`**.
The entire directory is Git-ignored. For a descriptive name, use
`--output bench/results/my-candidate`; existing directories are never overwritten.

Start with **`report.md`**. It links to a detailed report for each sample and
records the run's status, UTC timestamps, arguments, parameters, revisions, sample
counts and baseline/candidate medians, min–max ranges and percentage changes.
Results are grouped by scenario. The first table summarizes improved, degraded
and unchanged primary metrics. Each scenario has a compact table for every
variant/profile/scale, followed by expandable tables with all measurements.

Assessments use the release-check tolerances: within 5% throughput or 10% latency
is **unchanged within tolerance**. Beyond those bands, non-overlapping sample
ranges determine improved/degraded; overlapping ranges are **inconclusive**.
Missing samples are pending, overloaded samples are inconclusive, and opposing
changes across primary metrics produce **mixed** assessments. This is a
descriptive screen, not a statistical significance test or a release gate.

- `sample-candidate-1.md`, `sample-baseline-1.md`, etc.: every scenario/variant's
  record count, elapsed time, throughput, all applicable latency percentiles,
  startup and overload counts, timestamps and full effective configuration.
  Each sample also records Elixir/OTP, OS, scheduler count, dependency versions,
  lockfile hash and build environment.
- `samples.csv`: all metrics from every sample, including p50/p95/p99, scheduling
  delay, startup and overload counts.
- `sample-*.etf` and `.etf.txt`: raw results and effective settings, machine-readable
  and human-readable. `run.etf` stores invocation metadata. ETF files are trusted
  task artifacts, not external inputs.

Reports update after each result, outside the measurement window. Failed runs
retain partial results and failure details; unfinished samples are clearly
marked. Percentage changes are omitted for incomplete or overloaded comparisons.
Keep each run's folder to compare later; no Kafka connection is needed to read
its Markdown or CSV files.

Positive throughput deltas and negative latency deltas indicate improvement.
Compare matching scenario, variant, profile and level. Differences within the
sample range need longer measurements; this task does not declare release gates.

Run the benchmark's standalone unit checks without Kafka:

```sh
elixir bench/release_benchmark/test.exs
```
