# Client configuration

Here are some client configuration examples.

For help choosing settings for a workload, see the
[configuration guide](../configuration.md). It covers latency, throughput,
isolation, consumer buffering, transactions and deployment tradeoffs.

## Simplest configuration

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ]
```

This client will connect to brokers using non ssl connection and produce messages using the default producer and default partitioner.

## SSL with SASL and custom socket opts

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: true,
      connect_opts: [
        verify: :verify_peer,
        cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
      ],
      socket_opts: [delay_send: true],
      sasl_opts: [
        mechanism: "PLAIN",
        mechanism_opts: [
          username: "klifeusr",
          password: "klifepwd"
        ]
      ],
    ]
```

This client will connect to brokers using ssl connection, `connect_opts` and `socket_opts` are forwarded to erlang module `:ssl` in order to proper configure the socket. See the documentation for more details.

## SASL

When `sasl_opts` is set, every broker connection authenticates with the given `mechanism`. The supported mechanisms are:

- `"PLAIN"`: sends the password as is, so use it only with `ssl: true`
- `"SCRAM-SHA-256"` and `"SCRAM-SHA-512"`: the password never leaves the client
- `"OAUTHBEARER"`: sends a token you provide

`PLAIN` and `SCRAM` take `username` and `password` as `mechanism_opts`:

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19094", "localhost:29094"],
      ssl: true,
      sasl_opts: [
        mechanism: "SCRAM-SHA-512",
        mechanism_opts: [
          username: "klifeusr",
          password: "klifepwd"
        ]
      ]
    ]
```

`OAUTHBEARER` takes a `token_mfa`, applied on every authentication to get the token (a binary), and optional `extensions` (a map):

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19094", "localhost:29094"],
      ssl: true,
      sasl_opts: [
        mechanism: "OAUTHBEARER",
        mechanism_opts: [
          token_mfa: {MyApp.TokenCache, :get_token, []}
        ]
      ]
    ]
```

Fetching, caching and refreshing the token is up to you. Since every connection authenticates on its own, `token_mfa` should return a cached token, and refresh it before 80% of its lifetime: a session never outlives its token.

> #### Session expiration {: .info}
>
> Brokers may end sessions: after `connections.max.reauth.ms` if set, and when the token expires for `OAUTHBEARER`.
> Shortly before that (between 85% and 95% of the session), Klife replaces each connection with a newly
> authenticated one. The old one keeps receiving replies to requests already sent for
> `default_request_timeout_ms` + 5 seconds, then it is closed. That drain always fits in what is left of
> the old session, so short sessions are replaced earlier, and sessions shorter than two drains
> (70 seconds with the default request timeout) are refused.

## Connections

A Kafka broker reads the requests of a TCP connection one at a time and answers them in order. So a request the broker holds delays every request sent after it on the same TCP connection:

- a fetch with `max_wait_ms` above 0, when there are no new records: up to `max_wait_ms`
- a produce with `acks: :all`: until the replicas have the records, up to the producer's `request_timeout_ms`

To keep such requests from delaying more urgent ones, Klife sends different kinds of requests over different connections. A connection is a named group of TCP connections, `connection_count` of them to each broker. Every client has three default connections, named by these connection options:

| Option | Default name | Used by |
| --- | --- | --- |
| `default_connection` | `:klife_default_connection` | producers and txn pools |
| `default_fetch_connection` | `:klife_fetch_connection` | fetchers |
| `default_critical_connection` | `:klife_critical_connection` | consumer groups (heartbeats, offset commits and fetches, coordinator lookups, offset resets) and metadata refreshes |

So by default a client keeps `3 * connection_count` TCP connections to each broker, plus one to a bootstrap server to discover the cluster.

### Custom connections

You can declare more connections, for example to keep a latency-sensitive producer, a consumer group or a long-polling fetcher away from the others:

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      custom_connections: [
        # One producer's requests, sent without waiting to fill TCP packets
        [name: :payments, socket_opts: [nodelay: true]],
        # One consumer group's heartbeats and commits
        [name: :payments_group],
        # Long polls, away from the other fetchers
        [name: :long_poll],
        # Using the name of a default connection configures it
        [name: :klife_fetch_connection, connection_count: 4]
      ]
    ],
    producers: [
      [name: :payments_producer, connection: :payments]
    ],
    fetchers: [
      [name: :tail_fetcher, connection: :long_poll, max_wait_ms: 5_000]
    ],
    topics: [
      [name: "payments", default_producer: :payments_producer]
    ]
```

A custom connection takes the client's connection options, except for the ones it sets:

- `connection_count` replaces the client's
- `connect_opts` and `socket_opts` are merged over the client's
- `sasl_opts` replaces the client's, so the connection can authenticate as another user, for instance one with its own quotas or ACLs

`ssl`, `bootstrap_servers` and `default_request_timeout_ms` are always the client's.

### Replacing the default connections

A default connection is only created when no custom connection has its name. So pointing a `default_*connection` option to a custom connection replaces it, and pointing several to the same name makes them share one connection:

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      # Fetchers share the default connection
      default_fetch_connection: :klife_default_connection,
      # Consumer groups and metadata refreshes use :control
      default_critical_connection: :control,
      custom_connections: [[name: :control, socket_opts: [nodelay: true]]]
    ]
```

