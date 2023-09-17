import Config

# kafka_ex benchmark
config :kafka_ex,
  brokers: [
    {"localhost", 19092},
    {"localhost", 29092}
  ],
  kafka_version: "kayrock"

# Brod benchmark
config :brod,
  clients: [
    kafka_client: [
      endpoints: [localhost: 19092, localhost: 29092],
      auto_start_producers: true,
      default_producer_config: [
        required_acks: -1,
        partition_onwire_limit: 1,
        max_linger_ms: 0,
        max_batch_size: 512_000
      ]
    ]
  ]
