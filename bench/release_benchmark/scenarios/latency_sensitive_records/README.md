# Latency-sensitive records

Measures how quickly sparse, urgent records are acknowledged and delivered to
consumers. The workload sends at controlled low-to-moderate rates and watches
tail latency instead of trying to maximize throughput.

```sh
mix release_benchmark --scenario latency_sensitive_records
```

## Real-world use cases

- **Order and payment state updates:** a checkout publishes an event so a
  downstream reservation, risk or notification worker can react promptly.
- **Fraud or operational alerts:** event volume is modest, but a delayed alert
  can matter more than aggregate throughput.
- **Interactive workflows:** a user action emits a command/event and the next
  service should start handling it with little delay, even after idle periods.

The measured path ends at consumer callback entry. Business processing and
external side effects follow that point. Application transaction events are the
motivation; Kafka's transactional produce API is a separate workload.

## Main metrics to observe

| Metric | Role / better direction | What it tells you |
|---|---|---|
| `e2e_p99_ms` | Primary; lower | Scheduled send to consumer callback: tail delay before the downstream worker can start. |
| `ack_p99_ms` | Primary; lower | Scheduled send to producer acknowledgment callback. |
| `dispatch_p99_ms` | Diagnostic; lower | Sender lateness already included in the primary latency metrics. |
| `ack_p50_ms`, `ack_p95_ms`, `e2e_p50_ms`, `e2e_p95_ms` | Supporting; lower | Whether delay affects most records or mainly the tail. |
| `records`, `dropped` | Validity | Verify the accepted sample count and require zero dropped offers for a comparison. |

Compare the same arrival rate, fetch strategy and profile across versions.
Throughput is supporting context because the arrival rate is fixed. Low-volume
short runs have few tail samples: at 10 records/s, a five-second phase contains
only 50 records. Increase `--seconds` for a stronger p99 comparison.

## Workload and scales

| Level | Total arrival rate | Topics | Partitions per topic |
|---|---:|---:|---:|
| 1 | 10 records/s | 3 | 1 |
| 2 | 100 records/s | 3 | 1 |
| 3 | 1,000 records/s | 3 | 1 |

These dedicated topics model a few event streams. Prepared 1,024-byte values
and 50-byte keys rotate across explicit partitions. Each value carries its
phase identifier and scheduled-send timestamp.

Both **shared** and **exclusive** consumer fetchers are measured. Shared reuses
the client's fetcher; exclusive creates one for the group and all its topics.

## How measurement works

The group starts at `:latest` after partition initialization. The sender waits
for consumer-start notifications, runs a warmup phase, and fully acknowledges
and consumes it before starting measurement. Defaults are one warmup second and
five measured seconds (`--warmup`, `--seconds`). With zero warmup, initial group
activation can affect the result.

Offers follow a fixed schedule independent of responses. A late offer keeps its
original timestamp, so queueing and sender delays remain visible. At most 4,096
producer records may await callbacks. Offers beyond that cap are dropped and
mark the sample overloaded, suppressing comparison deltas. Accepted records
must all be acknowledged and delivered before the phase ends.

Acknowledgment latency ends at the producer callback; delivery latency ends at
the consumer callback before application processing or offset commit
confirmation. Dispatch delay records sender lateness just before submission.
Sleep resolution can create small submission bursts, which this diagnostic
helps expose. `records_s` includes final delivery drain and can be below the
offered rate without indicating maximum publishing capacity.

## Configuration variants

Three rates, two fetch strategies and two profiles produce twelve cases per
version per sample. **Default** uses the tested version's producer, fetcher and
handler defaults. **Optimized** enables TCP_NODELAY, sets producer pipelining to
five requests per broker, uses one producer/fetch batcher per broker, zero
linger and fetcher maximum wait, a 1 ms topic empty-poll interval, and an
allowance of 100,000 records awaiting commit confirmation. Acknowledgments,
idempotence and committed reads remain enabled.

These settings favor prompt delivery, with extra polling and unconfirmed
commits as tradeoffs. Select variants with `--profile default|optimized` and
`--levels`. Use a longer phase when collecting release tail-latency numbers:

```sh
mix release_benchmark --scenario latency_sensitive_records --seconds 30
```

[Scenario module](scenario.exs) · [Measurement implementation](../../workload.exs) ·
[Setup, version comparison and reports](../../../README.md)
