# Changelog

Notable changes to Klife, grouped by release. Historical entries were reconstructed
from the [published releases](https://github.com/oliveigah/klife/releases) and the
commits between release tags. Related changes are combined; release dates follow
GitHub publication dates (UTC).

## Unreleased

### Added

- SASL authentication with `SCRAM-SHA-256`, `SCRAM-SHA-512`, and `OAUTHBEARER`, alongside the existing `PLAIN` mechanism. OAuth tokens are supplied through a configurable `token_mfa`, with optional extensions.
- Automatic renewal of expiring SASL sessions on broker and bootstrap connections. Broker connections are replaced before expiration while the old connection drains outstanding responses; bootstrap renewal can fall back to another configured server.
- Producer leader handoff: transfer buffered, queued, and in-flight batches to the new partition leader while preserving producer epochs, sequence numbers, callbacks, and delivery deadlines. This also fixes epoch-fencing errors in transactions when a partition leader changes. A handoff that exceeds `request_timeout_ms` fails affected records with `:handoff_expired`.
- Custom connections: `custom_connections` in the client's `connection` options declares connections with TCP connections of their own to every broker, each able to set its own `connection_count`, `connect_opts`, `socket_opts` and `sasl_opts`. Producers, txn pools, fetchers and consumer groups pick one with the new `:connection` option, and `default_connection`, `default_fetch_connection` and `default_critical_connection` choose the ones they use when they don't. See [Connections](guides/examples/client_configuration.md#connections).

### Changed

- Require Elixir 1.15 or later and upgrade `klife_protocol` from `~> 1.0` to `~> 2.1`.
- Reduce connection and metadata overhead by receiving socket replies in groups, caching frequently used table names, and generating direct tuple/map conversions.
- During a leader handoff, overlapping asynchronous or concurrent produce calls can reach the new leader in a different invocation order when a call is forwarded from the old batcher. Sequential synchronous calls retain their ordering guarantee.
- Requests go over three default connections: fetches over `:klife_fetch_connection`, consumer group requests and metadata refreshes over `:klife_critical_connection`, everything else over `:klife_default_connection`. A client now keeps `3 * connection_count` TCP connections to each broker, instead of `connection_count`. Setting the three `default_*connection` options to the same name keeps a single connection, as before.
- Expiring SASL sessions must last at least `2 * (default_request_timeout_ms + 5_000)` milliseconds: 70 seconds with the default request timeout. Shorter sessions are rejected because outstanding requests cannot safely drain before expiration. See the [SASL configuration guide](guides/examples/client_configuration.md#sasl).

### Fixed

- Fetches waiting for records (`max_wait_ms` above 0) no longer delay produce, heartbeat, offset commit and metadata requests to the same broker. They shared its TCP connections, which brokers answer in order, so each fetch could add up to `max_wait_ms` to them.
- Clients with fetchers configured in `fetchers` (other than one named after the default fetcher) failed to start: every fetcher had the same supervisor child id.
- Serialize records correctly when producer idempotence is disabled, including when using compression.
- Handle transaction abort markers in `:read_uncommitted` fetches without crashing the dispatcher when no aborted-offset list is available.
- Filter asynchronous fetch responses from the requested offset, matching synchronous fetch behavior when Kafka returns a batch that starts at an earlier offset.
- Allow broker verification to wait for the configured request timeout instead of failing after the default five-second `GenServer.call/3` timeout.
- Resolve compilation warnings on Elixir 1.20.

### Development

- Add isolated Docker Compose simulation workers, parallel campaigns, reproducible reruns, configurable resource limits, and coverage for the new SASL mechanisms.
- Add `mix release_benchmark` with comparisons between revisions, default and tuned profiles, throughput and latency reports, and workloads covering consumer catch-up, synchronous and asynchronous production, and latency-sensitive traffic.
- Document the release validation process, including test matrices, benchmarks, simulations, soak tests, and evidence archives.
- Test against Kafka 4.0 and 4.4 with Elixir/OTP 1.17/26 and 1.20/28; add a separate formatting check and production compilation with warnings treated as errors.
- Stabilize integration tests around broker restarts, transactions, and partition leader changes. Limit formatter inputs to source files so generated benchmark and simulation evidence is left untouched.

## [1.2.0] - 2026-07-12

### Added

- Per-client `metadata_check_interval_ms` configuration and reactive metadata refreshes when produce or fetch responses indicate stale partition leadership or topic metadata.

### Changed

- Upgrade `klife_protocol` to `~> 1.0`.

### Fixed

- Commit and resume consumer offsets using Kafka's convention that a committed offset identifies the next record to consume, improving interoperability with other clients and monitoring tools.
- Calculate fetched record offsets from each record's `offset_delta`, preserving gaps in compacted batches and correctly marking aborted records.
- Match synchronous broker responses by correlation ID so a late response from an earlier request cannot be consumed by a later call. Handle the race between response delivery and timeout cleanup.
- Recover transaction workers after callback exceptions or transaction completion failures by aborting the unfinished transaction, or restarting the producer if abort fails, before returning the worker to the pool.
- Restore producer sequence progress after non-retryable batch failures by bumping the affected partitions' epochs.
- Match asynchronous producer callback records to their correct offsets within a batch.
- Return retryable errors for unexpected or undecodable fetch responses instead of crashing the dispatcher and leaving outstanding fetches waiting for timeouts.

## [1.1.0] - 2026-06-13

### Added

- Manual consumer group mode (`mode: :manual`): external pipelines can pull buffered batches and commit processed offsets while Klife manages fetching, membership, and rebalances. This enables integrations such as [off_broadway_klife](https://github.com/oliveigah/off_broadway_klife).
- Consumer group `pull`, `commit`, and `assigned_partitions` functions, including wrappers on modules using `Klife.Consumer.ConsumerGroup`.
- Ownership monitoring for manually pulled records. If the owner dies with uncommitted records, or another owner takes over an outstanding lease, the partition consumer restarts to redeliver from the committed offset.
- Runtime client binding for reusable consumer group modules: supply `:client` on the first `start_link/1` instead of requiring it in `use`. A module remains bound to one client.
- Record timestamps on fetched `Klife.Record` structs, expressed in milliseconds since the Unix epoch.

### Changed

- Make `handle_record_batch/4` optional for groups whose topics all use manual mode; validate that automatic topics have a handler.
- Document manual-mode pacing, batch sizing, commit behavior, and consumer memory tuning.

### Fixed

- Allow graceful group shutdown to finish when a partition consumer has already stopped or dies during revocation.

## [1.0.0] - 2026-05-02

### Added

- Consumer groups using Kafka 4.0's KIP-848 rebalance protocol, including broker-managed assignments, heartbeats, static membership through `instance_id`, and partition revocation.
- `handle_record_batch/4` callbacks with batch-level or per-record commit/retry actions, retry attempt counts, configurable cooldowns, and consumer lifecycle callbacks.
- Batched offset commits, commit pipelining, liveness checks, and graceful shutdown that processes outstanding records and commits their offsets before leaving the group.
- Per-topic consumer configuration with group-wide defaults, fixed or dynamic handler batch sizes, bounded queues, backpressure, and earliest/latest offset reset policies.
- Shared or exclusive fetchers at consumer group and topic level, allowing independent fetch settings and isolation between workloads.
- Direct synchronous, batched, and asynchronous fetch APIs for applications that manage their own partitions and offsets, with `:read_committed` and `:read_uncommitted` isolation.
- Multiple connections per broker through the `connection_count` option.
- Structured logging metadata and `Klife.log_metadata/0` for configuring Logger output.
- A seeded simulation framework covering randomized client and consumer settings, broker failures, consumer restarts, partition expansion, and ordering, duplication, and data-loss invariants.
- Consumer benchmarks and expanded configuration, delivery-semantics, and performance documentation.

### Changed

- **Upgrade note:** switch the default keyed partitioner from Erlang `phash2` to Kafka-compatible `murmur2`. Applications that need the previous key-to-partition mapping must provide a custom partitioner.
- **Upgrade note:** increase the default request timeout from 15 to 30 seconds and expose `default_request_timeout_ms` in connection configuration.
- **Upgrade note:** default `Klife.Record.headers` to `[]` instead of `nil`; update pattern matches that depend on the old default.
- Share batching infrastructure between producers and fetchers and move topic/partition metadata into a dedicated cache.
- Focus consumer group support and integration testing on Kafka 4.0 and later. Producer features remain subject to API version negotiation on older brokers.

### Fixed

- Handle transactional records during consumption with transaction marker filtering and per-producer aborted-offset tracking.
- Improve consumer recovery from fetch and commit failures, coordinator changes, expired membership, and stalled partition consumers.
- Complete pending produce and fetch requests when their batcher or broker is removed instead of leaving callers waiting for a timeout.
- Correct producer retry notifications, epoch bumps, and sequence rewriting for queued and in-flight batches after delivery errors.
- Honor explicit configuration for default producers and transaction pools instead of overriding it with generated defaults.
- Improve metadata refresh, SSL message handling, and producer/fetcher recovery during cluster changes.

## [0.5.1] - 2026-02-13

### Fixed

- Write producer batch timestamps in milliseconds instead of seconds. Incorrect timestamps made new records appear to date from January 1970, allowing Kafka retention to delete them prematurely and causing intermittent `OffsetOutOfRange` errors or skipped records for consumers.

## [0.5.0] - 2024-11-23

### Added

- Disable unsupported features individually after API version negotiation, with startup warnings and descriptive runtime errors when a disabled API is called.
- Explicit `disabled_features` client configuration for producers and transactional producers.

### Changed

- Use `FindCoordinator` v1 for transactional coordinator discovery, broadening broker compatibility.

### Fixed

- Avoid starting producer systems for disabled features and report when idempotence is requested but unavailable.
- Improve producer initialization and coordinator-discovery error logs, including client names and broker error codes.

## [0.4.0] - 2024-11-22

### Changed

- Negotiate Produce API versions 3 through 9 instead of requiring version 9.
- Allow startup when `AddPartitionsToTxn` is unavailable, warning that transactions cannot be used instead of preventing non-transactional production.

## [0.3.0] - 2024-11-18

### Changed

- Send single-record asynchronous produce requests directly to the batcher and start callback tasks only after a result is available, avoiding a task waiting on each produce call.
- Use the same direct asynchronous path for batch production without a callback. Batch calls with a callback retain one task to collect the complete batch result.

### Development

- Add asynchronous producer benchmarks and comparisons with `erlkaf`, alongside the existing `brod` and `kafka_ex` comparisons.

## [0.2.0] - 2024-10-28

### Changed

- Return the complete record list from `Klife.Record.verify_batch/1` on partial failure, preserving successful records alongside failed ones in the `{:error, records}` result.
- Simplify generated client code by moving initialization into a shared implementation, and use string names for transactional producers instead of dynamically creating atoms.

### Fixed

- Correct broker reconnection backoff jitter and cluster-verification waiter handling.
- Keep timer references for scheduled cluster checks so subsequent checks can cancel the timer correctly.
- Wrap request correlation IDs within the supported range without a periodic counter reset.
- Exclude SASL credentials from connection controller inspection.
- Return `:ok` consistently from `Klife.Testing.setup/1` and correct usage examples.

## [0.1.0] - 2024-10-26

Initial public release, focused on producing records.

### Added

- Supervised Kafka clients with automatic broker discovery, metadata management, reconnection, and API version negotiation.
- Synchronous and asynchronous produce APIs, callbacks, and batch production across multiple topics and partitions.
- Per-broker batching, configurable producers, idempotent production, retries, delivery timeouts, and gzip/snappy compression.
- Custom partitioners and topic-specific producer configuration, including support for topics not explicitly configured in the client.
- Transactional producer pools, `transaction`, and `produce_batch_txn` APIs.
- TCP and SSL/TLS connections with SASL/PLAIN authentication.
- `Klife.Record` structs and helpers for verifying batch results.
- `Klife.Testing` helpers for checking produced records against a real broker.
- An example application, client configuration documentation, and synchronous producer benchmarks.

[unreleased]: https://github.com/oliveigah/klife/compare/v1.2.0...main
[1.2.0]: https://github.com/oliveigah/klife/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/oliveigah/klife/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/oliveigah/klife/compare/v0.5.1...v1.0.0
[0.5.1]: https://github.com/oliveigah/klife/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/oliveigah/klife/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/oliveigah/klife/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/oliveigah/klife/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/oliveigah/klife/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/oliveigah/klife/commits/v0.1.0
