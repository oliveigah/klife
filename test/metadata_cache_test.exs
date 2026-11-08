defmodule Klife.MetadataCacheTest do
  use ExUnit.Case

  alias Klife.Record
  alias Klife.MetadataCache
  alias Klife.Connection.Controller, as: ConnController

  # The clients used here have periodic metadata checks disabled in practice
  # (10 minutes interval), so any cache heal observed after corrupting the
  # leader can only come from the reactive refresh triggered by broker errors.
  defp base_config() do
    [
      connection: [
        bootstrap_servers: ["localhost:19092", "localhost:29092"],
        ssl: false
      ],
      metadata_check_interval_ms: 600_000,
      topics: [[name: "test_no_batch_topic"]]
    ]
  end

  defp corrupt_leader!(client, topic, partition) do
    real_leader = MetadataCache.get_metadata_attribute(client, topic, partition, :leader_id)

    wrong_broker =
      client
      |> ConnController.get_known_brokers()
      |> Enum.find(fn b -> b != real_leader end)

    true = MetadataCache.update_metadata(client, topic, partition, :leader_id, wrong_broker)

    real_leader
  end

  defp wait_leader_heal(client, topic, partition, expected_leader, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_leader_heal(client, topic, partition, expected_leader, deadline)
  end

  defp do_wait_leader_heal(client, topic, partition, expected_leader, deadline) do
    case MetadataCache.get_metadata_attribute(client, topic, partition, :leader_id) do
      ^expected_leader ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_wait_leader_heal(client, topic, partition, expected_leader, deadline)
        else
          flunk(
            "cache leader for #{topic}:#{partition} is still #{other}, expected #{expected_leader}"
          )
        end
    end
  end

  defp wait_producer_leader(client, topic, partition, broker_id, attempts \\ 100) do
    producer = client.get_default_producer()

    case Klife.Producer.get_producer_leader(client, producer, topic, partition) do
      {_map_version, {^broker_id, _batcher_id}} ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(50)
        wait_producer_leader(client, topic, partition, broker_id, attempts - 1)

      other ->
        flunk("producer leader for #{topic}:#{partition} is still #{inspect(other)}")
    end
  end

  test "the metadata table outlives restarts of the cache" do
    client = Module.concat(__MODULE__, RestartClient)
    Application.put_env(:klife, client, base_config())

    defmodule RestartClient do
      use Klife.Client, otp_app: :klife
    end

    start_supervised!(client)

    topic = "test_no_batch_topic"
    assert {:ok, %{leader_id: leader}} = MetadataCache.get_metadata(client, topic, 0)

    [{pid, _}] = Klife.ProcessRegistry.registry_lookup({MetadataCache, client})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Readers never miss it, even before the cache is back
    assert {:ok, %{leader_id: ^leader}} = MetadataCache.get_metadata(client, topic, 0)

    assert [{new_pid, _}] = wait_restart(client, pid)
    assert new_pid != pid
    assert {:ok, %{leader_id: ^leader}} = MetadataCache.get_metadata(client, topic, 0)
  end

  defp wait_restart(client, old_pid, attempts \\ 100) do
    case Klife.ProcessRegistry.registry_lookup({MetadataCache, client}) do
      [{pid, _}] = found when pid != old_pid ->
        found

      _ when attempts > 0 ->
        Process.sleep(50)
        wait_restart(client, old_pid, attempts - 1)

      other ->
        other
    end
  end

  @tag capture_log: true
  test "produce errors against a stale leader trigger a metadata refresh" do
    # Module.concat prevents compile time resolution of the client module,
    # which is only defined at runtime when the test runs.
    client = Module.concat(__MODULE__, ProduceTriggerClient)
    Application.put_env(:klife, client, base_config())

    defmodule ProduceTriggerClient do
      use Klife.Client, otp_app: :klife
    end

    start_supervised!(client)

    topic = "test_no_batch_topic"
    partition = 6

    real_leader = corrupt_leader!(client, topic, partition)
    wrong_leader = MetadataCache.get_metadata_attribute(client, topic, partition, :leader_id)

    # The producer leaders follow the cache when it reports a change
    :ok = Klife.PubSub.publish({:metadata_updated, client}, %{})
    :ok = wait_producer_leader(client, topic, partition, wrong_leader)

    # Routed to the wrong broker, which answers with a stale metadata error.
    # Fire and forget: the delivery outcome is irrelevant here, only the
    # error driven refresh matters.
    :ok =
      client.produce_async(%Record{value: :rand.bytes(10), topic: topic, partition: partition})

    assert :ok = wait_leader_heal(client, topic, partition, real_leader)
  end

  @tag capture_log: true
  test "fetch errors against a stale leader trigger a metadata refresh" do
    # Module.concat prevents compile time resolution of the client module,
    # which is only defined at runtime when the test runs.
    client = Module.concat(__MODULE__, FetchTriggerClient)
    Application.put_env(:klife, client, base_config())

    defmodule FetchTriggerClient do
      use Klife.Client, otp_app: :klife
    end

    start_supervised!(client)

    topic = "test_no_batch_topic"
    partition = 6

    # Produced with the healthy cache so the offset is valid on the real leader.
    {:ok, %Record{offset: valid_offset}} =
      client.produce(%Record{value: :rand.bytes(10), topic: topic, partition: partition})

    real_leader = MetadataCache.get_metadata_attribute(client, topic, partition, :leader_id)

    wrong_brokers =
      client
      |> ConnController.get_known_brokers()
      |> Enum.reject(&(&1 == real_leader))

    # With replication factor 2 one of the wrong brokers may be a follower
    # that is able to serve reads. At least one of them must reply with a
    # stale metadata error, which is the trigger under test.
    #
    # :unexpected_resp happens when the broker replies NOT_LEADER_OR_FOLLOWER
    # with KIP-951 tagged fields that the protocol deserialization does not
    # support yet, which the dispatcher fails as a retryable error.
    error_code =
      Enum.find_value(wrong_brokers, fn wrong ->
        true = MetadataCache.update_metadata(client, topic, partition, :leader_id, wrong)

        case client.fetch(topic, partition, valid_offset) do
          {:error, ec} -> ec
          {:ok, _recs} -> nil
        end
      end)

    assert error_code in [3, 6, 100, 103, :unexpected_resp]

    assert :ok = wait_leader_heal(client, topic, partition, real_leader)
  end
end
