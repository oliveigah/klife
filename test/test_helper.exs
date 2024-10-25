# ExUnit.configure(exclude: [cluster_change: true])

{:ok, _topics} = Klife.Utils.create_topics()

opts = [strategy: :one_for_one, name: Test.Supervisor]
{:ok, _} = Supervisor.start_link([MyClient], opts)

:ok = Klife.Testing.setup(MyClient)

ExUnit.start()
