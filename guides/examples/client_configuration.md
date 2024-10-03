# Client configuration

Here are some client configuration examples.

## Simplest configuration

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ]
```

This client will connect to brokers using non ssl connection and produce messages using the default producer and default partitioner.

## SSL and custom socket opts

```elixir
  config :my_app, MyApp.Client,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: true,
      connect_opts: [
        verify: :verify_peer,
        cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
      ],
      socket_opts: [delay_send: true]
    ]
```

This client will connect to brokers using ssl connection, `connect_opts` and `socket_opts` are forwarded to erlang module `:ssl` in order to proper configure the socket. See the documentation for more details.

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

## Defining multiple txn pools

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
    ]
    topics: [[name: "my_topic_0"]]
```

This client will have a total of 3 txn pools, the default one plus the other two defined in the configuration. You can see all the configuration options for the producers in `Klife.TxnProducerPool`.

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