# Heavy asynchronous production

Measures publishing capacity when the application can keep many records
outstanding and handle acknowledgments asynchronously. The workload pushes
completed delivery throughput while bounding the amount of pending work.

```sh
mix release_benchmark --scenario heavy_async_production
```

## Real-world use cases

- **Telemetry or activity ingestion:** a collector keeps publishing incoming
  events while acknowledgments for previous records arrive.
- **Large export or migration pipeline:** workers stream prepared records to
  Kafka and keep a bounded window of pending deliveries instead of waiting
  after every record.
- **Background event delivery:** an application publishes buffered events with
  callbacks and limits outstanding work to keep queue growth under control.

The benchmark's source is a prepared in-memory pool, isolating Kafka publishing
from source reads or event-generation cost.

## Main metrics to observe

| Metric | Better direction | What it tells you |
|---|---|---|
| `records_s` | Higher | Acknowledged records per second, including final drain; actual publishing capacity. |
| `ack_p99_ms` | Lower | Tail submission-to-callback time, including queueing and callback scheduling. |
| `ack_p50_ms`, `ack_p95_ms` | Lower | Whether delay is widespread or concentrated in outliers. |

The primary comparison uses `records_s` and `ack_p99_ms` at the same outstanding
window and profile. If a larger window raises latency without increasing
throughput, it is adding waiting work with little capacity benefit. A long final
drain is reflected in the throughput result.

## Workload and scales

| Level | Maximum outstanding application records |
|---|---:|
| 1 | 1 |
| 2 | 32 |
| 3 | 1,024 |

One sender fills the window using `Client.produce_async/2` with a callback. Each
successful callback frees a slot, which is replaced until the sending deadline.
The sender then waits for every remaining acknowledgment. It counts completed
records rather than enqueue calls.

The window counts records awaiting callbacks. The producer's
`max_in_flight_requests` controls Kafka requests per broker; each request can
contain many application records. Prepared records rotate across three topics
with twelve partitions each, with explicit partitions, 1,024-byte values and
50-byte keys by default.

## How measurement works

Payload generation and partition initialization are outside timing. Defaults are
a one-second warmup and a separate five-second measurement (`--warmup`,
`--seconds`). The timer includes the initial window fill and final drain.

Throughput is acknowledged records over actual elapsed seconds. Latency starts
before submission and ends when the public callback executes. The callback
captures its own timestamp, so the sender's later notification collection does
not inflate that latency. Callback scheduling itself remains part of the
measurement. Errors, duplicate callbacks or missing completions fail the run.

## Configuration variants

Both profiles run at all three levels: six cases per version per sample.
**Default** uses the tested version's built-in producer settings. **Optimized**
uses one batcher and one in-flight request per broker, zero linger, a
1,000,000-byte internal batch limit, and TCP_NODELAY. These settings favor
combining outstanding records while retaining acknowledgments and idempotence.

Use `--profile default|optimized` and `--levels` to select variants. For sparse
urgent events, use [latency-sensitive records](../latency_sensitive_records/README.md).

[Scenario module](scenario.exs) · [Measurement implementation](../../workload.exs) ·
[Setup, version comparison and reports](../../../README.md)
