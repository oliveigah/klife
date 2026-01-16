import Config

config :klife, metadata_check_interval_ms: 2_000

config :simulator, Simulator.NormalClient,
  connection: [
    bootstrap_servers: ["localhost:19092", "localhost:29092"],
    ssl: false,
    connection_count: 5
  ]

config :simulator, Simulator.TLSClient,
  connection: [
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
      cacertfile: Path.relative("../test/compose_files/ssl/ca.crt")
    ],
    connection_count: 5
  ]
