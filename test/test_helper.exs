# ExUnit.configure(exclude: [cluster_change: true])

{:ok, _topics} = Klife.Utils.create_topics()

opts = [strategy: :one_for_one, name: Test.Supervisor]
{:ok, _} = Supervisor.start_link([MyClient], opts)

:ok = Klife.Testing.setup(MyClient)

case System.fetch_env("KLIFE_KAFKA_VSN") do
  {:ok, _} -> :noop
  :error -> System.put_env("KLIFE_KAFKA_VSN", "4.0")
end

:ok = Klife.TestUtils.setup()

ExUnit.start()
