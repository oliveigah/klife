defmodule Klife.Utils do
  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages

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

  def create_topics!(topics, cluster_name) do
    topics_input =
      Enum.map(topics, fn input ->
        %{
          name: input[:name],
          num_partitions: 3,
          replication_factor: 2,
          assignments: [],
          configs: []
        }
      end)

    content = %{
      topics: topics_input,
      timeout_ms: 5_000
    }

    result =
      Broker.send_sync(
        Messages.CreateTopics,
        cluster_name,
        :controller,
        content,
        %{client_id: "klife.topic_creation.#{cluster_name}"}
      )

    case result do
      {:ok, %{content: content}} ->
        case Enum.filter(content.topics, fn e -> e.error_code not in [0, 36] end) do
          [] ->
            :ok

          err ->
            raise "
          Error while creating topics:

          #{inspect(err)}
          "
        end

      err ->
        raise "
        Unexpected error while creating topics:

        #{inspect(err)}
        "
    end
  end
end
