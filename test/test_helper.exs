# ExUnit.configure(exclude: [cluster_change: true])

:ok = Klife.Utils.create_topics()

opts = [strategy: :one_for_one, name: Test.Supervisor]
{:ok, _} = Supervisor.start_link([MyTestClient], opts)

ExUnit.start()
