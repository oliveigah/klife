if Mix.env() in [:dev] do
  defmodule Mix.Tasks.Benchmark do
    use Mix.Task

    def run(args) do
      Application.ensure_all_started(:klife)

      :ok = Klife.Utils.create_topics()
      opts = [strategy: :one_for_one, name: Benchmark.Supervisor]
      {:ok, _} = Supervisor.start_link([MyClient], opts)

      Process.sleep(1_000)
      apply(Mix.Tasks.Benchmark, :do_run_bench, args)
    end

    defp generate_data() do
      topic0 = "benchmark_topic_0"
      topic1 = "benchmark_topic_1"
      topic2 = "benchmark_topic_2"

      max_partition = 30

      records_0 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: :rand.bytes(1_000),
            key: :rand.bytes(50),
            topic: topic0,
            partition: p
          }
        end)

      records_1 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: :rand.bytes(1_000),
            key: :rand.bytes(50),
            topic: topic1,
            partition: p
          }
        end)

      records_2 =
        Enum.map(0..(max_partition - 1), fn p ->
          %Klife.Record{
            value: :rand.bytes(1_000),
            key: :rand.bytes(50),
            topic: topic2,
            partition: p
          }
        end)

      %{
        records_0: records_0,
        records_1: records_1,
        records_2: records_2,
        max_partition: max_partition
      }
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
      %{
        records_0: records_0,
        records_1: records_1,
        records_2: records_2,
        max_partition: max_partition
      } = generate_data()

      # Warmup brod
      Enum.map(0..(max_partition - 1), fn i ->
        :brod.produce_sync_offset(:kafka_client, List.first(records_0).topic, i, "key", "warmup")
        :brod.produce_sync_offset(:kafka_client, List.first(records_1).topic, i, "key", "warmup")
        :brod.produce_sync_offset(:kafka_client, List.first(records_2).topic, i, "key", "warmup")
      end)

      Benchee.run(
        %{
          "klife" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            t0 = Task.async(fn -> MyClient.produce(rec0) end)
            t1 = Task.async(fn -> MyClient.produce(rec1) end)
            t2 = Task.async(fn -> MyClient.produce(rec2) end)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          end,
          "kafka_ex" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            t0 =
              Task.async(fn ->
                KafkaEx.produce(rec0.topic, rec0.partition, rec0.value,
                  key: rec0.key,
                  required_acks: -1
                )
              end)

            t1 =
              Task.async(fn ->
                KafkaEx.produce(rec1.topic, rec1.partition, rec1.value,
                  key: rec1.key,
                  required_acks: -1
                )
              end)

            t2 =
              Task.async(fn ->
                KafkaEx.produce(rec2.topic, rec2.partition, rec2.value,
                  key: rec2.key,
                  required_acks: -1
                )
              end)

            [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          end,
          "brod" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            t0 =
              Task.async(fn ->
                :brod.produce_sync_offset(
                  :kafka_client,
                  rec0.topic,
                  rec0.partition,
                  rec0.key,
                  rec0.value
                )
              end)

            t1 =
              Task.async(fn ->
                :brod.produce_sync_offset(
                  :kafka_client,
                  rec1.topic,
                  rec1.partition,
                  rec1.key,
                  rec1.value
                )
              end)

            t2 =
              Task.async(fn ->
                :brod.produce_sync_offset(
                  :kafka_client,
                  rec2.topic,
                  rec2.partition,
                  rec2.key,
                  rec2.value
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
      %{
        records_0: records_0,
        records_1: records_1,
        records_2: records_2
      } = generate_data()

      Benchee.run(
        %{
          "produce_batch" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            [{:ok, _}, {:ok, _}, {:ok, _}] = MyClient.produce_batch([rec0, rec1, rec2])
          end,
          "produce_batch_txn" => fn ->
            rec0 = Enum.random(records_0)
            rec1 = Enum.random(records_1)
            rec2 = Enum.random(records_2)

            {:ok, [_rec1, _rec2, _rec3]} = MyClient.produce_batch_txn([rec0, rec1, rec2])
          end
        },
        time: 15,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end

    def do_run_bench("producer_inflight", parallel) do
      %{
        records_0: records_0
      } = generate_data()

      in_flight_records =
        Enum.map(records_0, fn r ->
          %Klife.Record{r | topic: "benchmark_topic_in_flight"}
        end)

      in_flight_linger_records =
        Enum.map(records_0, fn r ->
          %Klife.Record{r | topic: "benchmark_topic_in_flight_linger"}
        end)

      Benchee.run(
        %{
          "klife" => fn ->
            {:ok, _rec} = MyClient.produce(Enum.random(records_0))
          end,
          "klife multi inflight" => fn ->
            {:ok, _rec} = MyClient.produce(Enum.random(in_flight_records))
          end,
          "klife multi inflight linger" => fn ->
            {:ok, _rec} = MyClient.produce(Enum.random(in_flight_linger_records))
          end
        },
        time: 15,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end

    def do_run_bench("producer_resources", parallel, rec_qty) do
      %{
        records_0: records_0,
        records_1: records_1,
        records_2: records_2,
        max_partition: max_partition
      } = generate_data()

      # Warmup brod
      Enum.map(0..(max_partition - 1), fn i ->
        :brod.produce_sync_offset(:kafka_client, List.first(records_0).topic, i, "key", "warmup")
        :brod.produce_sync_offset(:kafka_client, List.first(records_1).topic, i, "key", "warmup")
        :brod.produce_sync_offset(:kafka_client, List.first(records_2).topic, i, "key", "warmup")
      end)

      tasks_recs_to_send =
        Enum.map(1..parallel, fn _t ->
          Enum.map(1..rec_qty, fn _ ->
            [records_0, records_1, records_2]
            |> Enum.random()
            |> Enum.random()
          end)
        end)

      IO.inspect("Running klife")

      tasks_klife =
        Enum.map(tasks_recs_to_send, fn recs ->
          Task.async(fn ->
            Enum.map(recs, fn rec ->
              {:ok, _rec} = MyClient.produce(rec)
            end)
          end)
        end)

      start_klife = System.monotonic_time(:second)

      _resps = Task.await_many(tasks_klife, :timer.minutes(5))

      total_time_klife = System.monotonic_time(:second) - start_klife

      IO.inspect("Running brod")

      tasks_brod =
        Enum.map(tasks_recs_to_send, fn recs ->
          Task.async(fn ->
            Enum.map(recs, fn rec ->
              :brod.produce_sync_offset(
                :kafka_client,
                rec.topic,
                rec.partition,
                rec.key,
                rec.value
              )
            end)
          end)
        end)

      start_brod = System.monotonic_time(:second)

      _resps = Task.await_many(tasks_brod, :timer.minutes(5))

      total_time_brod = System.monotonic_time(:second) - start_brod

      IO.inspect("Running kafka_ex")

      tasks_kafkaex =
        Enum.map(tasks_recs_to_send, fn recs ->
          Task.async(fn ->
            Enum.map(recs, fn rec ->
              KafkaEx.produce(rec.topic, rec.partition, rec.value,
                key: rec.key,
                required_acks: -1
              )
            end)
          end)
        end)

      start_kafkaex = System.monotonic_time(:second)

      _resps = Task.await_many(tasks_kafkaex, :timer.minutes(5))

      total_time_kafkaex = System.monotonic_time(:second) - start_kafkaex

      IO.inspect(
        %{
          total_time_klife_seconds: total_time_klife,
          total_time_brod_seconds: total_time_brod,
          total_time_kafkaex_seconds: total_time_kafkaex
        },
        label: "results"
      )
    end
  end
end
