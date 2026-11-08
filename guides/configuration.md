# Configuration guide

Klife's defaults favor batching, ordered production and at-least-once consumption.
This guide explains when to keep those defaults and when a workload benefits from
different settings. The numbers in tuning examples are starting points to measure.

Use the module documentation for the complete option reference and the
[client configuration examples](examples/client_configuration.md) for additional
syntax examples.

## Choose a scenario

| Workload or symptom                            | Start here                                                    |
| ---------------------------------------------- | ------------------------------------------------------------- |
| Setting up a client                            | [Start with the defaults](#start-with-the-defaults)           |
| Producing from a request handler               | [Latency-sensitive production](#latency-sensitive-production) |
| Publishing a large stream of records           | [High-throughput production](#high-throughput-production)     |
| Bulk traffic or retries delay urgent work      | [Isolating workloads](#isolating-workloads)                   |
| Following a quiet topic or doing one-off reads | [Fetching and long polling](#fetching-and-long-polling)       |
| A consumer cannot catch up                     | [Consumer throughput](#consumer-throughput)                   |
| Consumers use too much memory                  | [Consumer memory](#consumer-memory)                           |
| Writes must commit together                    | [Transactions](#transactions)                                 |
| Deploying across nodes or connecting securely  | [Deployment](#deployment)                                     |

## Start with the defaults

Define a client and start it before any consumer groups that use it.

```elixir
defmodule MyApp.Client do
  use Klife.Client, otp_app: :my_app
end
```

```elixir
# config/config.exs, for a local broker
import Config

config :my_app, MyApp.Client,
  connection: [bootstrap_servers: ["localhost:19092"]]
```

```elixir
# In your application's supervision tree
children = [MyApp.Client]
```

The client reads its application configuration when it starts. Changing the
application environment does not reconfigure running components.

By default, the client starts a producer, a fetcher and a transaction pool with
20 transactional producers. It also opens three named connections to each broker,
each containing one TCP connection. One carries production and transaction
requests, one carries record fetches, and one carries consumer coordination and
metadata requests. These connections are opened eagerly, plus a bootstrap
connection for cluster discovery.

If the application never uses transactions, disable them to avoid starting the
transaction pool and its producers.

```elixir
config :my_app, MyApp.Client,
  connection: [bootstrap_servers: ["localhost:19092"]],
  disabled_features: [:txn_producer]
```

A consumer-only client can set `disabled_features: [:producer, :txn_producer]`.
Disabling features does not remove the default named connections.

### Put each setting at the right level

| Configuration                                      | What it controls                                                            |
| -------------------------------------------------- | --------------------------------------------------------------------------- |
| Client `connection`                                | Cluster, TLS, authentication, named connections and default request timeout |
| Client `producers`                                 | Produce batching, retries, compression and connection selection             |
| Client `topics`                                    | Default producer and partitioner for production                             |
| Client `fetchers`                                  | Fetch batching, broker wait time and connection selection                   |
| Client `txn_pools`                                 | Transaction concurrency and transactional producer settings                 |
| Consumer group                                     | Membership, subscriptions, fetch strategy and coordination connection       |
| Consumer group `default_topic_config` and `topics` | Processing batches, buffering, commit pacing and initial offset policy      |

Client topic configuration does not subscribe a consumer group or create topics
in Kafka. Consumer groups have their own topic list, and Kafka topics must already
exist.

A produce call's `producer:` option overrides the topic's `default_producer`,
which overrides the client's `default_producer`. Partitioner selection follows the
same precedence, unless the record already has an explicit partition. Inside a
transaction, the checked-out transactional producer handles synchronous produce
calls and the `producer:` option is ignored.

Consumer topic options override `default_topic_config`, then fall back to built-in
defaults. Group options passed at startup override options supplied to `use`.

The client automatically adds its selected default producer, fetcher and
transaction pool if their names are absent from the corresponding lists. Declaring
a named producer alone adds it alongside the default. To replace the default,
also set `default_producer` to that name. The same rule applies to `default_fetcher`
and `default_txn_pool`.

The client configuration blocks below are alternatives. Add the relevant settings
to your application's configuration rather than concatenating every example.

## Latency-sensitive production

For records produced on the path of an HTTP request or another interactive
operation, start with `linger_ms: 0`, `acks: :all` and idempotence enabled, which
are already the producer defaults.

Klife batches records that accumulate while earlier requests are in flight, even
with zero linger. A positive `linger_ms` deliberately waits for more records and
can increase latency on quiet topics.

For small writes, try disabling Nagle's algorithm on the production connection
and measure the effect on tail latency and packet rate.

```elixir
config :my_app, MyApp.Client,
  connection: [
    bootstrap_servers: ["localhost:19092"],
    custom_connections: [
      [name: :klife_default_connection, socket_opts: [nodelay: true]]
    ]
  ]
```

This configures the existing default production connection. It does not add a
fourth named connection. Transactions also use it unless their pool selects a
different connection.

If bulk production shares the client, give urgent records their own producer and
connection as shown in [Isolating workloads](#isolating-workloads).

### Keep acknowledgement and timeout choices separate

`acks: 1` lets the leader acknowledge before its replicas have caught up, at the
cost of possible loss of acknowledged records after a leader failure. Keep
`acks: :all` when that tradeoff is unacceptable. Its durability also depends on
Kafka's replication and `min.insync.replicas` configuration. See Kafka's
[acknowledgement reference](https://kafka.apache.org/41/configuration/producer-configs/#acks)
and [broker reference](https://kafka.apache.org/41/configuration/broker-configs/#min.insync.replicas).

Klife has several independent timeout settings.

| Setting                                 | Scope                                                                     |
| --------------------------------------- | ------------------------------------------------------------------------- |
| Connection `default_request_timeout_ms` | Requests without a more specific timeout, including consumer coordination |
| Producer `request_timeout_ms`           | An individual produce request, also used for partition handoff timeout    |
| Producer `delivery_timeout_ms`          | The producer's delivery and retry budget                                  |
| Producer `retry_backoff_ms`             | Delay between retry attempts                                              |
| Fetcher `request_timeout_ms`            | An individual fetch request                                               |

Lowering only `default_request_timeout_ms` does not lower producer or fetcher
timeouts. Keep the delivery budget larger than the request timeout, with room for
backoff and further attempts. Klife reserves time before dispatching another
attempt, so equal request and delivery timeouts leave no useful retry budget.

A shorter delivery timeout fails sooner during outages; it does not make healthy
requests faster. A longer one retains work longer and can delay other records
sharing the same producer's in-flight slots. A timeout can also leave the write's
outcome unknown to the caller. Idempotence handles the producer's protocol retries;
it does not deduplicate a new application-level produce call made after an error.

## High-throughput production

First check whether the application supplies enough concurrent work. A loop that
waits for each `produce/2` call before making the next provides little work to
batch. Prefer `produce_batch/2` when records are already available together, or
use bounded concurrency. Async APIs let the caller continue before delivery, so
use callbacks to observe failures and bound the amount of outstanding work in the
application. The producer's batch size is not a total queue or memory limit.

Once the producer is the bottleneck, try one change at a time.

```elixir
config :my_app, MyApp.Client,
  connection: [bootstrap_servers: ["localhost:19092"]],
  default_producer: :bulk,
  producers: [
    [
      name: :bulk,
      compression_type: :snappy,
      batchers_count: 4,
      max_in_flight_requests: 3
    ]
  ]
```

| Change                             | When it helps                                                    | Cost or limit                                                                  |
| ---------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Compression (`:snappy` or `:gzip`) | Network or broker storage traffic dominates                      | More CPU; compare with realistic payloads                                      |
| Higher `batchers_count`            | A batcher process saturates a core across many active partitions | Smaller batches and more processes; one partition still belongs to one batcher |
| Higher `max_in_flight_requests`    | Waiting for acknowledgements leaves capacity unused              | More outstanding work and less opportunity to accumulate large batches         |
| Larger `batch_size_bytes`          | The current batch size prevents efficient requests               | Larger payloads and memory use; broker limits still apply                      |
| Positive `linger_ms`               | Small requests dominate and extra latency is acceptable          | Adds deliberate waiting; often unnecessary with dynamic batching               |

The default producer has one batcher per broker. With three brokers,
`batchers_count: 4` starts twelve batchers for that producer. Each batcher has its
own in-flight allowance. These settings multiply concurrency; they are not
client-wide limits.

Keep `enable_idempotence: true` while tuning. Disabling it allows duplicate writes
on retries and, with multiple requests in flight, can reorder records within a
partition. Different producers do not share an ordering guarantee. During leader
handoff, overlapping calls can also overtake each other; sequential synchronous
calls retain their order. See `Klife.Producer` for the full ordering rules.

Use a stable record key when records for the same entity must go to the same
partition. The default partitioner hashes non-nil keys with Murmur2 and randomly
assigns records with no key. Increasing the topic's partition count can change
the partition selected for a key. More client batchers cannot parallelize one hot
partition, and more consumer members cannot split ownership of that partition.

## Isolating workloads

Suppose payment events and a bulk export share a client. Separate producers keep
the export's batching and retry slots from holding up payments. Separate named
connections keep a slow broker request on the export's TCP connection from
holding up payment requests.

```elixir
config :my_app, MyApp.Client,
  connection: [
    bootstrap_servers: ["localhost:19092"],
    custom_connections: [
      [name: :payments, socket_opts: [nodelay: true]]
    ]
  ],
  producers: [
    [name: :payments_producer, connection: :payments]
  ],
  topics: [
    [name: "payments", default_producer: :payments_producer]
  ]
```

Other topics continue to use the default producer and connection. The dedicated
producer reduces batching opportunities across workloads, and the connection adds
one TCP connection to every broker. Both workloads still share application CPU,
network capacity and broker resources.

The same distinction applies to fetchers. An exclusive fetcher gives a group or
topic its own batching pipeline. It still uses the default fetch connection unless
you set its `connection` option.

### Connections and parallelism

A broker processes requests in order on each TCP connection. A long-poll fetch or
a produce waiting for replicas can therefore delay later requests on that socket.
Klife's three default connections separate production, record fetching and
coordination for this reason.

`connection_count` adds TCP connections within a named connection. Sending
processes are mapped to sockets by a hash of their PID, so a process keeps using
the same socket. Raising the count may spread several busy dispatchers across
sockets, but it does not guarantee isolation between workloads or add batchers.
Use different names when traffic must have separate request queues.

Steady-state broker socket count per client is approximately
`broker_count * sum(connection_count for each distinct connection name)`, plus
the bootstrap connection. Count this across application nodes and clients. SASL
connection replacement temporarily adds sockets while old connections drain.

To reduce sockets, you can point multiple `default_*connection` options at the
same name. That also makes their requests wait on each other again. See the
[connection examples](examples/client_configuration.md#connections) for sharing,
inheritance and custom credentials.

## Fetching and long polling

Use a consumer group for continuous processing with managed assignments and
committed offsets. Use `fetch/4`, `fetch/2` or `fetch_async/4` for explicit
topic/partition/offset reads when the application manages progress itself.
Choose a configured fetcher for direct reads with the `fetcher:` call option.

Two settings control idle polling at different layers.

| Setting                                              | Effect                                                        |
| ---------------------------------------------------- | ------------------------------------------------------------- |
| Fetcher `max_wait_ms` (default `0`)                  | How long the broker may hold a fetch while waiting for data   |
| Consumer topic `fetch_interval_ms` (default `1_000`) | Backoff after empty responses, increasing up to this interval |

Lowering `fetch_interval_ms` reduces the delay before noticing new records on
quiet partitions, at the cost of more requests when they remain empty. It does
not pace normal consumption while records are available. Positive `max_wait_ms`
can reduce empty responses, but held requests occupy their TCP connection.

For a long-polling group, give its fetcher a connection of its own if other
fetchers need prompt responses. First declare it in the client configuration.

```elixir
config :my_app, MyApp.Client,
  connection: [
    bootstrap_servers: ["localhost:19092"],
    custom_connections: [[name: :audit_fetch]]
  ]
```

```elixir
defmodule MyApp.AuditConsumer do
  use Klife.Consumer.ConsumerGroup,
    client: MyApp.Client,
    group_name: "audit",
    fetch_strategy:
      {:exclusive, [connection: :audit_fetch, max_wait_ms: 1_000]},
    topics: [[name: "audit", offset_reset_policy: :earliest]]

  @impl true
  def handle_record_batch(_topic, _partition, _group_name, records) do
    Enum.each(records, &IO.inspect(&1.value))
    :commit
  end
end
```

Start `MyApp.AuditConsumer` after the client. Keep the fetcher's
`request_timeout_ms` above `max_wait_ms`, allowing for network and broker delays.
Long polls still queue behind one another on their own connection.

The group's `connection:` option controls heartbeats, offset operations and
coordinator requests. It does not choose the connection used to fetch records.
That belongs to the fetcher selected by `fetch_strategy`.

An exclusive strategy at group level creates one fetcher shared by its topics.
At topic level it creates one for that topic. Putting an exclusive strategy in
`default_topic_config` therefore creates a separate fetcher for each topic, rather
than one for the group. Use `{:shared, :fetcher_name}` to reuse a fetcher declared
in the client's `fetchers` list.

Both consumer groups and direct fetch calls default to `:read_committed`.
For groups, Klife filters control records and aborted transactional records before
invoking the handler. Direct fetch users should apply `Klife.Record.filter_records/2`
as described in `Klife.Consumer.Fetcher`. An open transaction can delay visibility
even of later non-transactional records in the same partition. See Kafka's
[isolation level reference](https://kafka.apache.org/41/configuration/consumer-configs/#isolation.level).
Use `:read_uncommitted` only if processing records that may later be aborted is
acceptable.

## Consumer throughput

Each assigned partition has its own consumer process. A slow handler for one
partition cannot be made parallel by increasing fetch batchers or committers.
First determine whether time goes to application processing, fetching, or waiting
for commit acknowledgements.

With the default `handler_max_unacked_commits: 0`, each handler batch waits for
commit confirmation before the next batch is delivered. Dynamic batches amortize
that roundtrip across the fetched records. Setting `handler_max_batch_size: 1`
without changing commit pacing can turn this into a commit roundtrip per record.

When an integration needs fixed-size handler batches, allow processing to
continue while earlier commits are in flight. For example, these startup options
can override the topic defaults of the group defined above.

```elixir
children = [
  MyApp.Client,
  {MyApp.AuditConsumer,
   default_topic_config: [
     handler_max_batch_size: 100,
     handler_max_unacked_commits: 1_000
   ]}
]
```

`handler_max_unacked_commits` is a per-partition pacing threshold. It does not make
handler calls concurrent within that partition, and processing happens in batches,
so treat it as a threshold rather than an exact record count. Increasing it lets
more processed work await acknowledgement, increasing possible reprocessing after
a crash or lost assignment. Handlers must tolerate duplicates under either policy.

Increase `committers_count` only when profiling shows the committer process
cannot keep up across many partitions. It will not fix slow callbacks or commit
roundtrip pacing, and splitting partitions across committers reduces commit
batching efficiency.

For retries, return `:retry` for the failed record and all later records in the
batch, or route the failed record elsewhere and commit it. Klife rejects committing
a higher offset while retrying a lower one, since Kafka cannot persist that gap.
Use the callback's `handler_cooldown_ms` option for backoff on transient processing
errors. A nonzero topic-level cooldown also slows successful processing cycles.

These pacing settings apply to the default `mode: :auto`. In `mode: :manual`, an
external driver pulls and commits records; `handler_cooldown_ms` and
`handler_max_unacked_commits` are ignored. The driver owns backpressure.

## Consumer memory

Budget for the number of partitions a node may own after another member leaves,
not just its normal assignment. Every assigned partition buffers independently.

Use these settings in the group's `default_topic_config` or on individual topic
entries, with topic entries taking precedence.

| Setting                        | Tradeoff                                                                                |
| ------------------------------ | --------------------------------------------------------------------------------------- |
| Lower `fetch_max_bytes`        | Smaller per-partition fetch payloads, more requests to catch up                         |
| Lower `max_queue_size`         | Less prefetch, greater chance of waiting for data between batches                       |
| Fixed `handler_max_batch_size` | Predictable handler record counts, more handler calls and possibly more commit overhead |

Keep `fetch_max_bytes` below the fetcher's `max_bytes_per_request`. The former
controls one partition's requested payload; the latter controls the combined
request that may contain several partitions. Neither limits the whole group's
resident memory.

Dynamic handler batches buffer whole fetch results, with a default queue size of
five. Fixed-size batches split fetched records into chunks, with a default queue
size of twenty. Smaller handler batches alone do not shrink the fetched response
or the temporary memory needed to deserialize it.

For rough planning with dynamic batches, start with
`assigned_partitions * max_queue_size * fetch_max_bytes`, then allow for fetched
responses, decompression, record structs and handler work. This is a sizing estimate,
not a hard memory ceiling. Kafka may return an oversized first record batch to
allow progress, as documented in its
[fetch size reference](https://kafka.apache.org/41/configuration/consumer-configs/#fetch.max.bytes).

Start with shared fetchers for batching efficiency. Add exclusive fetchers or
raise their `batchers_count` when profiling shows fetch dispatch or deserialization
is the bottleneck. Each additional fetcher brings its own batchers and in-flight
allowance, so adding fetchers can increase concurrent response memory.

## Transactions

Use transactions when records across topics or partitions must become committed
together. They add coordination roundtrips and keep records invisible to
`read_committed` consumers until commit. Prefer fewer, meaningful batches over a
separate transaction for every record.

```elixir
config :my_app, MyApp.Client,
  connection: [bootstrap_servers: ["localhost:19092"]],
  default_txn_pool: :orders,
  txn_pools: [
    [name: :orders, pool_size: 4, txn_timeout_ms: 90_000]
  ]
```

`pool_size` limits simultaneous transactions. A larger pool starts more
transactional producers and permits more concurrent broker work. Size it for the
concurrency you need, considering transaction duration. Transactional producers
use idempotence, all-replica acknowledgements, zero linger and one batcher per
broker with one in-flight request. Tune the pool's supported options rather than
the ordinary `producers` list.

`txn_timeout_ms` is the broker's transaction lifetime budget. Keep application
work and produce retries within it, and ensure Kafka allows that timeout. It is
separate from the producer's request and delivery timeouts.

By default, transactional IDs are random. If you set `base_txn_id`, Klife appends
a worker index. Each concurrently running pool must have a distinct prefix across
nodes and clients, or their producers can fence each other. Stable prefixes can
identify a logical instance across restarts, but require managing instance
identity during deployments.

Inside `transaction/2`, use synchronous produce calls and check every result.
Returning `:ok` or `{:ok, value}` commits; other return values abort. A failed
produce result does not itself force an abort if your function ignores it and
returns success. `produce_batch_txn/2` checks the batch results for you.

Klife's producer transactions do not atomically commit consumer group offsets or
database changes. A consume-process-produce handler still needs a strategy for
reprocessing and external side effects. See the transaction API in `Klife.Client`.

## Deployment

### TLS and authentication

Put environment-dependent addresses and secrets in `config/runtime.exs`. For
example, a TLS connection with SCRAM authentication can use the following.

```elixir
import Config

config :my_app, MyApp.Client,
  connection: [
    bootstrap_servers:
      System.fetch_env!("KAFKA_BOOTSTRAP_SERVERS") |> String.split(",", trim: true),
    ssl: true,
    connect_opts: [
      verify: :verify_peer,
      cacertfile: System.fetch_env!("KAFKA_CA_FILE")
    ],
    sasl_opts: [
      mechanism: "SCRAM-SHA-512",
      mechanism_opts: [
        username: System.fetch_env!("KAFKA_USERNAME"),
        password: System.fetch_env!("KAFKA_PASSWORD")
      ]
    ]
  ]
```

Bootstrap servers discover the cluster; clients then connect to the addresses
brokers advertise. Those addresses must be reachable from every application node
and match your TLS setup. Adding reachable bootstrap servers cannot fix
unreachable advertised listeners.

Klife also supports PLAIN, SCRAM-SHA-256 and OAUTHBEARER. Use TLS with PLAIN since
it sends the password as supplied. OAUTHBEARER calls your `token_mfa` for every
authentication, so return a cached token and refresh it before 80% of its lifetime.
More connections mean more authentication calls.

SASL sessions with an expiration are replaced before they expire. Klife requires
a session lifetime of at least `2 * (default_request_timeout_ms + 5_000)`, which is
70 seconds with the default timeout. Raising that timeout also raises the minimum
accepted session lifetime. See the
[SASL examples](examples/client_configuration.md#sasl) for rotation details.

Custom connections can replace `sasl_opts` to use different credentials, for
example to separate quotas or ACLs. They inherit the client's TLS mode and merge
their socket options over the client's. Bootstrap discovery still uses the
client-level credentials.

### Large clusters and explicit topic lists

By default, Klife collects metadata for all topics visible to the client. On a
large cluster, restrict it to the topics the application uses.

```elixir
config :my_app, MyApp.Client,
  connection: [bootstrap_servers: ["localhost:19092"]],
  enable_unkown_topics: false,
  topics: [[name: "orders"], [name: "payments"]]
```

The option is currently spelled `enable_unkown_topics`. With it disabled, include
every topic used for production or consumption in the client's `topics` list,
even when it is also declared on a consumer group. This controls metadata scope;
it does not replace Kafka ACLs or create topics.

`metadata_check_interval_ms` defaults to 30 seconds unless configured through the
application environment. Klife also refreshes metadata in response to stale
metadata errors. Lowering the periodic interval increases background requests;
it is not the only mechanism for discovering leader changes.

### Group identity and restarts

Nodes with the same `group_name` cooperate and divide partitions. A different
group name maintains independent committed offsets and reads its own copy of the
stream. Set `instance_id` only when each concurrently running member can have a
unique, stable identity across restarts.

The default `offset_reset_policy: :latest` starts at the end when no committed
offset exists. Choose `:earliest` when a new group should process retained
history. Changing this setting does not rewind a group with valid committed
offsets; use a new group or explicitly reset its offsets for a replay.

Allow time for handlers and offset commits to complete during graceful shutdown
and revocation. `rebalance_timeout_ms` defaults to 30 seconds; it is the
coordinator's wait budget for revocation, not a per-handler execution timeout.
Long handlers and large batches can outlast a deployment's shutdown grace period.
Hard failures can redeliver processed records whose commits were not confirmed.

## Validate a configuration change

Measure the workload with realistic record sizes, partition counts, broker
latency and application concurrency. Compare throughput and tail latency alongside
CPU, memory, outstanding work, request rate and error counts. A faster producer
that builds an unbounded application backlog has not solved a capacity problem.

Change one layer at a time. Then check idle topics, catch-up, a slow or unavailable
broker, leader movement and shutdown as well as steady traffic. These cases expose
the costs of shared connections, retry budgets, buffering and commit pacing that
a throughput-only benchmark can miss.

### Release benchmark workloads

Klife's repository includes a release benchmark (`mix release_benchmark`, described
in `bench/README.md`) with one workload for each of these scenarios. Each workload
runs Klife's defaults and a tuned profile, and can compare two Klife versions.

| Scenario                                                      | Benchmark workload                                                                                      |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| [Latency-sensitive production](#latency-sensitive-production) | `latency_sensitive_records`                                                                             |
| [High-throughput production](#high-throughput-production)     | `heavy_sync_production`, `heavy_async_production` (its `pipelined` variant runs that section's example) |
| [Isolating workloads](#isolating-workloads)                   | `isolated_workloads`, with a shared, a dedicated producer and a dedicated connection variant            |
| [Fetching and long polling](#fetching-and-long-polling)       | `long_poll_interference`                                                                                |
| [Consumer throughput](#consumer-throughput)                   | `catchup_lag`                                                                                           |

The tuned profiles set `nodelay: true` in the client's `socket_opts`, which applies
to every connection, rather than only on the production connection as in
[Latency-sensitive production](#latency-sensitive-production). Run a workload on
hardware like yours before adopting its settings.
