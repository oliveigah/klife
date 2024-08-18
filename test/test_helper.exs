# ExUnit.configure(exclude: [cluster_change: true])

{:ok, topics} = Klife.Utils.create_topics()

opts = [strategy: :one_for_one, name: Test.Supervisor]
{:ok, _} = Supervisor.start_link([MyClient], opts)

:ok = Klife.TestUtils.wait_producer(MyClient)

# Enum.each(topics, fn topic ->
#   warmup_rec = %Klife.Record{
#     value: "warmup",
#     partition: 1,
#     topic: topic
#   }

#   {:ok, %Klife.Record{}} = MyClient.produce(warmup_rec)
# end)

# Process.sleep(10_000)

ExUnit.start()
