if Mix.env() in [:dev] do
  defmodule Mix.Tasks.Benchmark do
    use Mix.Task

    alias Klife.TestUtils.AsyncProducerBenchmark
    alias Klife.Record

    def run(args) do
      Application.ensure_all_started(:klife)

      {:ok, _topics} = Klife.Utils.create_topics()
      opts = [strategy: :one_for_one, name: Benchmark.Supervisor]
      {:ok, _} = Supervisor.start_link([MyClient], opts)

      :ok = Klife.Testing.setup(MyClient)

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
      l10 = Enum.map(1..10, fn _i -> :rand.bytes(1000) end)
      l100 = Enum.map(1..100, fn _i -> :rand.bytes(1000) end)
      l1000 = Enum.map(1..1000, fn _i -> :rand.bytes(1000) end)
      l10000 = Enum.map(1..10000, fn _i -> :rand.bytes(1000) end)

      Benchee.run(
        %{
          "l10" => fn -> List.last(l10) end,
          "l100" => fn -> List.last(l100) end,
          "l1000" => fn -> List.last(l1000) end,
          "l10000" => fn -> List.last(l10000) end
        },
        time: 10,
        memory_time: 2,
        parallel: parallel |> String.to_integer()
      )
    end

    def do_run_bench("consumer", client) do
      base_topic = Base.encode16(:rand.bytes(20))
      partitions = 10

      topics = [t1, t2, t3] = Enum.map(1..3, fn i -> base_topic <> "_#{i}" end)
      {:ok, sup_pid} = DynamicSupervisor.start_link(name: :benchmark_supervisor)

      {:ok, target1} = prepare_topic(t1, partitions, 10_000)
      {:ok, target2} = prepare_topic(t2, partitions, 10_000)
      {:ok, target3} = prepare_topic(t3, partitions, 10_000)

      :persistent_term.put(:bench_counter, :atomics.new(1, []))

      run_consumer_bench(
        String.to_existing_atom(client),
        topics,
        target1 + target2 + target3,
        sup_pid
      )
      |> IO.inspect(label: client, charlists: :as_lists)
    end

    def do_run_bench("producer_async", parallel) do
      AsyncProducerBenchmark.run(["klife"], String.to_integer(parallel))
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
          end
          # "kafka_ex" => fn ->
          #   rec0 = Enum.random(records_0)
          #   rec1 = Enum.random(records_1)
          #   rec2 = Enum.random(records_2)

          #   t0 =
          #     Task.async(fn ->
          #       KafkaEx.produce(rec0.topic, rec0.partition, rec0.value,
          #         key: rec0.key,
          #         required_acks: -1
          #       )
          #     end)

          #   t1 =
          #     Task.async(fn ->
          #       KafkaEx.produce(rec1.topic, rec1.partition, rec1.value,
          #         key: rec1.key,
          #         required_acks: -1
          #       )
          #     end)

          #   t2 =
          #     Task.async(fn ->
          #       KafkaEx.produce(rec2.topic, rec2.partition, rec2.value,
          #         key: rec2.key,
          #         required_acks: -1
          #       )
          #     end)

          #   [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          # end,
          # "brod" => fn ->
          #   rec0 = Enum.random(records_0)
          #   rec1 = Enum.random(records_1)
          #   rec2 = Enum.random(records_2)

          #   t0 =
          #     Task.async(fn ->
          #       :brod.produce_sync_offset(
          #         :kafka_client,
          #         rec0.topic,
          #         rec0.partition,
          #         rec0.key,
          #         rec0.value
          #       )
          #     end)

          #   t1 =
          #     Task.async(fn ->
          #       :brod.produce_sync_offset(
          #         :kafka_client,
          #         rec1.topic,
          #         rec1.partition,
          #         rec1.key,
          #         rec1.value
          #       )
          #     end)

          #   t2 =
          #     Task.async(fn ->
          #       :brod.produce_sync_offset(
          #         :kafka_client,
          #         rec2.topic,
          #         rec2.partition,
          #         rec2.key,
          #         rec2.value
          #       )
          #     end)

          #   [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many([t0, t1, t2])
          # end
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

    defp run_consumer_bench(client, topics, target, sup_pid) do
      counter = :persistent_term.get(:bench_counter)

      Enum.map(1..1, fn _ ->
        {:ok, pid} =
          case client do
            :brod ->
              DynamicSupervisor.start_child(
                sup_pid,
                {BrodBenchmarkConsumer,
                 %{
                   topics: topics,
                   consumer_config: [{:begin_offset, :earliest}],
                   consumer_group_id: Base.encode64(:rand.bytes(10))
                 }}
              )

            :klife ->
              DynamicSupervisor.start_child(
                sup_pid,
                {BenchmarkConsumer,
                 [
                   topics:
                     Enum.map(topics, fn tname ->
                       [
                         name: tname,
                         offset_reset_policy: :earliest
                       ]
                     end),
                   group_name: Base.encode64(:rand.bytes(10))
                 ]}
              )
          end

        t0 = System.monotonic_time(:millisecond)

        :ok =
          wait_consumption(
            counter,
            target,
            System.monotonic_time(:millisecond) + 30_000
          )

        tf = System.monotonic_time(:millisecond)

        t_first_call = :persistent_term.get(:first_call)
        :persistent_term.erase(:first_call)
        :atomics.put(counter, 1, 0)

        :ok = DynamicSupervisor.terminate_child(sup_pid, pid)

        total = tf - t0
        first_call = tf - t_first_call

        [
          total_time: "#{total} ms",
          since_first_cb_call: "#{first_call} ms (#{Float.round(first_call / total * 100, 2)}%)"
        ]
      end)
    end

    # klife: [{2288, 94}]
    # brod:  [{135, 98}]

    defp prepare_topic(topic, partitions, recs_per_partition) do
      :ok = Klife.TestUtils.create_topics(MyClient, [%{name: topic, partitions: partitions}])

      rec_size = 1
      bytes = :rand.bytes(rec_size)

      Enum.map(0..(partitions - 1), fn p ->
        Task.async(fn ->
          Enum.map(1..recs_per_partition, fn _i ->
            %Record{
              value: bytes,
              topic: topic,
              partition: p
            }
          end)
          |> Enum.chunk_every(5)
          |> Enum.each(fn rec_batch -> MyClient.produce_batch(rec_batch) end)
        end)
      end)
      |> Task.await_many(120_000)

      target_val = round(partitions * recs_per_partition * rec_size)

      {:ok, target_val}
    end

    defp wait_consumption(atomic_ref, target, deadline) do
      if System.monotonic_time(:millisecond) > deadline do
        raise "Timeout on wait consumption!"
      end

      curr_val = :atomics.get(atomic_ref, 1)

      cond do
        curr_val < target ->
          Process.sleep(1)
          wait_consumption(atomic_ref, target, deadline)

        curr_val == target ->
          :ok

        curr_val > target ->
          raise "Double count!"
      end
    end
  end

  defmodule BenchmarkConsumer do
    use Klife.Consumer.ConsumerGroup, client: MyClient

    @impl true
    def handle_record_batch(_topic, _partition, recs) do
      if :persistent_term.get(:first_call, nil) == nil do
        :persistent_term.put(:first_call, System.monotonic_time(:millisecond))
      end

      counter = :persistent_term.get(:bench_counter)

      Enum.each(recs, fn %Klife.Record{} = rec ->
        :atomics.add(counter, 1, byte_size(rec.value))
      end)

      :commit
    end
  end

  defmodule BrodBenchmarkConsumer do
    @behaviour :brod_group_subscriber_v2

    def child_spec(config) do
      config = %{
        client: :kafka_client,
        group_id: config.consumer_group_id,
        topics: config.topics,
        cb_module: __MODULE__,
        consumer_config: config.consumer_config,
        init_data: [],
        message_type: :message_set,
        group_config: [
          offset_commit_policy: :commit_to_kafka_v2,
          offset_commit_interval_seconds: 5,
          rejoin_delay_seconds: 60,
          reconnect_cool_down_seconds: 60
        ]
      }

      %{
        id: __MODULE__,
        start: {:brod_group_subscriber_v2, :start_link, [config]},
        type: :worker,
        restart: :temporary,
        shutdown: 5000
      }
    end

    @impl :brod_group_subscriber_v2
    def init(_group_id, _init_data), do: {:ok, []}

    @impl :brod_group_subscriber_v2
    def handle_message(message, _state) do
      if :persistent_term.get(:first_call, nil) == nil do
        :persistent_term.put(:first_call, System.monotonic_time(:millisecond))
      end

      {:kafka_message_set, _topic, _p, _count, recs} = message
      counter = :persistent_term.get(:bench_counter)

      Enum.each(recs, fn rec ->
        {:kafka_message, _offset, _headers?, val, _, _, _} = rec
        :atomics.add(counter, 1, byte_size(val))
      end)

      {:ok, :commit, []}
    end
  end
end
