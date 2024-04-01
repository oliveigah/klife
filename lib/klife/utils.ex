defmodule Klife.Utils do
  # TODO: Everything that is in here must be moved to a proper place
  def wait_connection!(cluster_name, timeout \\ :timer.seconds(5)) do
    deadline = System.monotonic_time() + System.convert_time_unit(timeout, :millisecond, :native)
    do_wait_connection!(cluster_name, deadline)
  end

  defp do_wait_connection!(cluster_name, deadline) do
    if System.monotonic_time() <= deadline do
      case :persistent_term.get({:known_brokers_ids, cluster_name}, :not_found) do
        :not_found ->
          Process.sleep(50)
          do_wait_connection!(cluster_name, deadline)

        data ->
          data
      end
    else
      raise "timeout while waiting for broker connection"
    end
  end

  # TODO: Refactor and think about topic auto creation feature
  # right now there is a bug when the Connection system intialize before
  # the topic are created, thats why we need to create a connection from
  # scratch here. Must solve it later.
  def create_topics!() do
    :klife
    |> Application.fetch_env!(:clusters)
    |> Enum.map(fn cluster_opts ->
      socker_opts = cluster_opts[:connection][:socket_opts]

      {:ok, conn} =
        Klife.Connection.new(
          cluster_opts[:connection][:bootstrap_servers] |> List.first(),
          socker_opts
        )

      {:ok, %{brokers: brokers_list, controller: controller_id}} =
        Klife.Connection.Controller.get_cluster_info(conn)

      {_id, url} = Enum.find(brokers_list, fn {id, _} -> id == controller_id end)

      {:ok, new_conn} = Klife.Connection.new(url, socker_opts)

      topics_input =
        Enum.map(cluster_opts[:topics], fn input ->
          %{
            name: input[:name],
            num_partitions: input[:num_partitions] || 12,
            replication_factor: input[:replication_factor] || 2,
            assignments: [],
            configs: []
          }
        end)

      :ok =
        %{
          content: %{
            topics: topics_input,
            timeout_ms: 15_000
          },
          headers: %{correlation_id: 123}
        }
        |> KlifeProtocol.Messages.CreateTopics.serialize_request(0)
        |> Klife.Connection.write(new_conn)

      {:ok, received_data} = Klife.Connection.read(new_conn)

      KlifeProtocol.Messages.CreateTopics.deserialize_response(received_data, 0)
      |> case do
        {:ok, %{content: content}} ->
          case Enum.filter(content.topics, fn e -> e.error_code not in [0, 36] end) do
            [] ->
              :ok

            err ->
              {:error, err}
          end

        err ->
          raise "
            Unexpected error while creating topics:

            #{inspect(err)}
            "
      end
    end)
    |> Enum.all?(fn e -> e == :ok end)
    |> case do
      true ->
        :ok

      false ->
        :error
    end
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
end
