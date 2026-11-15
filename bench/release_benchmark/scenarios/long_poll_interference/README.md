# Long-poll interference

Measures synchronous production while a consumer group long-polls topics that
never receive records. Each idle fetch is held by its broker for `max_wait_ms`.
The workload shows whether those held fetches delay produce requests to the
same brokers.

```sh
mix release_benchmark --scenario long_poll_interference
```

This is the "Fetching and long polling" scenario of the
[configuration guide](../../../../guides/configuration.md#fetching-and-long-polling).

## Real-world use cases

- **Audit or archive consumers on quiet topics:** a group uses a positive
  `max_wait_ms` to avoid empty fetches while the same application produces
  business events.
- **Request handlers that publish synchronously:** a held fetch on a shared
  connection adds its wait to the produce call, and so to the request.

## Main metrics to observe

| Metric | Role / better direction | What it tells you |
|---|---|---|
| `ack_p99_ms` | Primary; lower | Produce call latency while fetches are held. A value near `max_wait_ms` means produce requests waited behind them. |
| `records_s` | Primary; higher | Completed records per second across the eight callers. |
| `ack_p50_ms`, `ack_p95_ms` | Supporting; lower | Whether every call or only the tail waits. |

Level 1 (`max_wait_ms: 0`) is the control: the idle group still polls, but no
fetch is held.

## Workload and scales

| Level | Idle fetch `max_wait_ms` | Callers |
|---|---:|---:|
| 1 | 0 | 8 |
| 2 | 1,000 | 8 |
| 3 | 5,000 | 8 |

Eight callers produce single records synchronously to the heavy production
topics (three topics, twelve partitions each). An exclusive fetcher with the
level's `max_wait_ms` follows three idle topics with three partitions each, so
every broker holds one of its fetches. The idle topics poll again 100 ms after
each empty response (`fetch_interval_ms: 100`). The fetcher's request timeout is
`max_wait_ms` plus 30 s.

## How it relates to Klife's connections

A broker answers one request at a time on each TCP connection. Up to v1.2.0,
production and fetching share each broker's connection, so produce requests
wait for held fetches. Since the named connections of 1.3.0, fetchers use
`default_fetch_connection` and producers `default_connection`, which are
separate TCP connections by default.

A short local check (one sample, 3 s phases) at level 3: v1.2.0 completed about
1 record/s with an acknowledgement p99 of about 15 s; the 1.3.0 candidate kept
about 970 records/s and 25 ms, the same as its level 1 control.

## Configuration variants

Three levels and two profiles produce six cases per version per sample.
**Default** uses the tested version's producer and fetcher defaults. **Optimized**
applies the heavy synchronous production tuning (one batcher and one in-flight
request per broker, zero linger, TCP_NODELAY), so only the long polls differ
between levels.
