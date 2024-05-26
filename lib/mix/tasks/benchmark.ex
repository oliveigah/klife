if Mix.env() in [:dev] do
  defmodule Mix.Tasks.Benchmark do
    use Mix.Task

    def run(args) do
      Application.ensure_all_started(:klife)
      Process.sleep(1_000)
      apply(Mix.Tasks.Benchmark, :do_run_bench, args)
    end

    def do_run_bench("test", parallel) do
      :ets.new(:benchmark_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

      :ets.new(:benchmark_table_2, [
        :set,
        :public,
        :named_table
      ])

      Enum.each(1..1000, fn i ->
        :ets.insert(:benchmark_table, {{:test, i}, i * 2})
        :ets.insert(:benchmark_table_2, {{:test, i}, i * 2})
        :persistent_term.put({:test, i}, i * 2)
      end)

      Benchee.run(
        %{
          "ets read_concurrency" => fn ->
            Enum.each(1..1000, fn i -> :ets.lookup_element(:benchmark_table, {:test, i}, 2) end)
          end,
          "ets no read_concurrency" => fn ->
            Enum.each(1..1000, fn i -> :ets.lookup_element(:benchmark_table_2, {:test, i}, 2) end)
          end,
          "persistent_term" => fn ->
            Enum.each(1..1000, fn i -> :persistent_term.get({:test, i}) end)
          end
        },
        time: 10,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end

    def do_run_bench("producer_sync", parallel) do
      topic = "benchmark_topic"

      max_partition =
        :klife
        |> Application.fetch_env!(:clusters)
        |> List.first()
        |> Keyword.get(:topics)
        |> Enum.find(&(&1.name == topic))
        |> Map.get(:num_partitions)

      val = :rand.bytes(4000)
      key = "some_key"

      record = %{
        value: val,
        key: key
      }

      # Warmup brod
      Enum.map(0..(max_partition - 1), fn i ->
        :brod.produce_sync_offset(:kafka_client, topic, i, key, val)
      end)

      Benchee.run(
        %{
          "klife" => fn ->
            {:ok, offset} =
              Klife.Producer.produce(
                record,
                topic,
                Enum.random(0..(max_partition - 1)),
                :my_test_cluster_1
              )
          end,
          "klife multi inflight" => fn ->
            {:ok, offset} =
              Klife.Producer.produce(
                record,
                "benchmark_topic_in_flight",
                Enum.random(0..(max_partition - 1)),
                :my_test_cluster_1
              )
          end,
          # "kafka_ex" => fn ->
          #   {:ok, offset} =
          #     KafkaEx.produce(topic, Enum.random(0..(max_partition - 1)), val,
          #       key: key,
          #       required_acks: -1
          #     )
          # end,
          "brod" => fn ->
            {:ok, offset} =
              :brod.produce_sync_offset(
                :kafka_client,
                topic,
                Enum.random(0..(max_partition - 1)),
                key,
                val
              )
          end
        },
        time: 15,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end
  end
end
