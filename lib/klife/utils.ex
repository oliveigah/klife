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
end
