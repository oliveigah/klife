import Config

config :klife, metadata_check_interval_ms: 2_000

container? = System.get_env("SIM_CONTAINER") == "true"

plain_servers =
  if container?, do: ["kafka1:9092", "kafka2:9092"], else: ["localhost:19092", "localhost:29092"]

sasl_servers =
  if container?, do: ["kafka1:9095", "kafka2:9095"], else: ["localhost:19094", "localhost:29094"]

ca_file =
  if container?,
    do: "/tls/ca.crt",
    else: Path.expand("../../test/compose_files/ssl/ca.crt", __DIR__)

config :simulator, Simulator.NormalClient,
  connection: [
    bootstrap_servers: plain_servers,
    ssl: false,
    connection_count: 5
  ]

# One client per SASL mechanism, all on the brokers' SASL_SSL listener
sasl_connection = fn sasl_opts ->
  [
    bootstrap_servers: sasl_servers,
    ssl: true,
    sasl_opts: sasl_opts,
    connect_opts: [
      verify: :verify_peer,
      cacertfile: ca_file
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
