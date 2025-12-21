import Config

config :simulator, Simulator.NormalClient,
  connection: [
    bootstrap_servers: ["localhost:19092", "localhost:29092"],
    ssl: false
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
    ]
  ]
