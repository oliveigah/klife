defmodule Klife.Producer.HandoffTest do
  use ExUnit.Case

  import Klife.ProcessRegistry, only: [registry_lookup: 1]

  alias Klife.Connection.Broker
  alias Klife.MetadataCache
  alias Klife.Producer
  alias Klife.Producer.Batcher
  alias Klife.Producer.Dispatcher
  alias Klife.Record
  alias Klife.TestUtils
  alias KlifeProtocol.Messages, as: M

  # The leader handoff moves a partition's epoch and next sequence from the
  # old leader's batcher to the new one. That only works if the new leader
  # accepts the same epoch with the next sequence, and recognizes a resent
  # batch that was already appended: it answers success with the original
  # offset, without appending it again.
  @tag capture_log: true
  test "a new partition leader continues the producer's sequence" do
    topic = new_topic(1)

    content = %{transactional_id: nil, transaction_timeout_ms: 0}

    {p_id, epoch} =
      Klife.Helpers.with_timeout!(
        fn ->
          case Broker.send_message(M.InitProducerId, MyClient, :any, content) do
            {:ok, %{content: %{error_code: 0, producer_id: p_id, producer_epoch: epoch}}} ->
              {p_id, epoch}

            # The coordinator may still be loading after a broker restart
            _other ->
              :retry
          end
        end,
        :timer.seconds(30)
      )

    old_leader = MetadataCache.get_metadata_attribute(MyClient, topic, 0, :leader_id)

    first = batch_data(p_id, epoch, 0, 3)
    assert {0, offset} = raw_produce(old_leader, topic, 0, first)

    {^old_leader, new_leader} = TestUtils.move_leader(MyClient, topic, 0)

    # Uncertain resend: the batch was appended before the move
    assert {0, ^offset} = raw_produce(new_leader, topic, 0, first)

    assert {0, next_offset} = raw_produce(new_leader, topic, 0, batch_data(p_id, epoch, 3, 2))
    assert next_offset == offset + 3
  end

  test "popped partitions are no longer answered or retried by their dispatcher" do
    topic = new_topic(6)

    {broker_id, [p0, p1 | _]} = shared_leader(topic, 6)

    pconfig = %Producer{
      client_name: MyClient,
      name: :"pop_test_#{System.unique_integer([:positive])}",
      client_id: "pop_test",
      connection: :klife_default_connection,
      acks: :all,
      request_timeout_ms: 5_000,
      delivery_timeout_ms: 30_000,
      retry_backoff_ms: 100
    }

    {:ok, dispatcher} =
      Dispatcher.start_link(
        producer_config: pconfig,
        broker_id: broker_id,
        batcher_id: 0,
        batcher_pid: self()
      )

    produce_ref = make_ref()

    request = fn req_ref, partitions_data ->
      %Dispatcher.Request{
        producer_config: pconfig,
        request_ref: req_ref,
        base_time: System.monotonic_time(:millisecond),
        data_to_send: Map.new(partitions_data, fn {p, data} -> {{topic, p}, data} end),
        delivery_confirmation_pids:
          Map.new(partitions_data, fn {p, _data} ->
            {{topic, p}, [{self(), produce_ref, 0, p}]}
          end),
        records_map: %{}
      }
    end

    small = batch_data(-1, -1, -1, 1)
    # Over the broker's 1MB default: refused with a non retryable error
    too_large = put_in(small, [:records, Access.at(0), :value], :rand.bytes(1_500_000))

    # Popped from an in-flight request: the rest of it still completes, and
    # the broker's error for the popped partition is not acted on
    mixed = make_ref()
    :ok = Dispatcher.dispatch(dispatcher, request.(mixed, %{p0 => too_large, p1 => small}))

    assert [%{tp: {^topic, ^p0}, waiting_pids: [{_pid, ^produce_ref, 0, ^p0}]}] =
             Dispatcher.pop_partitions(dispatcher, MapSet.new([{topic, p0}]))

    assert_receive {:klife_produce, ^produce_ref, {:ok, _offset}, ^p1}, 5_000
    assert_receive {:complete_dispatch, ^mixed}
    refute_received {:bump_epoch, _tps}

    # Popped whole: completed at once, its response and retries ignored
    whole = make_ref()
    :ok = Dispatcher.dispatch(dispatcher, request.(whole, %{p0 => small}))

    assert [%{tp: {^topic, ^p0}}] =
             Dispatcher.pop_partitions(dispatcher, MapSet.new([{topic, p0}]))

    assert_receive {:complete_dispatch, ^whole}

    send(dispatcher, {:dispatch, whole})
    send(dispatcher, {:async_broker_response, whole, :timeout})

    refute_receive {:klife_produce, ^produce_ref, _resp, _idx}, 1_000
    refute_received {:complete_dispatch, _ref}
    assert %Dispatcher{requests: requests} = :sys.get_state(dispatcher)
    assert requests == %{}

    GenServer.stop(dispatcher)
  end

  @tag capture_log: true
  test "a moved partition's pending records reach its new leader in order" do
    # Its batches close at 5000 bytes, so these records take one each
    producer = :async_test_producer
    topic = new_topic(6)

    # Two partitions sharing a leader share its batcher: p moves, q stays
    {_leader, [p, q | _]} = shared_leader(topic, 6)

    rec = fn partition, key ->
      %Record{key: key, value: :binary.copy("v", 3_000), topic: topic, partition: partition}
    end

    test_pid = self()
    opts = [producer: producer, callback: fn resp -> send(test_pid, {:async_resp, resp}) end]

    assert {:ok, %Record{offset: first}} = MyClient.produce(rec.(p, "first"), opts)
    assert {:ok, %Record{offset: q_first}} = MyClient.produce(rec.(q, "q first"), opts)

    {old_version, leader_map} = Producer.get_producer_leader_map(MyClient, producer)
    {source_broker, batcher_id} = source = Map.fetch!(leader_map, {topic, p})
    source_pid = batcher_pid(producer, source)
    [{producer_pid, _}] = registry_lookup({Producer, MyClient, producer})
    assert {epoch, ^source_pid} = producer_epoch(producer_pid, topic, p)

    # Held back, the Producer does not follow the move: the next record
    # reaches the old leader, which refuses it, and waits for a retry
    suspend(producer_pid)
    {^source_broker, new_leader} = TestUtils.move_leader(MyClient, topic, p)
    retrying = Task.async(fn -> MyClient.produce(rec.(p, "retrying"), opts) end)

    %Batcher{dispatcher_pid: dispatcher} = :sys.get_state(source_pid).user_state

    wait_until(fn ->
      match?([%{in_flight: false}], Map.values(:sys.get_state(dispatcher).requests))
    end)

    # Queued and current batches of the source when it gets the transfer,
    # one of them for q
    suspend(source_pid)
    :ok = MyClient.produce_async(rec.(p, "queued"), opts)
    :ok = MyClient.produce_async(rec.(q, "q queued"), opts)
    :ok = MyClient.produce_async(rec.(p, "current"), opts)

    :sys.resume(producer_pid)

    wait_until(fn ->
      match?({_version, {^new_leader, _}}, producer_leader(producer, topic, p))
    end)

    # Read from the new producer leader: held until the transfer
    {_version, dest} = producer_leader(producer, topic, p)
    dest_pid = batcher_pid(producer, dest)
    :ok = MyClient.produce_async(rec.(p, "held"), opts)

    wait_until(fn ->
      match?(%{{^topic, ^p} => {_ref, [_]}}, :sys.get_state(dest_pid).user_state.to_hold)
    end)

    :sys.resume(source_pid)

    # Read from the old producer leader after the transfer, by an async and a sync
    # caller, as the Producer would send them: forwarded
    late = fn key, callback ->
      %Record{
        rec.(p, key)
        | __estimated_size: 100,
          __batch_index: 1,
          __callback: callback,
          __arrival_ms: System.monotonic_time(:millisecond)
      }
    end

    late_async = late.("late async", opts[:callback])

    :ok =
      Batcher.produce_async(
        [late_async],
        MyClient,
        source_broker,
        producer,
        batcher_id,
        old_version
      )

    late_sync_ref = make_ref()
    late_sync = late.("late sync", {self(), late_sync_ref})

    assert {:ok, _delivery_timeout} =
             Batcher.produce(
               [late_sync],
               MyClient,
               source_broker,
               producer,
               batcher_id,
               old_version
             )

    assert {:ok, %Record{offset: retrying_offset}} = Task.await(retrying, 10_000)
    assert_receive {:klife_produce, ^late_sync_ref, {:ok, late_sync_offset}, 1}, 10_000
    offsets = receive_async_offsets(5)

    async_offsets = Enum.map(["queued", "current", "held", "late async"], &offsets[&1])

    assert [first, retrying_offset] ++ async_offsets ++ [late_sync_offset] ==
             Enum.to_list(first..(first + 6))

    assert :ok = TestUtils.assert_offset(MyClient, late_sync, late_sync_offset)

    assert offsets["q queued"] == q_first + 1

    # Same epoch, now the new batcher's, and nothing left at the source
    assert {^epoch, ^dest_pid} = producer_epoch(producer_pid, topic, p)
    refute Map.has_key?(:sys.get_state(source_pid).user_state.producer_epochs, {topic, p})
    assert :sys.get_state(dispatcher).requests == %{}
    assert Enum.all?(:sys.get_state(source_pid).in_flight_pool, &is_nil/1)

    for {key, offset} <- offsets do
      partition = if key == "q queued", do: q, else: p
      assert :ok = TestUtils.assert_offset(MyClient, rec.(partition, key), offset)
    end
  end

  @tag capture_log: true
  test "a handoff whose source dies is given up at once" do
    # Gives up on handoffs after 30 seconds
    producer = Klife.Client.default_producer_name()
    topic = new_topic(1)
    rec = fn value -> %Record{value: value, topic: topic, partition: 0} end
    test_pid = self()
    callback = fn resp -> send(test_pid, {:async_resp, resp}) end

    assert {:ok, %Record{offset: first}} = MyClient.produce(rec.("first"))

    {_version, source} = producer_leader(producer, topic, 0)
    source_pid = batcher_pid(producer, source)
    [{producer_pid, _}] = registry_lookup({Producer, MyClient, producer})
    assert {epoch, ^source_pid} = producer_epoch(producer_pid, topic, 0)

    suspend(source_pid)
    {_old, new_leader} = TestUtils.move_leader(MyClient, topic, 0)

    wait_until(fn ->
      match?({_version, {^new_leader, _}}, producer_leader(producer, topic, 0))
    end)

    {_version, dest} = producer_leader(producer, topic, 0)
    dest_pid = batcher_pid(producer, dest)
    :ok = MyClient.produce_async(rec.("held"), callback: callback)

    wait_until(fn ->
      match?(%{{^topic, 0} => {_ref, [_]}}, :sys.get_state(dest_pid).user_state.to_hold)
    end)

    Process.exit(source_pid, :kill)

    # Released, as for a new partition, long before the timeout
    assert_receive {:async_resp, {:ok, %Record{value: "held", offset: offset}}}, 5_000
    assert offset == first + 1
    new_epoch = epoch + 1
    assert {^new_epoch, ^dest_pid} = producer_epoch(producer_pid, topic, 0)
  end

  @tag capture_log: true
  test "a bump the source still owes is done before it hands off" do
    producer = Klife.Client.default_producer_name()
    topic = new_topic(1)
    rec = fn value -> %Record{value: value, topic: topic, partition: 0} end
    test_pid = self()
    callback = fn resp -> send(test_pid, {:async_resp, resp}) end

    assert {:ok, %Record{offset: first}} = MyClient.produce(rec.("first"))

    {_version, source} = producer_leader(producer, topic, 0)
    source_pid = batcher_pid(producer, source)
    [{producer_pid, _}] = registry_lookup({Producer, MyClient, producer})
    assert {epoch, ^source_pid} = producer_epoch(producer_pid, topic, 0)

    suspend(source_pid)
    :ok = MyClient.produce_async(rec.("queued"), callback: callback)
    {_old, new_leader} = TestUtils.move_leader(MyClient, topic, 0)

    wait_until(fn ->
      match?({_version, {^new_leader, _}}, producer_leader(producer, topic, 0))
    end)

    # As its dispatcher does after a non retryable error
    send(source_pid, {:bump_epoch, [{topic, 0}]})
    :sys.resume(source_pid)

    # Queued under the new epoch, which the new batcher goes on with
    assert_receive {:async_resp, {:ok, %Record{value: "queued", offset: offset}}}, 10_000
    assert offset == first + 1
    {_version, dest} = producer_leader(producer, topic, 0)
    dest_pid = batcher_pid(producer, dest)
    new_epoch = epoch + 1
    assert {^new_epoch, ^dest_pid} = producer_epoch(producer_pid, topic, 0)
  end

  @tag capture_log: true
  test "a partition that moves again during its handoff is handed off again after it" do
    producer = Klife.Client.default_producer_name()
    topic = new_topic(1)
    rec = fn value -> %Record{value: value, topic: topic, partition: 0} end
    test_pid = self()
    callback = fn resp -> send(test_pid, {:async_resp, resp}) end

    assert {:ok, %Record{offset: first}} = MyClient.produce(rec.("first"))

    {_version, {source_broker, _} = source} = producer_leader(producer, topic, 0)
    source_pid = batcher_pid(producer, source)
    [{producer_pid, _}] = registry_lookup({Producer, MyClient, producer})
    assert {epoch, ^source_pid} = producer_epoch(producer_pid, topic, 0)

    # The first handoff waits for the source
    suspend(source_pid)
    {^source_broker, new_leader} = TestUtils.move_leader(MyClient, topic, 0)

    wait_until(fn ->
      match?({_version, {^new_leader, _}}, producer_leader(producer, topic, 0))
    end)

    {_version, dest} = producer_leader(producer, topic, 0)
    dest_pid = batcher_pid(producer, dest)
    :ok = MyClient.produce_async(rec.("held"), callback: callback)

    wait_until(fn ->
      match?(%{{^topic, 0} => {_ref, [_]}}, :sys.get_state(dest_pid).user_state.to_hold)
    end)

    # Back to the source's broker. Once the cache is done with the check
    # that saw it, the Producer has the event, and handles it meanwhile.
    {^new_leader, ^source_broker} = TestUtils.move_leader(MyClient, topic, 0)
    [{cache_pid, _}] = registry_lookup({MetadataCache, MyClient})
    :sys.get_state(cache_pid)
    :sys.get_state(producer_pid)
    assert {_version, ^dest} = producer_leader(producer, topic, 0)

    :sys.resume(source_pid)

    assert_receive {:async_resp, {:ok, %Record{value: "held", offset: offset}}}, 10_000
    assert offset == first + 1

    wait_until(fn ->
      match?({_version, {^source_broker, _}}, producer_leader(producer, topic, 0))
    end)

    assert {:ok, %Record{offset: after_offset}} = MyClient.produce(rec.("after"))
    assert after_offset == first + 2
    assert {^epoch, ^source_pid} = producer_epoch(producer_pid, topic, 0)
  end

  # Claiming the moved partition with a new epoch would make the
  # transaction's next write fail with INVALID_PRODUCER_EPOCH (47)
  @tag capture_log: true
  test "a transaction produces to a partition whose leader moved after the previous one" do
    topic = new_topic(1)
    rec = fn value -> %Record{value: value, topic: topic, partition: 0} end

    txn = fn value ->
      MyClient.transaction(fn -> {:ok, MyClient.produce(rec.(value))} end,
        pool_name: :my_test_pool_1
      )
    end

    assert {:ok, {:ok, %Record{}}} = txn.("before")
    TestUtils.move_leader(MyClient, topic, 0)
    assert {:ok, {:ok, %Record{offset: offset}}} = txn.("after")

    # Commit markers are written asynchronously
    wait_until(fn ->
      :ok ==
        TestUtils.assert_offset(MyClient, rec.("after"), offset,
          txn_status: :committed,
          isolation: :committed
        )
    end)
  end

  @tag capture_log: true
  test "a handoff whose source does not answer is given up after the request timeout" do
    # Its request timeout is 2 seconds
    producer = :handoff_test_producer
    topic = new_topic(1)
    other_topic = new_topic(3)
    rec = fn topic, value -> %Record{value: value, topic: topic, partition: 0} end
    test_pid = self()
    callback = fn resp -> send(test_pid, {:async_resp, resp}) end

    assert {:ok, %Record{}} = MyClient.produce(rec.(topic, "first"), producer: producer)

    {_version, {source_broker, _} = source} = producer_leader(producer, topic, 0)
    source_pid = batcher_pid(producer, source)

    other =
      Enum.find_value(0..2, fn p ->
        leader = MetadataCache.get_metadata_attribute(MyClient, other_topic, p, :leader_id)
        if leader != source_broker, do: %Record{value: "other", topic: other_topic, partition: p}
      end)

    [{producer_pid, _}] = registry_lookup({Producer, MyClient, producer})
    assert {epoch, ^source_pid} = producer_epoch(producer_pid, topic, 0)

    suspend(source_pid)
    :ok = MyClient.produce_async(rec.(topic, "stuck"), producer: producer, callback: callback)
    {_old, new_leader} = TestUtils.move_leader(MyClient, topic, 0)

    wait_until(fn ->
      match?({_version, {^new_leader, _}}, producer_leader(producer, topic, 0))
    end)

    # A new partition still gets its epoch while the transfer waits
    assert {:ok, %Record{}} = MyClient.produce(other, producer: producer)

    # Held by the new batcher until the handoff is given up, then claimed
    # with a new epoch
    {elapsed_us, held} =
      :timer.tc(fn -> MyClient.produce(rec.(topic, "held"), producer: producer) end)

    assert {:ok, %Record{}} = held
    assert elapsed_us < :timer.seconds(5) * 1000
    {_version, dest} = producer_leader(producer, topic, 0)
    dest_pid = batcher_pid(producer, dest)
    new_epoch = epoch + 1
    assert {^new_epoch, ^dest_pid} = producer_epoch(producer_pid, topic, 0)

    # The transfer arrives too late: its records fail, and the source does
    # not claim the partition back
    :sys.resume(source_pid)

    assert_receive {:async_resp, {:error, %Record{value: "stuck", error_code: :handoff_expired}}},
                   5_000

    assert {:ok, %Record{}} = MyClient.produce(rec.(topic, "after"), producer: producer)
    assert {^new_epoch, ^dest_pid} = producer_epoch(producer_pid, topic, 0)
    refute Map.has_key?(:sys.get_state(source_pid).user_state.producer_epochs, {topic, 0})
  end

  test "a leader move changes the batcher of the moved partition only" do
    # 32 batchers per broker
    producer = :async_benchmark_producer
    topic = new_topic(6)

    snapshot = fn ->
      for p <- 0..5, into: %{} do
        leader = MetadataCache.get_metadata_attribute(MyClient, topic, p, :leader_id)
        {_version, producer_leader} = producer_leader(producer, topic, p)
        {p, {leader, producer_leader}}
      end
    end

    before = snapshot.()
    {_old, new_leader} = TestUtils.move_leader(MyClient, topic, 0)

    wait_until(fn ->
      match?({_version, {^new_leader, _}}, producer_leader(producer, topic, 0))
    end)

    later = snapshot.()

    for p <- 1..5, elem(before[p], 0) == elem(later[p], 0) do
      assert before[p] == later[p]
    end
  end

  defp new_topic(partitions) do
    # Unique across runs too, the cluster may outlive them
    topic =
      "handoff_topic_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"

    :ok = Klife.Utils.create_topics(MyClient, [%{name: topic, partitions: partitions}])
    topic
  end

  # Partitions of the topic led by the same broker, once all of them are known
  defp shared_leader(topic, partitions) do
    wait_until(fn ->
      MyClient
      |> MetadataCache.get_all_metadata()
      |> Enum.count(&(&1.topic_name == topic)) == partitions
    end)

    # More partitions than brokers: some broker leads two of them
    MyClient
    |> MetadataCache.get_all_metadata()
    |> Enum.filter(&(&1.topic_name == topic))
    |> Enum.group_by(& &1.leader_id, & &1.partition_idx)
    |> Enum.find(fn {_leader, parts} -> length(parts) >= 2 end)
  end

  # Resumed at the end even if the test fails, not to stall the next ones
  defp suspend(pid) do
    :ok = :sys.suspend(pid)

    on_exit(fn ->
      try do
        :sys.resume(pid)
      catch
        :exit, _dead -> :ok
      end
    end)
  end

  defp producer_leader(producer, topic, partition),
    do: Producer.get_producer_leader(MyClient, producer, topic, partition)

  defp batcher_pid(producer, {broker_id, batcher_id}) do
    [{pid, _}] = registry_lookup({Batcher, MyClient, broker_id, producer, batcher_id})
    pid
  end

  defp producer_epoch(producer_pid, topic, partition),
    do: :sys.get_state(producer_pid).epochs[{topic, partition}]

  defp receive_async_offsets(count) do
    for _ <- 1..count, into: %{} do
      assert_receive {:async_resp, {:ok, %Record{key: key, offset: offset}}}, 10_000
      {key, offset}
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end

  defp batch_data(p_id, epoch, base_seq, count) do
    now = System.system_time(:millisecond)

    %{
      base_offset: 0,
      partition_leader_epoch: -1,
      magic: 2,
      attributes: 0,
      last_offset_delta: count - 1,
      base_timestamp: now,
      max_timestamp: now,
      producer_id: p_id,
      producer_epoch: epoch,
      base_sequence: base_seq,
      records:
        for i <- (count - 1)..0//-1 do
          %{
            attributes: 0,
            timestamp_delta: 0,
            offset_delta: i,
            key: nil,
            value: "seq #{base_seq + i}",
            headers: []
          }
        end,
      records_length: count
    }
  end

  # Batches are kept newest record first until sent, as the batcher does
  defp raw_produce(broker_id, topic, partition, batch) do
    content = %{
      transactional_id: nil,
      acks: -1,
      timeout_ms: 5_000,
      topic_data: [
        %{
          name: topic,
          partition_data: [
            %{index: partition, records: %{batch | records: Enum.reverse(batch.records)}}
          ]
        }
      ]
    }

    {:ok, %{content: %{responses: [%{partition_responses: [resp]}]}}} =
      Broker.send_message(M.Produce, MyClient, broker_id, content)

    {resp.error_code, resp.base_offset}
  end
end
