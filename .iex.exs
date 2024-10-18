{:ok, _} = Klife.Utils.create_topics()

opts = [strategy: :one_for_one, name: Test.Supervisor]
{:ok, _} = Supervisor.start_link([MyClient], opts)
