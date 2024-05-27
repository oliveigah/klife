defmodule Klife.TestUtils do
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias KlifeProtocol.Messages, as: M
  alias Klife.PubSub

  @port_to_service_name %{
    19092 => "kafka1",
    29092 => "kafka2",
    39092 => "kafka3"
  }

  @docker_file_path Path.relative("test/compose_files/docker-compose.yml")

  defp get_service_name(cluster_name, broker_id) do
    content = %{include_cluster_authorized_operations: true, topics: []}

    {:ok, resp} = Broker.send_message(M.Metadata, cluster_name, :any, content)

    broker = Enum.find(resp.content.brokers, fn b -> b.node_id == broker_id end)

    @port_to_service_name[broker.port]
  end

  def stop_broker(cluster_name, broker_id) do
    Task.async(fn ->
      cb_ref = make_ref()
      :ok = PubSub.subscribe({:cluster_change, cluster_name}, cb_ref)

      service_name = get_service_name(cluster_name, broker_id)

      System.shell("docker-compose -f #{@docker_file_path} stop #{service_name} > /dev/null 2>&1")

      result =
        receive do
          {{:cluster_change, ^cluster_name}, event_data, ^cb_ref} ->
            removed_brokers = event_data.removed_brokers
            brokers_list = Enum.map(removed_brokers, fn {broker_id, _url} -> broker_id end)

            if broker_id in brokers_list,
              do: {:ok, service_name},
              else: {:error, :invalid_event}
        after
          10_000 ->
            {:error, :timeout}
        end

      :ok = PubSub.unsubscribe({:cluster_change, cluster_name})

      Process.sleep(10)
      result
    end)
    |> Task.await(30_000)
  end

  def start_broker(service_name, cluster_name) do
    Task.async(fn ->
      cb_ref = make_ref()
      port_map = @port_to_service_name |> Enum.map(fn {k, v} -> {v, k} end) |> Map.new()
      expected_url = "localhost:#{port_map[service_name]}"

      :ok = PubSub.subscribe({:cluster_change, cluster_name}, cb_ref)

      old_brokers = :persistent_term.get({:known_brokers_ids, cluster_name})

      System.shell(
        "docker-compose -f #{@docker_file_path} start #{service_name} > /dev/null 2>&1"
      )

      :ok =
        Enum.reduce_while(1..20, nil, fn _, _acc ->
          :ok = ConnController.trigger_brokers_verification(cluster_name)
          new_brokers = :persistent_term.get({:known_brokers_ids, cluster_name})

          if old_brokers != new_brokers do
            {:halt, :ok}
          else
            Process.sleep(500)
            {:cont, nil}
          end
        end)

      result =
        receive do
          {{:cluster_change, ^cluster_name}, event_data, ^cb_ref} ->
            added_brokers = event_data.added_brokers

            case Enum.find(added_brokers, fn {_broker_id, url} -> url == expected_url end) do
              nil ->
                {:error, :invalid_event}

              {broker_id, ^expected_url} ->
                {:ok, broker_id}
            end
        after
          10_000 ->
            {:error, :timeout}
        end

      :ok = PubSub.unsubscribe({:cluster_change, cluster_name})

      Process.sleep(10)
      result
    end)
    |> Task.await(30_000)
  end

  def get_record_by_offset(cluster_name, topic, partition, offset) do
    content = %{
      replica_id: -1,
      max_wait_ms: 1000,
      min_bytes: 1,
      max_bytes: 100_000,
      isolation_level: 0,
      topics: [
        %{
          topic: topic,
          partitions: [
            %{
              partition: partition,
              fetch_offset: offset,
              # 1 guarantees that only the first record batch will
              # be retrieved
              partition_max_bytes: 1
            }
          ]
        }
      ]
    }

    broker = Klife.Producer.Controller.get_broker_id(cluster_name, topic, partition)

    {:ok, %{content: content}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.Fetch,
        cluster_name,
        broker,
        content
      )

    topic_resp = Enum.find(content.responses, &(&1.topic == topic))
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))
    [%{base_offset: base_offset, records: records}] = partition_resp.records
    Enum.find(records, &(&1.offset_delta + base_offset == offset))
  end

  def get_record_batch_by_offset(cluster_name, topic, partition, offset) do
    content = %{
      replica_id: -1,
      max_wait_ms: 1000,
      min_bytes: 1,
      max_bytes: 100_000,
      isolation_level: 0,
      topics: [
        %{
          topic: topic,
          partitions: [
            %{
              partition: partition,
              fetch_offset: offset,
              # 1 guarantees that only the first record batch will
              # be retrieved
              partition_max_bytes: 1
            }
          ]
        }
      ]
    }

    broker = Klife.Producer.Controller.get_broker_id(cluster_name, topic, partition)

    {:ok, %{content: content}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.Fetch,
        cluster_name,
        broker,
        content
      )

    topic_resp = Enum.find(content.responses, &(&1.topic == topic))
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))
    [%{records: records}] = partition_resp.records
    records
  end

  def get_partition_resp_records_by_offset(cluster_name, topic, partition, offset) do
    content = %{
      replica_id: -1,
      max_wait_ms: 1000,
      min_bytes: 1,
      max_bytes: 100_000,
      isolation_level: 0,
      topics: [
        %{
          topic: topic,
          partitions: [
            %{
              partition: partition,
              fetch_offset: offset,
              # 1 guarantees that only the first record batch will
              # be retrieved
              partition_max_bytes: 1
            }
          ]
        }
      ]
    }

    broker = Klife.Producer.Controller.get_broker_id(cluster_name, topic, partition)

    {:ok, %{content: content}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.Fetch,
        cluster_name,
        broker,
        content
      )

    topic_resp = Enum.find(content.responses, &(&1.topic == topic))
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))
    partition_resp.records
  end
end
