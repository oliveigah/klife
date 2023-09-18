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
          #   cacertfile: Path.relative("test/compose_files/truststore/ca.crt")
          # ]
        ]
      ],
      producers: [
        %{
          name: :my_batch_producer,
          client_id: "my_custom_client_id",
          linger_ms: 100
        },
        %{
          name: :benchmark_producer,
          client_id: "my_custom_client_id",
          max_in_flight_requests: 1
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
          enable_produce: true
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
