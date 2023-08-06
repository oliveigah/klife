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
      ]
    ],
    [
      cluster_name: :my_cluster_2,
      connection: [
        bootstrap_servers: ["localhost:39092"],
        socket_opts: [ssl: false]
      ]
    ]
  ]
