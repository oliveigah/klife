:klife
|> Application.fetch_env!(:clusters)
|> Enum.map(fn cluster_opts ->
  Klife.Utils.wait_connection!(cluster_opts[:cluster_name])
  Klife.Utils.create_topics!(cluster_opts[:topics] || [], cluster_opts[:cluster_name])
end)

ExUnit.start()
