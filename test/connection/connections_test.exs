defmodule Klife.Connection.ConnectionsTest do
  use ExUnit.Case, async: false

  alias Klife.Record
  alias Klife.MetadataCache
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController

  defmodule TestGroup do
    use Klife.Consumer.ConsumerGroup, client: MyClient

    @impl true
    def handle_record_batch(_topic, _partition, _group_name, _records), do: :commit
  end

  # Send operations on the TCP connections of a connection so far, to every broker
  defp sent_count(conn_name) do
    for broker_id <- ConnController.get_known_brokers(MyClient),
        idx <- 0..(ConnController.get_connection_count(MyClient, conn_name) - 1),
        reduce: 0 do
      acc ->
        conn = Broker.get_connection(MyClient, conn_name, broker_id, idx)
        mod = if conn.ssl, do: :ssl, else: :inet
        {:ok, [send_cnt: count]} = mod.getstat(conn.socket, [:send_cnt])
        acc + count
    end
  end

  # The broker answers a TCP connection's requests in order, and holds a fetch until
  # records arrive or its max_wait_ms ends. MyClient has a single TCP connection per
  # broker on each connection, so this would fail if fetches and produces shared one
  test "a fetch waiting for records does not hold back produce requests to its broker" do
    topic = "test_no_batch_topic"

    {:ok, %Record{offset: offset}} =
      MyClient.produce(%Record{value: "v", topic: topic, partition: 0})

    leader = MetadataCache.get_metadata_attribute(MyClient, topic, 0, :leader_id)

    {other_topic, other_partition} =
      for t <- ["test_no_batch_topic", "my_topic_1", "my_topic_2", "my_topic_3"],
          p <- 0..2,
          {t, p} != {topic, 0},
          MetadataCache.get_metadata_attribute(MyClient, t, p, :leader_id) == leader do
        {t, p}
      end
      |> List.first()

    # No records past offset yet: the broker holds this fetch for its 3s max_wait_ms
    {:ok, _pid} = MyClient.fetch_async(topic, 0, offset + 1, fetcher: :long_poll_test_fetcher)
    Process.sleep(300)

    rec = %Record{value: "v", topic: other_topic, partition: other_partition}

    {elapsed_us, {:ok, %Record{}}} =
      :timer.tc(fn -> MyClient.produce(rec, producer: :klife_default_producer) end)

    assert elapsed_us < 1_500_000
    assert_receive {:klife_fetch_response, {^topic, 0, _}, {:ok, _}}, 5_000
  end

  test "producers, fetchers and consumer groups send over their configured connection" do
    before = sent_count(:test_producer_connection)
    rec = %Record{value: "v", topic: "my_topic_1"}
    {:ok, _} = MyClient.produce(rec, producer: :test_connection_producer)
    assert sent_count(:test_producer_connection) > before

    before = sent_count(:test_fetcher_connection)
    _ = MyClient.fetch("my_topic_1", 0, 0, fetcher: :test_connection_fetcher)
    assert sent_count(:test_fetcher_connection) > before

    # A group finds its coordinator before start_link returns
    before = sent_count(:test_group_connection)
    group_name = "connections_test_#{System.unique_integer([:positive])}"

    opts = [
      group_name: group_name,
      topics: [[name: "my_topic_1"]],
      connection: :test_group_connection
    ]

    start_supervised!({TestGroup, opts}, restart: :temporary)
    assert sent_count(:test_group_connection) > before
  end

  test "components refuse a connection the client does not have" do
    opts = [group_name: "connections_test", topics: [[name: "my_topic_1"]], connection: :unknown]

    assert_raise ArgumentError, ~r/unknown connection :unknown for client MyClient/, fn ->
      TestGroup.start_link(opts)
    end
  end
end
