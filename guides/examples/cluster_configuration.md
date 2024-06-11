# Cluster configuration

Here are some cluster configuration examples.

## Simplest configuration

```elixir
  config :my_app, MyApp.Cluster,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: false
    ],
    topics: [[name: "my_topic_0"]]
```

This cluster will connect to brokers using non ssl connection and produce messages only to topic `my_topic` using the default producer and default partitioner.

## SSL and custom socket opts

```elixir
  config :my_app, MyApp.Cluster,
    connection: [
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      ssl: true,
      connect_opts: [
        verify: :verify_peer,
        cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
      ],
      socket_opts: [delay_send: true]
    ],
    topics: [[name: "my_topic_0"]]
```

This cluster will connect to brokers using ssl connection, `connect_opts` and `socket_opts` are forwarded to erlang module `:ssl` in order to proper configure the socket. See the documentation for more details.

## TODO: DO MORE EXAMPLES