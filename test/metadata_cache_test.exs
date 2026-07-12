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
