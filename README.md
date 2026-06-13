[![ci](https://github.com/oliveigah/klife/actions/workflows/ci.yml/badge.svg)](https://github.com/oliveigah/klife/actions/workflows/ci.yml)
[![hex.pm badge](https://img.shields.io/badge/Package%20on%20hex.pm-informational)](https://hex.pm/packages/klife)
[![Documentation badge](https://img.shields.io/badge/Documentation-ff69b4)](https://hexdocs.pm/klife)

# Klife

Klife is a modern, ergonomic and high-performance Kafka client built from the ground up with minimal dependencies.

- **Modern**: Built for today's Kafka. It supports Kafka >= 4.0 and implements the [next generation of the consumer rebalance protocol (KIP-848)](https://cwiki.apache.org/confluence/display/KAFKA/KIP-848%3A+The+Next+Generation+of+the+Consumer+Rebalance+Protocol), providing a simpler and more efficient consumer group experience.

- **Ergonomic**: Designed to feel natural in Elixir projects (e.g. Ecto-like transactions, `Klife.Record` struct, testing utilities, consumer callbacks, etc.) and also provides capabilities to better handle Kafka workflows like automatic retry counting and batch size limits.

- **High Performance**: Batching architecture that delivers exceptional throughput. Most requests destined for the same broker are batched into a single TCP request, maximizing network efficiency. In [benchmarks](benchmarks.md) against other community Kafka clients, this approach has shown massive throughput improvements while minimizing the Kafka cluster resource usage.

## Key Features

- **Consumer Group**: The new [KIP-848 rebalance protocol](https://cwiki.apache.org/confluence/display/KAFKA/KIP-848%3A+The+Next+Generation+of+the+Consumer+Rebalance+Protocol) introduced in Kafka 4.0.
- **Custom Consumer Configuration**: Per-topic consumer settings within the same group.
- **Static Membership**: Stable consumer identity via `instance_id`.
- **Backpressure**: Fetch rate naturally regulated by processing speed, with multiple configurable controls.
- **Graceful Shutdown**: In-flight records are processed and offsets committed before leaving the group.
- **Direct Fetch**: Fetch a specific topic/partition/offset combinations without consumer coordination.
- **Batch Produce API**: Produce to multiple topics/partitions in a single call, with sync and async modes.
- **Custom Partitioner per Topic**: Configurable partitioning strategy for each topic.
- **Transactional Support**: Ecto-like transaction API for producing records.
- **Testing Utilities**: Helpers for testing against a real broker without mocking.
- **SASL Authentication**: Plain authentication support.

## Installation and Base setup

### 0. Add `klife` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:klife, "~> 1.1"}
  ]
end
```

### 1. Define your application client

```elixir
defmodule MyApp.Client do
  use Klife.Client, otp_app: :my_app
end
```

### 2. Add basic configuration

```elixir
config :my_app, MyApp.Client,
  connection: [
    bootstrap_servers: ["localhost:19092", "localhost:29092"],
    ssl: false
  ]
```

Check out the `Klife.Client` [docs](https://hexdocs.pm/klife/Klife.Client.html) for more details regarding configurations!

### 3. Add the client to the supervision tree

```elixir
children = [ MyApp.Client ]

opts = [strategy: :one_for_one, name: Example.Supervisor]
Supervisor.start_link(children, opts)
```

## Produce records

Assuming a proper setup as described above, now you just need to call your client produce API!

```elixir
my_rec = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
{:ok, %Klife.Record{}} = MyApp.Client.produce(my_rec)

# Batch produce across multiple topics and partitions in a single call
my_recs = [
  %Klife.Record{value: "val_1", topic: "my_topic_1"},
  %Klife.Record{value: "val_2", topic: "my_topic_2"}
]
[{:ok, %Klife.Record{}}, {:ok, %Klife.Record{}}] = MyApp.Client.produce_batch(my_recs)
```

Check out the `Klife.Client` [docs](https://hexdocs.pm/klife/Klife.Client.html) for more details regarding the produce API and the `Klife.Producer` [docs](https://hexdocs.pm/klife/Klife.Producer.html) for configuration options!

## Consumer Group

Assuming a proper setup as described above, now you just need to define a Consumer Group module:

```elixir
defmodule MyApp.MyConsumerGroup do
  use Klife.Consumer.ConsumerGroup,
    client: MyApp.Client,
    group_name: "my_group_name",
    topics: [
      [name: "my_topic_1"],
      [name: "my_topic_2"]
    ]

  @impl true
  def handle_record_batch(topic, partition, cg_name, record_list) do
    Enum.map(record_list, fn %Klife.Record{} = rec ->
      IO.inspect("Consuming record with offset #{rec.offset} and value #{rec.value}!")
      {:commit, rec}
    end)
  end
end
```

and then start it under your supervision tree!

```elixir
children = [ MyApp.MyConsumerGroup ]

opts = [strategy: :one_for_one, name: Example.Supervisor]
Supervisor.start_link(children, opts)
```

Check out the `Klife.Consumer.ConsumerGroup` [docs](https://hexdocs.pm/klife/Klife.Consumer.ConsumerGroup.html) for more details regarding the consumer group behaviour and configuration options!

## Reliability

Klife has been validated through thousands of randomized simulation runs using a dedicated chaos testing framework. Each simulation generates a unique scenario from a vast configuration space randomizing all possible configurations.

During each run, the simulator continuously injects failures:

- **Broker crashes**: Kafka brokers are killed and restarted after random delays
- **Consumer group kills**: Groups are forcefully terminated and gracefully stopped
- **Partition expansion**: Partitions are dynamically added to topics mid-simulation
- **Application-level faults**: Random exceptions and batch processing failures in consumer callbacks

Throughout all of this, the framework asserts three core invariants that must never be violated:

1. **No duplicate consumption**: Every record is delivered exactly once per consumer group (only possible to ensure on runs without injected failures)
2. **Ordered delivery**: Offsets within a partition are always consumed in order
3. **No data loss**: Every produced record is eventually consumed by all subscribed groups

The full simulator source code is available in the `simulator` directory.

## Upgrade from 0.x to 1.x

- **Default partitioner**: The default partitioner changed from `phash2` to `murmur2` to improve compatibility with Kafka standards. To avoid the change, you can define a custom partitioner that uses the old `phash2` behavior.
- **Default timeout**: Changed from 15s to 30s and can now be configured via the `default_request_timeout_ms` option in the connection configuration.
- **Record struct default headers**: Now defaults to `[]` instead of `nil`. Pattern matches on the `headers` field may need to be updated accordingly.

## Kafka versions support

The focus of Klife is to support the most recent versions of Kafka (i.e. >= 4.0); all development and testing was performed almost exclusively on these versions.

That said, it is possible to use some features of Klife on older versions. The consumer group feature will not work on older brokers, but for produce-only workflows Klife may still work fine (Kafka versions >= 2.4).

During startup, Klife will emit warning logs for any features that were disabled due to lack of compatibility with the broker. The logs follow the format: `[Name of the feature] feature disabled due...`.

If you attempt to use a disabled feature at runtime, Klife will raise with a descriptive error message.
