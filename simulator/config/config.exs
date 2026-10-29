import Config

config :klife, metadata_check_interval_ms: 2_000

config :simulator, Simulator.NormalClient,
  connection: [
    bootstrap_servers: ["localhost:19092", "localhost:29092"],
    ssl: false,
    connection_count: 5
  ]

# One client per SASL mechanism, all on the brokers' SASL_SSL listener
sasl_connection = fn sasl_opts ->
  [
    bootstrap_servers: ["localhost:19094", "localhost:29094"],
    ssl: true,
    sasl_opts: sasl_opts,
    connect_opts: [
      verify: :verify_peer,
      cacertfile: Path.relative("../test/compose_files/ssl/ca.crt")
    ],
    connection_count: 5
  ]
end

credentials = [username: "klifeusr", password: "klifepwd"]

config :simulator, Simulator.TLSClient,
  connection: sasl_connection.(mechanism: "PLAIN", mechanism_opts: credentials)

config :simulator, Simulator.ScramSha256Client,
  connection: sasl_connection.(mechanism: "SCRAM-SHA-256", mechanism_opts: credentials)

config :simulator, Simulator.ScramSha512Client,
  connection: sasl_connection.(mechanism: "SCRAM-SHA-512", mechanism_opts: credentials)

config :simulator, Simulator.OAuthClient,
  connection:
    sasl_connection.(
      mechanism: "OAUTHBEARER",
      mechanism_opts: [token_mfa: {Simulator.OAuthClient, :token, []}]
    )
