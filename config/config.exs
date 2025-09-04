import Config

# TODO: Test without kafka

config :klife, MyClient,
  connection: [
    # SSL FALSE
    # bootstrap_servers: ["localhost:19092", "localhost:29092"],
    # SSL TRUE
    # bootstrap_servers: ["localhost:19093", "localhost:29093"],
    # SSL TRUE AND SASL
    bootstrap_servers: ["localhost:19094", "localhost:29094"],
    ssl: true,
    sasl_opts: [
      mechanism: "PLAIN",
      mechanism_opts: [
        username: "klifeusr",
        password: "klifepwd"
      ]
    ],
    connect_opts: [
      verify: :verify_peer,
      cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
    ]
    # socket_opts: [
    #   delay_send: true
    # ]
  ],
  # disabled_features: [:producer],
  txn_pools: [
    [name: :my_test_pool_1, pool_size: 1]
  ],
  producers: [
    [
      name: :benchmark_producer,
      client_id: "my_custom_client_id"
    ],
    [
      name: :async_benchmark_producer,
      client_id: "my_custom_client_id",
      batchers_count: 32
    ],
    [
      name: :benchmark_producer_in_flight,
      client_id: "my_custom_client_id",
      max_in_flight_requests: 10
    ],
    [
      name: :benchmark_producer_in_flight_linger,
      client_id: "my_custom_client_id",
      max_in_flight_requests: 10,
      linger_ms: 1
    ],
    [
      name: :test_batch_producer,
      client_id: "my_custom_client_id",
      linger_ms: 1_500
    ],
    [
      name: :test_batch_compressed_producer,
      client_id: "my_custom_client_id",
      linger_ms: 1_500,
      compression_type: :snappy
    ],
    [
      name: :async_test_producer,
      batch_size_bytes: 5000
    ]
  ],
  topics: [
    [
      name: "benchmark_topic_0",
      default_producer: :benchmark_producer
    ],
    [
      name: "benchmark_topic_1",
      default_producer: :benchmark_producer
    ],
    [
      name: "benchmark_topic_2",
      default_producer: :benchmark_producer
    ],
    [
      name: "async_benchmark_topic_klife_0",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_klife_1",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_klife_2",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_erlkaf_0",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_erlkaf_1",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_erlkaf_2",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_brod_0",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_brod_1",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "async_benchmark_topic_brod_2",
      default_producer: :async_benchmark_producer
    ],
    [
      name: "benchmark_topic_in_flight",
      default_producer: :benchmark_producer_in_flight
    ],
    [
      name: "benchmark_topic_in_flight_linger",
      default_producer: :benchmark_producer_in_flight_linger
    ],
    [
      name: "test_batch_topic",
      default_producer: :test_batch_producer
    ],
    [
      name: "test_compression_topic",
      default_producer: :test_batch_compressed_producer
    ],
    [
      name: "test_no_batch_topic"
    ],
    [
      name: "test_no_batch_topic_2",
      default_partitioner: Klife.TestCustomPartitioner
    ],
    [
      name: "test_async_topic"
    ],
    [name: "my_topic_1"],
    [name: "my_topic_2"],
    [name: "my_topic_3"],
    [
      name: "test_async_topic_0",
      default_producer: :async_test_producer
    ],
    [
      name: "test_async_topic_1",
      default_producer: :async_test_producer
    ],
    [
      name: "test_async_topic_2",
      default_producer: :async_test_producer
    ],
    [
      name: "my_move_to_topic"
    ]
  ]

# consumers: [
#   [
#     group_name: "klife_consumer_group_1",
#     group_type: :consumer,
#     topics: [
#       {"my_topic", MyHandler}
#     ]
#   ],
#   [
#     group_name: "klife_share_group_1",
#     group_type: :share,
#     topics: [
#       {"my_topic", MyHandler},
#       {CustomTopicMatch, MyOtherHandler}
#     ]
#   ],
#   [
#     group_name: "klife_classic_group_1",
#     group_type: :classic,
#     topics: [
#       {"my_topic", MyHandler},
#       {CustomTopicMatch, MyOtherHandler}
#     ]
#   ],
#   [
#     group_name: "klife_classic_group_1",
#     group_type: :classic,
#     topics: [
#       {"my_topic", MyHandler},
#       {CustomTopicMatch, MyOtherHandler}
#     ]
#   ]
# ]

if config_env() == :dev do
  import_config "#{config_env()}.exs"
end
