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
      topic0 = "benchmark_topic_0"
      topic1 = "benchmark_topic_1"
      topic2 = "benchmark_topic_2"

      max_partition =
        :klife
        |> Application.fetch_env!(:clusters)
        |> List.first()
        |> Keyword.get(:topics)
        |> Enum.find(&(&1.name == topic0))
        |> Map.get(:num_partitions)

      val = :rand.bytes(1_000)
      key = "some_key"

      records_0 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: topic0,
            partition: p
          }
        end)

      records_1 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: topic1,
            partition: p
          }
        end)

      records_2 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: topic2,
            partition: p
          }
        end)

      # Warmup brod
      Enum.map(0..(max_partition - 1), fn i ->
        :brod.produce_sync_offset(:kafka_client, topic0, i, key, val)
        :brod.produce_sync_offset(:kafka_client, topic1, i, key, val)
        :brod.produce_sync_offset(:kafka_client, topic2, i, key, val)
      end)

      Benchee.run(
        %{
          "klife" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            t0 = Task.async(fn -> Klife.produce(rec0) end)
            t1 = Task.async(fn -> Klife.produce(rec1) end)
            t2 = Task.async(fn -> Klife.produce(rec2) end)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          end,
          # "klife multi inflight" => fn ->
          #   {:ok, _rec} =
          #     Klife.produce(Enum.random(in_flight_records))
          # end,
          "kafka_ex" => fn ->
            p0 = Enum.random(0..(max_partition - 1))
            p1 = Enum.random(0..(max_partition - 1))
            p2 = Enum.random(0..(max_partition - 1))

            t0 =
              Task.async(fn ->
                KafkaEx.produce(topic0, p0, val,
                  key: key,
                  required_acks: -1
                )
              end)

            t1 =
              Task.async(fn ->
                KafkaEx.produce(topic1, p1, val,
                  key: key,
                  required_acks: -1
                )
              end)

            t2 =
              Task.async(fn ->
                KafkaEx.produce(topic2, p2, val,
                  key: key,
                  required_acks: -1
                )
              end)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          end,
          "brod" => fn ->
            p0 = Enum.random(0..(max_partition - 1))
            p1 = Enum.random(0..(max_partition - 1))
            p2 = Enum.random(0..(max_partition - 1))

            t0 =
              Task.async(fn ->
                :brod.produce_sync_offset(
                  :kafka_client,
                  topic0,
                  p0,
                  key,
                  val
                )
              end)

            t1 =
              Task.async(fn ->
                :brod.produce_sync_offset(
                  :kafka_client,
                  topic1,
                  p1,
                  key,
                  val
                )
              end)

            t2 =
              Task.async(fn ->
                :brod.produce_sync_offset(
                  :kafka_client,
                  topic2,
                  p2,
                  key,
                  val
                )
              end)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          end
        },
        time: 15,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end

    def do_run_bench("producer_txn", parallel) do
      topic0 = "benchmark_topic_0"
      topic1 = "benchmark_topic_1"
      topic2 = "benchmark_topic_2"

      max_partition =
        :klife
        |> Application.fetch_env!(:clusters)
        |> List.first()
        |> Keyword.get(:topics)
        |> Enum.find(&(&1.name == topic0))
        |> Map.get(:num_partitions)

      val = :rand.bytes(1_000)
      key = "some_key"

      records_0 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: topic0,
            partition: p
          }
        end)

      records_1 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: topic1,
            partition: p
          }
        end)

      records_2 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: topic2,
            partition: p
          }
        end)

      Benchee.run(
        %{
          "klife with batch no txn" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Klife.produce([rec0, rec1, rec2])
          end,
          "klife with batch with txn" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Klife.produce([rec0, rec1, rec2], with_txn: true)
          end,
          "klife no batch no txn" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            t0 = Task.async(fn -> Klife.produce(rec0) end)
            t1 = Task.async(fn -> Klife.produce(rec1) end)
            t2 = Task.async(fn -> Klife.produce(rec2) end)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          end
        },
        time: 15,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end

    def do_run_bench("producer_inflight", parallel) do
      topic0 = "benchmark_topic_0"

      max_partition =
        :klife
        |> Application.fetch_env!(:clusters)
        |> List.first()
        |> Keyword.get(:topics)
        |> Enum.find(&(&1.name == topic0))
        |> Map.get(:num_partitions)

      val = :rand.bytes(1_000)
      key = "some_key"

      records_0 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: topic0,
            partition: p
          }
        end)

      in_flight_records =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: val,
            key: key,
            topic: "benchmark_topic_in_flight",
            partition: p
          }
        end)

      Benchee.run(
        %{
          "klife" => fn ->
            {:ok, _rec} = Klife.produce(Enum.random(records_0))
          end,
          "klife multi inflight" => fn ->
            {:ok, _rec} = Klife.produce(Enum.random(in_flight_records))
          end
        },
        time: 15,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end
  end
end
