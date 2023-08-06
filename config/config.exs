import Config

config :klife,
  clusters: [
    [
      cluster_name: :my_cluster_1,
      connection: [
        bootstrap_servers: ["localhost:19093", "localhost:29093"],
        socket_opts: [
          ssl: true,
          ssl_opts: [
            verify: :verify_peer,
            cacertfile: Path.relative("test/compose_files/truststore/ca.crt")
          ]
        ]
      ],
      producers: [
        %{
          name: :my_custom_producer,
          client_id: "my_custom_client_id"
        }
      ],
      topics: [
        %{
          name: "topic_a",
          enable_produce: true,
          producer: :my_custom_producer
        },
        %{
          name: "topic_b",
          enable_produce: true
        },
        %{
          name: "topic_c",
          enable_produce: false
        }
      ]
    ]
    # [
    #   cluster_name: :my_cluster_2,
    #   connection: [
    #     bootstrap_servers: ["localhost:39092"],
    #     socket_opts: [ssl: false]
    #   ]
    # ]
  ]
