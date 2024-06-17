import Config

config :example, Example.MySimplestClient,
  connection: [
    bootstrap_servers: ["localhost:19092", "localhost:29092"],
    ssl: false
  ],
  topics: [[name: "my_topic"]]
