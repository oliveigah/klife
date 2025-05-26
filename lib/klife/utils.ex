defmodule Klife.Utils do
  @moduledoc false
  # TODO: Everything that is in here must be moved to a proper place

  def get_brokers(client), do: :persistent_term.get({:known_brokers_ids, client})

  # TODO: Refactor and think about topic auto creation feature
  # right now there is a bug when the Connection system intialize before
  # the topic are created, thats why we need to create a connection from
  # scratch here. Must solve it later.
  def create_topics() do
    do_create_topics(System.monotonic_time())
  end

  defp do_create_topics(init_time) do
    case create_topics_call() do
      {:ok, res} ->
        {:ok, res}

      :error ->
        now = System.monotonic_time(:millisecond)

        if now - init_time > :timer.seconds(15) do
          raise "Timeout while creating topics"
        else
          do_create_topics(init_time)
        end
    end
  end

  defp create_topics_call() do
    client_opts = Application.fetch_env!(:klife, MyClient)

    conn_defaults =
      Klife.Connection.Controller.get_opts()
      |> Keyword.take([:connect_opts, :socket_opts])
      |> Enum.map(fn {k, opt} -> {k, opt[:default] || []} end)
      |> Map.new()

    ssl = client_opts[:connection][:ssl]

    connect_opts =
      Keyword.merge(conn_defaults.connect_opts, client_opts[:connection][:connect_opts] || [])

    socket_opts =
      Keyword.merge(conn_defaults.socket_opts, client_opts[:connection][:socket_opts] || [])

    sasl_opts =
      case client_opts[:connection][:sasl_opts] || [] do
        [] ->
          []

        base_opts ->
          Keyword.merge(base_opts, auth_vsn: 2, handshake_vsn: 1)
      end

    {:ok, conn} =
      Klife.Connection.new(
        client_opts[:connection][:bootstrap_servers] |> List.first(),
        ssl,
        connect_opts,
        socket_opts,
        sasl_opts
      )

    {:ok, %{brokers: brokers_list, controller: controller_id}} =
      Klife.Connection.Controller.get_cluster_info(conn)

    {_id, url} = Enum.find(brokers_list, fn {id, _} -> id == controller_id end)

    {:ok, new_conn} = Klife.Connection.new(url, ssl, connect_opts, socket_opts, sasl_opts)

    topics_input =
      Enum.map(client_opts[:topics], fn input ->
        %{
          name: input[:name],
          num_partitions: input[:num_partitions] || 30,
          replication_factor: input[:replication_factor] || 2,
          assignments: [],
          configs: []
        }
      end)

    non_configured_topics = [
      %{
        name: "non_configured_topic_1",
        num_partitions: 10,
        replication_factor: 3,
        assignments: [],
        configs: []
      },
      %{
        name: "my_consumer_topic",
        num_partitions: 4,
        replication_factor: 3,
        assignments: [],
        configs: []
      },
      %{
        name: "my_consumer_topic_2",
        num_partitions: 2,
        replication_factor: 3,
        assignments: [],
        configs: []
      }
    ]

    topics_input = topics_input ++ non_configured_topics

    :ok =
      %{
        content: %{
          topics: topics_input,
          timeout_ms: 15_000,
          validate_only: false
        },
        headers: %{correlation_id: 123}
      }
      |> KlifeProtocol.Messages.CreateTopics.serialize_request(2)
      |> Klife.Connection.write(new_conn)

    {:ok, received_data} = Klife.Connection.read(new_conn)

    KlifeProtocol.Messages.CreateTopics.deserialize_response(received_data, 2)
    |> case do
      {:ok, %{content: content}} ->
        case Enum.filter(content.topics, fn e -> e.error_code not in [0, 36] end) do
          [] ->
            {:ok, Enum.map(content.topics, fn %{name: topic} -> topic end)}

          err ->
            {:error, err}
        end

      err ->
        raise "
            Unexpected error while creating topics:

            #{inspect(err)}
            "
    end
  end
end
