{:ok, _} = Klife.Utils.create_topics()

opts = [strategy: :one_for_one, name: Test.Supervisor]

{:ok, _} =
  Supervisor.start_link(
    [
      MyClient,
      {MyConsumerGroup,
       [
         topics: [
           [name: "my_consumer_topic"],
           [name: "my_consumer_topic_2"]
         ],
         group_name: "consumer_group_example_1"
       ]}
    ],
    opts
  )
