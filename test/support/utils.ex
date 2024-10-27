defmodule Klife.TestUtils do
  @moduledoc false
  import ExUnit.Assertions

  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias KlifeProtocol.Messages, as: M
  alias Klife.PubSub

  alias Klife.Record

  @port_to_service_name %{
    19092 => "kafka1",
    19093 => "kafka1",
    19094 => "kafka1",
    29092 => "kafka2",
    29093 => "kafka2",
    29094 => "kafka2",
    39092 => "kafka3",
    39093 => "kafka3",
    39094 => "kafka3"
  }

  @docker_file_path Path.relative("test/compose_files/docker-compose.yml")

  defp get_service_name(client_name, broker_id) do
    content = %{include_client_authorized_operations: true, topics: []}

    {:ok, resp} = Broker.send_message(M.Metadata, client_name, :any, content)

    broker = Enum.find(resp.content.brokers, fn b -> b.node_id == broker_id end)

    Map.fetch!(@port_to_service_name, broker.port)
  end

  def stop_broker(client_name, broker_id) do
    # This must be done in a separate process because
    # of how the PubSub works.
    task = Task.async(fn -> do_stop_broker(client_name, broker_id) end)
    Task.await(task, :infinity)
    |> tap(fn _ -> Process.sleep(:timer.seconds(10)) end)
  end

  defp do_stop_broker(client_name, broker_id) do
    cb_ref = make_ref()
    :ok = PubSub.subscribe({:cluster_change, client_name}, cb_ref)

    service_name = get_service_name(client_name, broker_id)

    System.shell("docker compose -f #{@docker_file_path} stop #{service_name} > /dev/null 2>&1")

    result =
      receive do
        {{:cluster_change, ^client_name}, event_data, ^cb_ref} ->
          removed_brokers = event_data.removed_brokers
          brokers_list = Enum.map(removed_brokers, fn {broker_id, _url} -> broker_id end)

          if broker_id in brokers_list,
            do: {:ok, service_name},
            else: {:error, :invalid_event}
      after
        30_000 ->
          {:error, :timeout}
      end

    :ok = PubSub.unsubscribe({:cluster_change, client_name})

    result
  end

  def start_broker(service_name, client_name) do
    Task.async(fn ->
      cb_ref = make_ref()

      port_prefix_service_map =
        @port_to_service_name
        |> Enum.map(fn {port, service} ->
          {port_prefix, _} = String.split_at("#{port}", 2)
          {service, port_prefix}
        end)
        |> Map.new()

      expected_url_prefix = "localhost:#{port_prefix_service_map[service_name]}"

      :ok = PubSub.subscribe({:cluster_change, client_name}, cb_ref)

      old_brokers = :persistent_term.get({:known_brokers_ids, client_name})

      System.shell(
        "docker compose -f #{@docker_file_path} start #{service_name} > /dev/null 2>&1"
      )

      :ok =
        Enum.reduce_while(1..50, nil, fn _, _acc ->
          :ok = ConnController.trigger_brokers_verification(client_name)
          new_brokers = :persistent_term.get({:known_brokers_ids, client_name})

          if old_brokers != new_brokers do
            {:halt, :ok}
          else
            Process.sleep(500)
            {:cont, nil}
          end
        end)

      result =
        receive do
          {{:cluster_change, ^client_name}, event_data, ^cb_ref} ->
            added_brokers = event_data.added_brokers

            case Enum.find(added_brokers, fn {_broker_id, url} ->
                   String.starts_with?(url, expected_url_prefix)
                 end) do
              nil ->
                {:error, :invalid_event}

              {broker_id, _} ->
                {:ok, broker_id}
            end
        after
          50_000 ->
            {:error, :timeout}
        end

      :ok = PubSub.unsubscribe({:cluster_change, client_name})
      result
    end)
    |> Task.await(60_000)
    |> tap(fn _ -> Process.sleep(:timer.seconds(10)) end)
  end

  def get_record_batch_by_offset(client_name, topic, partition, offset) do
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

    broker = Klife.Producer.Controller.get_broker_id(client_name, topic, partition)

    {:ok, %{content: content}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.Fetch,
        client_name,
        broker,
        content
      )

    topic_resp = Enum.find(content.responses, &(&1.topic == topic))
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))
    [%{records: records}] = partition_resp.records
    records
  end

  def get_partition_resp_records_by_offset(client_name, topic, partition, offset) do
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

    broker = Klife.Producer.Controller.get_broker_id(client_name, topic, partition)

    {:ok, %{content: content}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.Fetch,
        client_name,
        broker,
        content
      )

    topic_resp = Enum.find(content.responses, &(&1.topic == topic))
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))
    partition_resp.records
  end

  def get_latest_offset(client, topic, partition, base_ts) do
    broker = Klife.Producer.Controller.get_broker_id(client, topic, partition)

    content = %{
      replica_id: -1,
      isolation_level: 1,
      topics: [
        %{
          name: topic,
          partitions: [
            %{
              partition_index: partition,
              timestamp: base_ts
            }
          ]
        }
      ]
    }

    {:ok, %{content: resp}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.ListOffsets,
        client,
        broker,
        content
      )

    [%{partitions: partitions}] = resp.topics
    [%{error_code: 0, offset: offset}] = partitions

    offset
  end

  def assert_offset(
        client,
        %Record{topic: topic} = expected_record,
        offset,
        opts \\ []
      ) do
    partition = Keyword.get(opts, :partition, expected_record.partition)
    iso_lvl = Keyword.get(opts, :isolation, :committed)
    txn_status = Keyword.get(opts, :txn_status, :committed)

    client
    |> get_record_by_offset(topic, partition, offset, iso_lvl)
    |> case do
      nil ->
        :not_found

      {stored_record, status} ->
        assert status == txn_status

        Enum.each(Map.from_struct(expected_record), fn {k, v} ->
          case k do
            :value -> assert v == stored_record.value
            :headers -> assert (v || []) == stored_record.headers
            :key -> assert v == stored_record.key
            _ -> :noop
          end
        end)
    end
  end

  defp get_record_by_offset(client_name, topic, partition, offset, isolation) do
    isolation_level =
      case isolation do
        :committed -> 1
        :uncommitted -> 0
      end

    content = %{
      replica_id: -1,
      max_wait_ms: 1000,
      min_bytes: 1,
      max_bytes: 100_000,
      isolation_level: isolation_level,
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

    broker = Klife.Producer.Controller.get_broker_id(client_name, topic, partition)

    {:ok, %{content: content}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.Fetch,
        client_name,
        broker,
        content
      )

    topic_resp = Enum.find(content.responses, &(&1.topic == topic))
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))

    aborted_offset =
      case partition_resp.aborted_transactions do
        [%{first_offset: aborted_offset}] -> aborted_offset
        _ -> :infinity
      end

    case partition_resp.records do
      [%{base_offset: base_offset, records: records}] ->
        rec = Enum.find(records, &(&1.offset_delta + base_offset == offset))
        if aborted_offset <= offset, do: {rec, :aborted}, else: {rec, :committed}

      [] ->
        nil
    end
  end
end
