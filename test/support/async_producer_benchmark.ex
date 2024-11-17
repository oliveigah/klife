defmodule Klife.TestUtils.AsyncProducerBenchmark do
  require Logger

  alias Klife.Producer.Controller, as: PController

  @number_of_records 5_000_000

  def run(clients) do
    sample_data = generate_data()

    topics = [
      List.first(sample_data.records_0).topic,
      List.first(sample_data.records_1).topic,
      List.first(sample_data.records_2).topic
    ]

    records = sample_data.records_0 ++ sample_data.records_1 ++ sample_data.records_2

    client_results = Enum.map(clients, &run_benchmark(&1, topics, records))

    results = Enum.zip(clients, client_results) |> Map.new()
    IO.puts("Client  | Result    | Compared to klife")
    Enum.each(results, fn {client, result} ->
      IO.puts(
        "#{client}\t| #{result}   | x#{results_compared_to_klife(result, results)}"
      )
    end)
  end

  defp run_benchmark("erlkaf", topics, records) do
    :erlkaf.start()

    producer_config = [
      bootstrap_servers: "localhost:19092",
      max_in_flight: 1,
      enable_idempotence: true,
      sticky_partitioning_linger_ms: 0,
      batch_size: 512_000
    ]

    :ok = :erlkaf.create_producer(:erlkaf_test_producer, producer_config)

    Task.start(fn ->
      Enum.map(1..@number_of_records, fn _i ->
        erlkaf_msg = Enum.random(records)

        :erlkaf.produce(
          :erlkaf_test_producer,
          erlkaf_msg.topic,
          erlkaf_msg.key,
          erlkaf_msg.value
        )
      end)

      :ok
    end)

    result = measurement_collector(topics)

    :erlkaf.stop()

    result
  end

  defp run_benchmark("klife", topics, records) do
    {:ok, client_pid} =
      Task.start(fn ->
        Enum.map(1..@number_of_records, fn _i ->
          klife_msg = Enum.random(records)
          MyClient.produce_async(klife_msg)
        end)
      end)

    result = measurement_collector(topics)

    Process.exit(client_pid, :kill)

    result
  end

  defp run_benchmark("brod", topics, records) do
    Task.async(fn ->
      Enum.map(1..@number_of_records, fn _i ->
        brod_msg = Enum.random(records)

        :brod.produce(
          :kafka_client,
          brod_msg.topic,
          brod_msg.partition,
          brod_msg.key,
          brod_msg.value
        )
      end)
    end)

    result = measurement_collector(topics)

    :brod.stop()

    result
  end

  defp measurement_collector(topics) do
    starting_offset = get_total_offsets(topics)

    Process.sleep(10000)

    get_total_offsets(topics) - starting_offset
  end

  defp get_total_offsets(topics), do: get_offset_by_topic(topics) |> Map.values() |> Enum.sum()

  defp get_offset_by_topic(topics) do
    metas = PController.get_all_topics_partitions_metadata(MyClient)

    data_by_topic =
      metas
      |> Enum.group_by(fn m -> m.leader_id end)
      |> Enum.flat_map(fn {leader_id, metas} ->
        Klife.Testing.get_latest_offsets(leader_id, metas, MyClient)
      end)
      |> Enum.filter(fn {topic, _pdata} -> Enum.member?(topics, topic) end)
      |> Enum.group_by(fn {topic, _pdata} -> topic end, fn {_topic, pdata} -> pdata end)
      |> Enum.map(fn {k, v} ->
        {k, List.flatten(v) |> Enum.map(fn {_p, offset} -> offset end) |> Enum.sum()}
      end)
      |> Map.new()
  end

  defp generate_data() do
    topic0 = "async_benchmark_topic_0"
    topic1 = "async_benchmark_topic_1"
    topic2 = "async_benchmark_topic_2"

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

  defp results_compared_to_klife(result, results) do
    result / Map.get(results, "klife") |> Float.round(2)
  end
end
