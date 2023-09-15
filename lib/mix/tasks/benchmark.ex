if Mix.env() in [:dev] do
  defmodule Mix.Tasks.Benchmark do
    use Mix.Task

    def run(args) do
      Application.ensure_all_started(:klife)
      Process.sleep(1_000)
      apply(Mix.Tasks.Benchmark, :do_run_bench, args)
    end

    def do_run_bench("test") do
      _rec = %{
        value: "1",
        key: "key_1",
        headers: [%{key: "header_key", value: "header_value"}]
      }

      :persistent_term.put({:some, :key}, Application.fetch_env!(:klife, :clusters))

      Benchee.run(
        %{
          "app_env" => fn -> Application.fetch_env!(:klife, :clusters) end,
          "persistent_term" => fn -> :persistent_term.get({:some, :key}) end
        },
        time: 10,
        memory_time: 2
      )
    end

    def do_run_bench("test_producer") do
      topic = "my_no_batch_topic"
      val = :rand.bytes(1000)
      key = "some_key"

      record = %{
        value: val,
        key: key
      }

      create_erlkaf_producer(topic)

      Benchee.run(
        %{
          "klife produce_sync" => fn ->
            {:ok, _offset} =
              Klife.Producer.produce_sync(
                record,
                topic,
                Enum.random(0..2),
                :my_test_cluster_1
              )
          end,
          "kafka_ex" => fn ->
            {:ok, _offset} =
              KafkaEx.produce(topic, Enum.random(0..2), val, key: key, required_acks: -1)
          end,
          "erlkaf" => fn ->
            :ok = :erlkaf.produce(:bench_producer, topic, Enum.random(0..2), key, val, :undefined)
          end
        },
        time: 10,
        memory_time: 2,
        parallel: 10
      )
    end

    defp create_erlkaf_producer(topic) do
      :ok = :erlkaf.start()
      :ok = :erlkaf.create_producer(:bench_producer, Application.get_env(:erlkaf, :config))
      :ok = :erlkaf.create_topic(:bench_producer, topic, [{:request_required_acks, -1}])
    end
  end
end
