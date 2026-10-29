# Heavy synchronous production

Measures how fast applications can publish Kafka records when each worker waits
for acknowledgment before continuing. Single-record and batch APIs are variants
of this same workload.

```sh
mix release_benchmark --scenario heavy_sync_production
```

## Real-world use cases

- **Database migration or backfill:** workers read source rows, publish a chunk,
  and advance their checkpoint after the results succeed. Batch throughput
  controls migration duration; slow batch acknowledgments hold workers up.
- **Bulk catalog import:** parallel import workers publish product changes and
  wait for each write or batch before processing more input.
- **Synchronous event publishing:** many request/job processes wait for broker
  acknowledgment before returning success or moving to their next step.

These examples motivate the workload. The benchmark prepares records in memory
and measures Kafka publishing, so source database reads and application work do
not affect the numbers.

## Main metrics to observe

| Metric | Better direction | What it tells you |
|---|---|---|
| `records_s` | Higher | Completed records per second; the main bulk publishing capacity metric. |
| `ack_p99_ms` | Lower | Tail time a worker waits for its entire call, including a whole API batch. |
| `ack_p50_ms`, `ack_p95_ms` | Lower | Whether waiting affects most calls or mainly the tail. |

Compare versions at the same variant, level and profile. More throughput with
longer batch latency can be a useful bulk-import tradeoff. Batch latency is per
call, rather than per record. Throughput flattening while latency rises with
more callers suggests saturation. The report compares `records_s` and
`ack_p99_ms` as primary metrics.

## Workload and scales

| Level | Single-record variant | Batch variant |
|---|---|---|
| 1 | 1 concurrent caller, 1 record/call | 16 callers, 1 record/call |
| 2 | 8 concurrent callers, 1 record/call | 16 callers, 10 records/call |
| 3 | 64 concurrent callers, 1 record/call | 16 callers, 100 records/call |

The single-record variant calls `Client.produce/1`; the batch variant calls
`Client.produce_batch/1`. Each worker checks every result and offset, then starts
its next call. The sending rate is determined by completion speed.

Prepared records rotate across three topics with twelve partitions each, using
explicit partitions, 1,024-byte values and 50-byte keys by default. Klife can
combine records from several workers into internal broker requests.

## How measurement works

Partition initialization and payload generation happen before timing. Defaults
are one warmup second followed by five measured seconds (`--warmup`, `--seconds`).
Workers stop starting calls at the deadline and finish their outstanding work.

Throughput counts successful records across all workers over actual elapsed
seconds, including the final drain. Acknowledgment latency starts immediately
before the API call and ends after checking its results. Constructing an API
batch is outside the call-latency timer but inside the throughput measurement.
An unsuccessful result fails the run.

## Configuration variants

Both profiles run for both API variants at every level: twelve cases per version
per sample. **Default** uses the tested version's producer defaults.
**Optimized** enables TCP_NODELAY and explicitly keeps one batcher and one
in-flight request per broker with zero linger. Its batch variant also sets
`batch_size_bytes: 1_000_000` to allow larger internal requests.

These settings preserve acknowledgments and idempotence. One application batch
can span several broker requests. Extra batchers and pipelining reduced bulk
throughput in the local calibration, so this profile favors coalescing records.
Use `--profile default|optimized` or `--levels 1,2` to narrow a run.

[Scenario module](scenario.exs) · [Measurement implementation](../../workload.exs) ·
[Setup, version comparison and reports](../../../README.md)
