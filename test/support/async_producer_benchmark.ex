defmodule Klife.TestUtils.AsyncProducerBenchmark do
  alias Klife.Producer.Controller, as: PController

  @number_of_records 5_000_000

  def run(clients, sample_data) do
    topics = [
      List.first(sample_data.records_0).topic,
      List.first(sample_data.records_1).topic,
      List.first(sample_data.records_2).topic
    ]

    records = sample_data.records_0 ++ sample_data.records_1 ++ sample_data.records_2

    Enum.map(clients, &run_benchmark(&1, topics, records)) |> dbg()
  end

  defp run_benchmark("erlkaf", topics, records) do
    :erlkaf.start()

    producer_config = [bootstrap_servers: "localhost:19092"]

    :ok = :erlkaf.create_producer(:erlkaf_test_producer, producer_config)

    client_pid =
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

    result = measurement_collector("erlkaf", topics)

    :erlkaf.stop()

    result
  end

  defp run_benchmark("klife", topics, records) do
    {:ok, client_pid} =
      Task.start(fn ->
        Enum.map(1..@number_of_records, fn _i ->
          klife_msg = Enum.random(records)
          MyClient.produce_async(klife_msg)
          Process.sleep(1)
        end)
      end)

    result = measurement_collector("klife", topics)

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

    result = measurement_collector("klife", topics)

    :brod.stop()

    result
  end

  defp measurement_collector(client, topics) do
    starting_offset = get_total_offsets(topics)

    IO.puts("Starting to measure #{client} , 2 seconds to first measure")

    Process.sleep(2000)
    measurement = get_total_offsets(topics) - starting_offset
    IO.puts("Measurement 1: #{measurement}")

    Process.sleep(2000)
    measurement = get_total_offsets(topics) - starting_offset
    IO.puts("Measurement 2: #{measurement}")

    Process.sleep(2000)
    measurement = get_total_offsets(topics) - starting_offset
    IO.puts("Measurement 3: #{measurement}")

    Process.sleep(2000)
    measurement = get_total_offsets(topics) - starting_offset
    IO.puts("Measurement 4: #{measurement}")

    Process.sleep(2000)
    measurement = get_total_offsets(topics) - starting_offset
    IO.puts("Measurement 5: #{measurement}")

    measurement
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
end