This client keeps `2 * connection_count` TCP connections to each broker: `:klife_default_connection` and `:control`. Pointing all three options to the same name gives a single connection, as in Klife 1.2, with its requests waiting for each other again.

### Choosing a connection

Each component that sends requests has a `:connection` option, which defaults to the connection its `default_*connection` option names. The requests from many produce or fetch calls are batched together, so the connection belongs to the producer or fetcher, not to each call.

- **Producers and txn pools:** `connection:` in their configuration. It covers every request they send, transaction requests included.
- **Fetchers:** `connection:` in their configuration. A consumer group's exclusive fetchers take it too: `fetch_strategy: {:exclusive, [connection: :long_poll]}`. To change the default fetcher's connection, declare a fetcher with its name (`:klife_default_fetcher`) or set `default_fetcher`.
- **Consumer groups:** `connection:` on the group. It covers the requests the group itself sends. Records are fetched by the fetcher picked through `fetch_strategy`, over that fetcher's connection.

```elixir
defmodule MyApp.Payments do
  use Klife.Consumer.ConsumerGroup,
    client: MyApp.Client,
    group_name: "payments",
    # Heartbeats and commits, over :klife_critical_connection when not set
    connection: :payments_group,
    # Records come through :tail_fetcher, over :long_poll
    fetch_strategy: {:shared, :tail_fetcher},
    topics: [[name: "payments"]]
end
```

A component raises when it starts with a connection the client doesn't have.

> #### Tradeoffs {: .warning}
>
> - Each connection costs `connection_count` TCP connections to each broker. They are opened when the
>   client starts, even if nothing uses them, and each authenticates on its own.
> - Requests on the same connection still wait for each other. A fetcher with `max_wait_ms` above 0
>   delays the other fetchers on its connection, and its own requests too: they all share the
>   connection's TCP connections. Give long-polling fetchers a connection of their own.
> - Each process sending requests sticks to one TCP connection of a connection, chosen from its pid.
>   A larger `connection_count` spreads the requests of many processes, not those of one.

## Defining and using multiple producers

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ],
    producers: [
      [
        name: :my_linger_ms_producer,
        linger_ms: 1_000
      ],
      [
        name: :my_custom_client_id_producer,
        client_id: "my_custom_client_id",
      ]
    ],
    topics: [
      [
        name: "my_topic_0",
        default_producer: :my_linger_ms_producer
      ],
      [
        name: "my_topic_1",
        default_producer: :my_custom_client_id_producer
      ]
    ]
```

This client will have a total of 3 producers, the default one plus the other 2 defined in the configuration. You can see all the configuration options for the producers in `Klife.Producer`.

Messages produced to `my_topic_0` and `my_topic_1` will use `my_linger_ms_producer` and `my_custom_client_id_producer` respectively if no producer is set on opts. All other topics keep using the default producer.

## Defining and using custom partitioner

First you need to implement a module following the `Klife.Behaviours.Partitioner` behaviour.

```elixir
defmodule MyApp.MyCustomPartitioner do
  @behaviour Klife.Behaviours.Partitioner

  alias Klife.Record

  @impl true
  def get_partition(%Record{} = record, max_partition) do
    # Some logic to find the partition here!
  end
end

```

Then, you need to use it on your configuration.

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ],
    topics: [
      [
        name: "my_topic_0",
        default_partitioner: MyApp.MyCustomPartitioner
      ]
    ]
```

On this client, the records produced to `my_topic_0` without a specific partition will have a partition assigned using the `MyApp.MyCustomPartitioner` module all other topics keep using the default partitioner.

## Defining multiple transactional (txn) pools

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ],
    default_txn_pool: :my_txn_pool,
    txn_pools: [
      [name: :my_txn_pool, base_txn_id: "my_custom_base_txn_id"],
      [name: :my_txn_pool_2, txn_timeout_ms: :timer.seconds(120)]
    ],
    topics: [[name: "my_topic_0"]]
```

This client will have two txn pools. `:my_txn_pool` is the selected default, so Klife does not add another pool. You can see all the configuration options for the pools in `Klife.TxnProducerPool`.

## Using custom default producer, partitioner and txn pool

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ],
    default_producer: :my_custom_producer,
    producers: [[name: :my_custom_producer, linger_ms: 1_000]],
    default_partitioner: MyCustomPartitioner,
    default_txn_pool: :my_txn_pool,
    txn_pools: [[name: :my_txn_pool, base_txn_id: "my_custom_base_txn_id"]],
    topics: [[name: "my_topic_0"]]
```

This cliente will have only one producer (`:my_custom_producer`) and txn pool (`:my_txn_pool`),and the default paritioner strategy will be `MyCustomPartitioner`. All this 3 configurations will be used in produce API calls to topics that does not have any override config defined in the `topics` configuration.
