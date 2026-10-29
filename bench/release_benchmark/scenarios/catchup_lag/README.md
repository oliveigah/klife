# Catch-up lag

Measures how quickly a consumer group clears a sudden backlog at maximum
available processing capacity, including the time until Kafka stores the final
committed offsets.

```sh
mix release_benchmark --scenario catchup_lag
```

## Real-world use cases

- **Paused processing after maintenance:** a consumer resumes with many records
  waiting and needs to restore fresh downstream state quickly.
- **Lag spike after a bulk import:** a migration publishes changes faster than
  an indexing or projection consumer processes them; this tests draining the
  accumulated spike once production finishes.
- **Replay of missed events:** a projection or analytics worker catches up on
  records accumulated during an interruption.

The callback validates offsets and counts records. Application processing such
as database writes adds its own capacity limit beyond this client benchmark.

## Main metrics to observe

| Metric | Role / better direction | What it tells you |
|---|---|---|
| `catchup_ms` | Primary; lower | Time from the first partition's activation, before fetching, until every partition's committed offset reaches the backlog end. |
| `records_s` | Primary; higher | Callback delivery rate during recovery, before the final commit drain. |
| `delivery_drain_ms` | Diagnostic; lower for the same backlog | Time until all records have reached callbacks. |
| `commit_drain_ms` | Diagnostic; lower | Additional time to observe final committed offsets after delivery finishes. |
| `initial_lag_records`, `remaining_lag_records` | Validity | The initial spike must match the preload; remaining committed lag must be zero. |
| `startup_ms` | Diagnostic; lower | Group preparation before the first partition activates, reported separately from catch-up. |

Compare matching backlog sizes, partition counts, strategies and profiles.
Fast callback delivery with slower final commits is visible as a larger
`commit_drain_ms`; it should not be mistaken for complete lag recovery. Short
drains have noisy rates, so increase `--records-per-partition` when needed.
At small backlogs, activation and protocol delays can dominate the recovery
rate. Increase the backlog to study sustained delivery capacity.

## Workload and scales

| Level | Topics | Partitions per topic | Backlog with the default 10,000 records/partition |
|---|---:|---:|---:|
| 1 | 3 | 1 | 30,000 records |
| 2 | 3 | 6 | 180,000 records |
| 3 | 3 | 24 | 720,000 records |

Values default to 1,024 bytes with 50-byte keys. The dataset is written and every
produce result checked before measurement. Production finishes before catch-up
starts, isolating recovery from a fixed spike.

Each level has **shared** and **exclusive** fetcher variants. Shared uses the
client's existing fetcher. Exclusive starts one fetcher for the group, serving
all three topics.

## How measurement works

A fresh group starts at `:earliest`. The recovery clock starts in the first
partition's start callback, before it fetches any records. All fetching, decoding,
delivery and subsequent partition activation are inside that clock. Initial
group preparation before the first partition activates is reported separately
as `startup_ms`; it does not dominate the recovery measurement.

The benchmark checks exact delivery counts and final record offsets, then reads
Kafka's committed offsets through `OffsetFetch`. Completion requires every
partition's stored next offset to equal its seeded record count. Missing or
unexpected partitions/offsets fail the run. Coordinator lookup and commit checks
run after delivery, with a 5 ms retry interval for pending commits. Recovery and
`commit_drain_ms` include this observation overhead.

Throughput uses the delivery interval; `catchup_ms` also includes the final
commit drain. If `--warmup` is nonzero, one complete recovery pass precedes the
measured pass, each with a fresh group. `--seconds` does not control this case:
the fixed backlog determines its duration.

## Configuration variants

Three levels, two fetch strategies and two profiles produce twelve cases per
version per sample. **Default** uses the tested version's fetcher/handler defaults.
**Optimized** sets:

| Setting | Value |
|---|---|
| Fetch batchers per broker | `min(8, max(1, ceil(schedulers_online / 3)))` |
| Fetcher bytes per request | 20,000,000 |
| Fetcher maximum wait | 0 ms |
| Topic fetch bytes | 4,000,000 |
| Empty-poll interval | 1 ms |
| Queued batches per partition | 10 |
| Records awaiting commit confirmation | 100,000 |
| TCP_NODELAY | Enabled |

Larger buffers and more unconfirmed commits trade resource use and commit lag
for delivery capacity. Measuring committed catch-up exposes that tradeoff.
Use `--profile default|optimized`, `--levels` and `--records-per-partition` to
select the comparison size.

[Scenario module](scenario.exs) · [Measurement implementation](../../workload.exs) ·
[Setup, version comparison and reports](../../../README.md)
