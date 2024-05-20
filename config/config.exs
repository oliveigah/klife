import Config

config :klife,
  clusters: [
    [
      cluster_name: :my_test_cluster_1,
      connection: [
        bootstrap_servers: ["localhost:19092", "localhost:29092"],
        socket_opts: [
          ssl: false
          # ssl_opts: [
          #   verify: :verify_peer,
          #   cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
          # ]
        ]
      ],
      producers: [
        %{
          name: :my_batch_producer,
          client_id: "my_custom_client_id",
          linger_ms: 1_500
        },
        %{
          name: :benchmark_producer_in_flight,
          client_id: "my_custom_client_id",
          max_in_flight_requests: 10
        },
        %{
          name: :my_batch_compressed_producer,
          client_id: "my_custom_client_id",
          linger_ms: 1_500,
          compression_type: :snappy
        },
        %{
          name: :benchmark_producer,
          client_id: "my_custom_client_id"
        },
        %{
          name: :batcher_benchmark_producer_1,
          client_id: "my_custom_client_id",
          batchers_count: 1
        },
        %{
          name: :batcher_benchmark_producer_2,
          client_id: "my_custom_client_id",
          batchers_count: 2
        },
        %{
          name: :batcher_benchmark_producer_3,
          client_id: "my_custom_client_id",
          batchers_count: 3
        }
      ],
      topics: [
        %{
          name: "benchmark_topic",
          producer: :benchmark_producer,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "benchmark_topic_in_flight",
          producer: :benchmark_producer_in_flight,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "comression_topic",
          producer: :my_batch_compressed_producer
        },
        %{
          name: "batcher_benchmark_topic_1",
          producer: :batcher_benchmark_producer_1,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "batcher_benchmark_topic_2",
          producer: :batcher_benchmark_producer_2,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "batcher_benchmark_topic_3",
          producer: :batcher_benchmark_producer_3,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "benchmark_topic_2",
          producer: :benchmark_producer,
          num_partitions: 6,
          replication_factor: 2
        },
        %{
          name: "my_batch_topic",
          enable_produce: true,
          producer: :my_batch_producer
        },
        %{
          name: "topic_b",
          enable_produce: true
        },
        %{
          name: "topic_c",
          enable_produce: true,
          producer: :my_batch_producer
        },
        %{
          name: "my_no_batch_topic",
          enable_produce: true
        }
      ]
    ]
  ]

if config_env() == :dev do
  import_config "#{config_env()}.exs"
end
