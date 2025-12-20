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

  def get_docker_compose_file do
    vsn = System.fetch_env!("KLIFE_KAFKA_VSN")
    Path.relative("test/compose_files/docker-compose-kafka-#{vsn}.yml")
  end

  defp get_service_name(client_name, broker_id) do
    content = %{
      include_topic_authorized_operations: true,
      topics: [],
      allow_auto_topic_creation: false
    }

    {:ok, resp} = Broker.send_message(M.Metadata, client_name, :any, content)

    broker = Enum.find(resp.content.brokers, fn b -> b.node_id == broker_id end)

    Map.fetch!(@port_to_service_name, broker.port)
  end

  def stop_broker(client_name, broker_id) do
    # This must be done in a separate process because
    # of how the PubSub works.
    Task.async(fn -> do_stop_broker(client_name, broker_id) end)
    |> Task.await(:infinity)
    # This sleep is needed because we must
    # give some time to the producer system react to the cluster
    # change. One way to avoid this, would be having pubsub
    # events related to the producer system but it does not
    # exists yet.
    #
    # Also, it appears that metadata changes may happen in multiple
    # steps when a broker enters/leaves the cluster and it may cause
    # metadata changes to occur unexpecteadly inside a test, increase
    # this sleep may help avoid this scenario, but I think it is
    # not possible to guarantee it won't happen at all
    |> tap(fn _ -> Process.sleep(:timer.seconds(5)) end)
  end

  defp do_stop_broker(client_name, broker_id) do
    cb_ref = make_ref()
    :ok = PubSub.subscribe({:cluster_change, client_name}, cb_ref)

    service_name = get_service_name(client_name, broker_id)

    System.shell(
      "docker compose -f #{get_docker_compose_file()} stop #{service_name} > /dev/null 2>&1"
    )

    result =
      receive do
        {{:cluster_change, ^client_name}, event_data, ^cb_ref} ->
          if broker_id in ConnController.get_known_brokers(client_name),
            do: {:error, :invalid_event, event_data},
            else: {:ok, service_name}
      after
        60_000 ->
          {:error, :timeout}
      end

    :ok = PubSub.unsubscribe({:cluster_change, client_name})

    result
  end

  def start_broker(service_name, client_name) do
    # This must be done in a separate process because
    # of how the PubSub works.
    Task.async(fn -> do_start_broker(service_name, client_name) end)
    |> Task.await(:infinity)
    # This sleep is needed because we must
    # give some time to the producer system react to the cluster
    # change. One way to avoid this, would be having pubsub
    # events related to the producer system but it does not
    # exists yet.
    #
    # Also, it appears that metadata changes may happen in multiple
    # steps when a broker enters/leaves the cluster and it may cause
    # metadata changes to occur unexpecteadly inside a test, increase
    # this sleep may help avoid this scenario, but I think it is
    # not possible to guarantee it won't happen at all
    |> tap(fn _ -> Process.sleep(:timer.seconds(5)) end)
  end

  defp do_start_broker(service_name, client_name) do
    cb_ref = make_ref()

    :ok = PubSub.subscribe({:cluster_change, client_name}, cb_ref)

    old_brokers = ConnController.get_known_brokers(client_name)

    System.shell(
      "docker compose -f #{get_docker_compose_file()} start #{service_name} > /dev/null 2>&1"
    )

    result =
      receive do
        {{:cluster_change, ^client_name}, event_data, ^cb_ref} ->
          new_brokers = ConnController.get_known_brokers(client_name)

          case new_brokers -- old_brokers do
            [broker_id] -> {:ok, broker_id}
            _other -> {:error, :invalid_event, event_data}
          end
      after
        60_000 ->
          {:error, :timeout}
      end

    :ok = PubSub.unsubscribe({:cluster_change, client_name})
    result
  end

  def get_record_batch_by_offset(client_name, topic, partition, offset) do
    {:ok, %{content: content}} =
      make_fetch_req(client_name, {topic, partition, offset}, max_bytes: 1)

    [topic_resp] = content.responses
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))
    [%{records: records, base_offset: bo}] = partition_resp.records

    Enum.map(records, fn r -> Map.put(r, :offset, r.offset_delta + bo) end)
  end

  def get_partition_resp_records_by_offset(client_name, topic, partition, offset) do
    {:ok, %{content: content}} = make_fetch_req(client_name, {topic, partition, offset})

    [topic_resp] = content.responses
    partition_resp = Enum.find(topic_resp.partitions, &(&1.partition_index == partition))
    partition_resp.records
  end

  def get_latest_offset(client, topic, partition, base_ts) do
    broker = Klife.MetadataCache.get_metadata_attribute(client, topic, partition, :leader_id)

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
    iso_lvl = Keyword.get(opts, :isolation, :uncommitted)
    txn_status = Keyword.get(opts, :txn_status, :committed)

    client
    |> get_record_by_offset(topic, partition, offset, iso_lvl)
    |> case do
      nil ->
        :not_found

      {stored_record, status} ->
        Enum.each(Map.from_struct(expected_record), fn {k, v} ->
          case k do
            :value -> assert v == stored_record.value
            :headers -> assert (v || []) == stored_record.headers
            :key -> assert v == stored_record.key
            _ -> :noop
          end
        end)

        assert status == txn_status

        :ok
    end
  end

  defp get_record_by_offset(client_name, topic, partition, offset, isolation) do
    {:ok, %{content: content}} =
      make_fetch_req(client_name, {topic, partition, offset},
        isolation_level: isolation,
        max_bytes: 1
      )

    [topic_resp] = content.responses
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

  def assert_records(response_record, expected_record) do
    fields_to_compare = [
      :key,
      :topic,
      :partition,
      :offset,
      :value,
      :headers
    ]

    Enum.each(fields_to_compare, fn field ->
      resp_val = Map.fetch!(response_record, field)
      exp_val = Map.fetch!(expected_record, field)
      assert {field, resp_val} == {field, exp_val}
    end)
  end

  def create_topics(client_name, tp_list) do
    # This must be done in a separate process because
    # of how the PubSub works.
    Task.async(fn -> do_create_topics(client_name, tp_list) end)
    |> Task.await(:infinity)
    # This sleep is needed because we must
    # give some time to the producer system react to the cluster
    # change. One way to avoid this, would be having pubsub
    # events related to the producer system but it does not
    # exists yet.
    |> tap(fn _ -> Process.sleep(:timer.seconds(2)) end)
  end

  defp do_create_topics(client, tp_list) do
    cb_ref = make_ref()
    Klife.PubSub.subscribe({:metadata_updated, client}, cb_ref)

    content = %{
      topics:
        Enum.map(tp_list, fn tp_map ->
          %{
            name: tp_map.name,
            num_partitions: tp_map[:partitions] || 3,
            replication_factor: 2,
            assignments: [],
            configs: []
          }
        end),
      timeout_ms: 15_000,
      validate_only: false
    }

    {:ok, %{content: %{topics: t_resp}}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.CreateTopics,
        client,
        :controller,
        content
      )

    if Enum.any?(t_resp, fn t -> t.error_code not in [0, 36] end) do
      raise "Unexpected error creating topic #{t_resp}"
    end

    receive do
      {{:metadata_updated, ^client}, _event_data, ^cb_ref} ->
        :ok
    after
      60_000 ->
        {:error, :timeout}
    end

    :ok
  end

  def make_fetch_req(client, {t, p, o}, opts \\ []) do
    {:ok,
     %{
       topic_id: t_id,
       leader_id: broker
     }} = Klife.MetadataCache.get_metadata(client, t, p)

    data = %{
      replica_id: opts[:replica_id] || -1,
      max_wait_ms: opts[:max_wait_ms] || 1000,
      min_bytes: opts[:min_bytes] || 1,
      max_bytes: opts[:max_bytes] || 100_000,
      isolation_level:
        case Keyword.get(opts, :isolation_level, :committed) do
          :committed -> 1
          :uncommitted -> 0
        end,
      session_id: opts[:session_id] || 0,
      session_epoch: opts[:session_epoch] || 0,
      topics: [
        %{
          topic_id: t_id,
          partitions: [
            %{
              partition: p,
              current_leader_epoch: opts[:current_leader_epoch] || -1,
              fetch_offset: o,
              last_fetched_epoch: opts[:last_fetched_epoch] || -1,
              log_start_offset: opts[:log_start_offset] || -1,
              partition_max_bytes: opts[:max_bytes] || 100_000
            }
          ]
        }
      ],
      forgotten_topics_data: [],
      rack_id: opts[:rack_id] || ""
    }

    headers = %{
      client_id: opts[:client_id] || nil
    }

    Broker.send_message(
      M.Fetch,
      client,
      broker,
      data,
      headers
    )
  end
end
