import Config

config :klife,
  default_cluster: :my_test_cluster_1,
  clusters: [
    [
      cluster_name: :my_test_cluster_1,
      txn_pools: [
        %{name: :my_test_pool_1, pool_size: 1}
      ],
      connection: [
        bootstrap_servers: ["localhost:19092", "localhost:29092"],
        # bootstrap_servers: ["localhost:19093", "localhost:29093"],
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
          name: :benchmark_producer,
          client_id: "my_custom_client_id"
        },
        %{
          name: :benchmark_producer_in_flight,
          client_id: "my_custom_client_id",
          max_in_flight_requests: 10
        },
        %{
          name: :benchmark_producer_in_flight_linger,
          client_id: "my_custom_client_id",
          max_in_flight_requests: 10,
          linger_ms: 1
        },
        %{
          name: :test_batch_producer,
          client_id: "my_custom_client_id",
          linger_ms: 1_500
        },
        %{
          name: :test_batch_compressed_producer,
          client_id: "my_custom_client_id",
          linger_ms: 1_500,
          compression_type: :snappy
        }
      ],
      topics: [
        %{
          name: "benchmark_topic_0",
          producer: :benchmark_producer,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "benchmark_topic_1",
          producer: :benchmark_producer,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "benchmark_topic_2",
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
          name: "benchmark_topic_in_flight_linger",
          producer: :benchmark_producer_in_flight_linger,
          num_partitions: 30,
          replication_factor: 2
        },
        %{
          name: "test_batch_topic",
          enable_produce: true,
          producer: :test_batch_producer
        },
        %{
          name: "test_compression_topic",
          producer: :test_batch_compressed_producer
        },
        %{
          name: "test_no_batch_topic",
          enable_produce: true
        },
        %{
          name: "test_no_batch_topic_2",
          enable_produce: true,
          partitioner: Klife.TestCustomPartitioner
        },
        %{
          name: "test_async_topic",
          enable_produce: true
        }
      ]
    ]
  ]

if config_env() == :dev do
  import_config "#{config_env()}.exs"
end
