if Mix.env() in [:dev] do
  defmodule Mix.Tasks.Benchmark do
    use Mix.Task

    def run(args) do
      Application.ensure_all_started(:klife)
      Process.sleep(1_000)
      apply(Mix.Tasks.Benchmark, :do_run_bench, args)
    end

    defp definition(%{a: a, b: b, c: c}), do: a + b + c

    defp inside(map) do
      %{a: a, b: b, c: c} = map
      a + b + c
    end

    defp no_match(map) do
      map.a + map.b + map.c
    end

    def do_run_bench("test") do
      input = %{a: 1, b: 2, c: 3}

      Benchee.run(
        %{
          "definition" => fn -> Enum.each(1..1000, fn _ -> definition(input) end) end,
          "inside" => fn -> Enum.each(1..1000, fn _ -> inside(input) end) end,
          "no_match" => fn -> Enum.each(1..1000, fn _ -> no_match(input) end) end
        },
        time: 10,
        memory_time: 2
      )
    end

    def do_run_bench("test_producer_sync", parallel) do
      topic = "benchmark_topic"
      val = :rand.bytes(1000)
      key = "some_key"

      record = %{
        value: val,
        key: key
      }

      Benchee.run(
        %{
          "klife" => fn ->
            {:ok, offset} =
              Klife.Producer.produce_sync(
                record,
                topic,
                Enum.random(0..11),
                :my_test_cluster_1
              )
          end,
          "kafka_ex" => fn ->
            {:ok, offset} =
              KafkaEx.produce(topic, Enum.random(0..11), val, key: key, required_acks: -1)
          end,
          "brod" => fn ->
            {:ok, offset} =
              :brod.produce_sync_offset(
                :kafka_client,
                topic,
                Enum.random(0..11),
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
