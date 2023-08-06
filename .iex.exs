import Klife.ProcessRegistry

alias Klife.Utils

:klife
|> Application.fetch_env!(:clusters)
|> Enum.map(fn cluster_opts ->
  Utils.wait_connection!(cluster_opts[:cluster_name])
  Utils.create_topics!(cluster_opts[:topics] || [], cluster_opts[:cluster_name])
end)
