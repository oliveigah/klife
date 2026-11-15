# Isolated workloads

Measures latency-sensitive records while bulk asynchronous production runs on the
same client, with and without the isolation the configuration guide recommends.

```sh
mix release_benchmark --scenario isolated_workloads
```

This is the "Isolating workloads" scenario of the
[configuration guide](../../../../guides/configuration.md#isolating-workloads).

## Real-world use cases

- **Payments next to an export:** payment events must stay prompt while a bulk
  export or backfill keeps the producer busy.
- **Alerts next to telemetry:** a few urgent records share a client with a
  high-volume stream.

## Main metrics to observe

| Metric | Role / better direction | What it tells you |
|---|---|---|
| `ack_p99_ms` | Primary; lower | Scheduled send to acknowledgement of urgent records under bulk load. |
| `e2e_p99_ms` | Primary; lower | Scheduled send to consumer callback of urgent records. |
| `bulk_records_s` | Supporting; higher | Bulk throughput during the phases: what isolation costs or gains for bulk work. |
| `dropped` | Validity | Offers beyond the 4,096-record pending cap; must be zero for a comparison. |

## Workload and scales

| Level | Urgent rate | Bulk outstanding records |
|---|---:|---:|
| 1 | 100 records/s | 0 (no bulk load) |
| 2 | 100 records/s | 64 |
| 3 | 100 records/s | 1,024 |

Urgent records follow the latency-sensitive records workload: a fixed schedule
over three single-partition topics, consumed by a group on the client's shared
fetcher, with the same timing boundaries. Bulk records go to the heavy production
topics through the default producer, with a fixed number of outstanding records,
starting before the measured phases and stopping after them.

## Configuration variants

| Variant | Urgent records use | Versions |
|---|---|---|
| `shared` | The default producer and connection, like the bulk records | All |
| `dedicated_producer` | A second producer, `:urgent_producer`, on the default connection | All |
| `dedicated_connection` | `:urgent_producer` on a custom connection `:urgent` with TCP_NODELAY, as in the guide's payments example | 1.3.0 and later (`custom_connections`) |

Versions without `custom_connections` skip `dedicated_connection`; the report
marks it as candidate only.

**Default** uses the tested version's defaults for everything except this
structure. **Optimized** keeps the heavy asynchronous production tuning for the
default (bulk) producer, gives `:urgent_producer` the latency-sensitive producer
tuning, and applies the latency-sensitive fetcher, topic and socket settings.

Three levels, three variants and two profiles produce eighteen cases per version
per sample. As with latency-sensitive records, use a nonzero warmup: with
`--warmup 0`, group activation lands in the first measured phase.
