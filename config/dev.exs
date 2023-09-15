import Config

# KAFKA EX BENCHMARK
config :kafka_ex,
  brokers: [
    {"localhost", 19092},
    {"localhost", 29092}
  ]

config :erlkaf,
  config: [
    {:bootstrap_servers, "localhost:19092,localhost:29092"},
    {:queue_buffering_overflow_strategy, :block_calling_process}
  ]
