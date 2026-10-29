defmodule Klife.ReleaseBenchmark.Client do
  use Klife.Client, otp_app: :klife_release_benchmark
end

defmodule Klife.ReleaseBenchmark.Consumer do
  use Klife.Consumer.ConsumerGroup, client: Klife.ReleaseBenchmark.Client
  alias Klife.ReleaseBenchmark.Stats

  @impl true
  def handle_consumer_start(topic, partition, group) do
    config = :persistent_term.get({__MODULE__, group})

    if config.mode == :catchup do
      # This callback runs before polling: include every fetch and decode in recovery.
      :ets.insert_new(config.stats, {:started_at, System.monotonic_time(:microsecond)})
    else
      send(config.owner, {:ready, group, topic, partition})
    end

    :ok
  end

  @impl true
  def handle_record_batch(topic, partition, group, records) do
    config = :persistent_term.get({__MODULE__, group})

    now = System.monotonic_time(:microsecond)
    # Kafka offsets must advance even when callbacks span multiple batches.
    key = {:last_offset, topic, partition}

    previous =
      case :ets.lookup(config.stats, key) do
        [{_, offset}] -> offset
        [] -> -1
      end

    last =
      Enum.reduce(records, previous, fn rec, previous ->
        if rec.offset <= previous, do: raise("Duplicate/out-of-order benchmark delivery")
        rec.offset
      end)

    :ets.insert(config.stats, {key, last})

    case config.mode do
      :catchup ->
        Stats.add(config.stats, :consumed, length(records))

      :latency ->
        for %{value: <<tag::binary-size(16), scheduled::signed-64, _::binary>>} <- records,
            tag == config.tag do
          Stats.observe(config.stats, :e2e, now - scheduled)
          Stats.add(config.stats, :consumed, 1)
        end
    end

    :commit
  end
end

defmodule Klife.ReleaseBenchmark.Workload do
  alias Klife.ReleaseBenchmark.{Client, Consumer, Stats}
  @timeout 120_000

  def catchup(c, %{config: config, topics: topics, filler: filler, settings: settings}) do
    seed_key = {:seeded, c.level}

    unless Process.get(seed_key, false) do
      seed(topics, config.records_per_partition, filler)
      Process.put(seed_key, true)
    end

    if config.warmup > 0, do: drain(c, config, topics, settings)
    drain(c, config, topics, settings)
  end

  def latency(c, %{config: config, topics: topics, filler: filler, settings: settings}) do
    table = Stats.new()
    group = new_group()
    register_group(group, table, :latency, <<0::128>>)
    {:ok, pid} = start_group(c, group, topics, settings, :latest)

    try do
      wait_ready(group, Enum.sum(Enum.map(topics, &elem(&1, 1))), deadline())

      if config.warmup > 0 do
        phase(c, config.warmup, topics, filler, table, group, config.record_bytes)
        :ets.delete_all_objects(table)
      end

      phase(c, config.seconds, topics, filler, table, group, config.record_bytes)
    after
      GenServer.stop(pid, :normal, @timeout)
      :persistent_term.erase({Consumer, group})
      :ets.delete(table)
    end
  end

  def throughput(c, %{config: config, topics: topics, filler: filler}) do
    if config.warmup > 0, do: produce(c, config.warmup, topics, filler, config.record_bytes)
    produce(c, config.seconds, topics, filler, config.record_bytes)
  end

  def warmup_partitions(topics, filler) do
    # Producer topics are also used by latency groups, which start at :latest.
    records =
      for {topic, partitions} <- topics,
          p <- 0..(partitions - 1),
          do: record(topic, p, <<0::128>>, 0, filler)

    records |> Enum.chunk_every(100) |> Enum.each(&verify_batch!(Client.produce_batch(&1)))
  end

  defp produce(c, seconds, topics, filler, bytes) do
    table = Stats.new()
    pool = pool(topics, filler)

    workers = c.callers

    tasks =
      for worker <- 1..workers do
        Task.async(fn ->
          receive do
            {:go, stop} ->
              if c.operation == :async,
                do: async_loop(pool, c.window, stop, table),
                else:
                  sync_loop(
                    pool,
                    worker * 17,
                    if(c.operation == :batch, do: c.batch, else: 1),
                    c.operation,
                    stop,
                    table
                  )
          end
        end)
      end

    start = now()
    Enum.each(tasks, &send(&1.pid, {:go, start + seconds * 1_000_000}))

    try do
      Task.await_many(tasks, seconds * 1_000 + @timeout)
      result(table, start, bytes)
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      :ets.delete(table)
    end
  end

  defp sync_loop(pool, index, batch, operation, stop, table) do
    if now() < stop do
      records = for n <- index..(index + batch - 1), do: elem(pool, rem(n, tuple_size(pool)))
      start = now()

      case operation do
        :single -> verify_batch!([Client.produce(hd(records))])
        :batch -> verify_batch!(Client.produce_batch(records))
      end

      Stats.observe(table, :ack, now() - start)
      Stats.add(table, :acked, batch)
      sync_loop(pool, index + batch, batch, operation, stop, table)
    end
  end

  defp async_loop(pool, window, stop, table) do
    ref = make_ref()
    pending = Enum.reduce(1..window, %{}, fn n, pending -> submit(pool, n, ref, pending) end)

    await_async(
      pool,
      ref,
      pending,
      window + 1,
      stop,
      table,
      deadline() + ceil(max(0, stop - now()) / 1_000)
    )
  end

  defp submit(pool, n, ref, pending, scheduled \\ nil) do
    owner = self()
    start = scheduled || now()

    :ok =
      Client.produce_async(elem(pool, rem(n, tuple_size(pool))),
        callback: fn result ->
          send(owner, {ref, n, result, now()})
        end
      )

    Map.put(pending, n, start)
  end

  defp await_async(_pool, _ref, pending, _n, _stop, _table, _deadline)
       when map_size(pending) == 0, do: :ok

  defp await_async(pool, ref, pending, n, stop, table, deadline) do
    receive do
      {^ref, id, {:ok, _}, finished} ->
        {start, pending} = Map.pop!(pending, id)
        Stats.observe(table, :ack, finished - start)
        Stats.add(table, :acked, 1)

        pending =
          if not is_nil(stop) and now() < stop, do: submit(pool, n, ref, pending), else: pending

        await_async(pool, ref, pending, n + 1, stop, table, deadline)

      {^ref, _, error, _} ->
        raise "Async produce failed: #{inspect(error)}"
    after
      remaining(deadline) ->
        raise "Timed out draining async records (#{map_size(pending)} outstanding)"
    end
  end

  defp phase(c, seconds, topics, filler, table, group, bytes) do
    tag = :crypto.strong_rand_bytes(16)
    register_group(group, table, :latency, tag)
    pool = pool(topics, filler, tag)
    start = now()
    rate = c.rate
    ref = make_ref()
    # Fixed schedule, independent of response speed. Never queue unlimited work.
    count = rate * seconds
    pending = paced(pool, table, ref, 0, count, rate, start, %{})
    await_async(pool, ref, pending, count, nil, table, deadline())
    acked = Stats.get(table, :acked)

    if acked + Stats.get(table, :dropped) != count,
      do: raise("Offered and completed record counts differ")

    wait_count(table, :consumed, acked, deadline())
    result(table, start, bytes)
  end

  defp paced(_pool, _table, _ref, count, count, _rate, _start, pending), do: pending

  defp paced(pool, table, ref, index, count, rate, start, pending) do
    scheduled = start + div(index * 1_000_000, rate)
    wait_until(scheduled)
    pending = collect_acks(ref, pending, table)

    pending =
      if map_size(pending) < 4_096 do
        Stats.observe(table, :dispatch, now() - scheduled)
        rec = elem(pool, rem(index, tuple_size(pool)))
        <<tag::binary-size(16), _::signed-64, filler::binary>> = rec.value
        pool = {%{rec | value: <<tag::binary, scheduled::signed-64, filler::binary>>}}
        submit(pool, index, ref, pending, scheduled)
      else
        Stats.add(table, :dropped, 1)
        pending
      end

    paced(pool, table, ref, index + 1, count, rate, start, pending)
  end

  defp collect_acks(ref, pending, table) do
    receive do
      {^ref, id, {:ok, _}, finished} ->
        {start, pending} = Map.pop!(pending, id)
        Stats.observe(table, :ack, finished - start)
        Stats.add(table, :acked, 1)
        collect_acks(ref, pending, table)

      {^ref, _, error, _} ->
        raise "Paced produce failed: #{inspect(error)}"
    after
      0 -> pending
    end
  end

  defp drain(c, config, topics, settings) do
    table = Stats.new()
    group = new_group()
    register_group(group, table, :catchup, nil)
    startup = now()
    {:ok, pid} = start_group(c, group, topics, settings, :earliest)

    try do
      count =
        Enum.sum(for {_, partitions} <- topics, do: partitions * config.records_per_partition)

      wait_count(table, :consumed, count, deadline())
      [{:started_at, start}] = :ets.lookup(table, :started_at)

      for {topic, partitions} <- topics, partition <- 0..(partitions - 1) do
        key = {:last_offset, topic, partition}

        unless :ets.lookup(table, key) == [{key, config.records_per_partition - 1}],
          do: raise("Incomplete partition: #{topic}:#{partition}")
      end

      delivered = result(table, start, config.record_bytes)
      coordinator = find_coordinator(group)
      :ok = wait_committed(group, coordinator, topics, config.records_per_partition, deadline())
      catchup_ms = (now() - start) / 1_000

      Map.merge(delivered, %{
        startup_ms: (start - startup) / 1_000,
        catchup_ms: catchup_ms,
        delivery_drain_ms: delivered.elapsed_s * 1_000,
        commit_drain_ms: catchup_ms - delivered.elapsed_s * 1_000,
        initial_lag_records: count,
        remaining_lag_records: 0
      })
    after
      GenServer.stop(pid, :normal, @timeout)
      :persistent_term.erase({Consumer, group})
      :ets.delete(table)
    end
  end

  defp find_coordinator(group) do
    {:ok, %{content: %{coordinators: [%{error_code: 0, node_id: id}]}}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.FindCoordinator,
        Client,
        :any,
        %{key_type: 0, coordinator_keys: [group]}
      )

    id
  end

  defp wait_committed(group, coordinator, topics, target, deadline) do
    request = %{
      groups: [
        %{
          group_id: group,
          member_id: nil,
          member_epoch: -1,
          topics:
            Enum.map(topics, fn {name, partitions} ->
              %{name: name, partition_indexes: Enum.to_list(0..(partitions - 1))}
            end)
        }
      ],
      require_stable: true
    }

    {:ok, %{content: %{groups: [%{error_code: 0, topics: response}]}}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.OffsetFetch,
        Client,
        coordinator,
        request
      )

    pending = Klife.ReleaseBenchmark.Scenarios.CatchupLag.remaining_lag(topics, target, response)

    cond do
      pending == 0 ->
        :ok

      remaining(deadline) == 0 ->
        raise "Catch-up left #{pending} records of committed lag"

      true ->
        Process.sleep(5)
        wait_committed(group, coordinator, topics, target, deadline)
    end
  end

  defp seed(topics, count, filler) do
    for({topic, partitions} <- topics, partition <- 0..(partitions - 1), do: {topic, partition})
    |> Task.async_stream(
      fn {topic, partition} ->
        rec = record(topic, partition, <<0::128>>, 0, filler)

        1..count
        |> Stream.map(fn _ -> rec end)
        |> Stream.chunk_every(100)
        |> Enum.each(&verify_batch!(Client.produce_batch(&1)))
      end,
      max_concurrency: 16,
      timeout: @timeout,
      ordered: false
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)
  end

  defp start_group(c, group, topics, settings, reset) do
    strategy =
      if c.strategy == :shared,
        do: {:shared, Client.get_default_fetcher()},
        else: {:exclusive, settings.fetcher}

    Consumer.start_link(
      group_name: group,
      fetch_strategy: strategy,
      topics:
        Enum.map(topics, fn {topic, _} ->
          Keyword.merge(settings.topic, name: topic, offset_reset_policy: reset)
        end)
    )
  end

  defp register_group(group, table, mode, tag),
    do:
      :persistent_term.put({Consumer, group}, %{owner: self(), stats: table, mode: mode, tag: tag})

  defp new_group, do: "klife-release-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
  defp wait_ready(_group, 0, _deadline), do: :ok

  defp wait_ready(group, count, deadline) do
    receive do
      {:ready, ^group, _, _} -> wait_ready(group, count - 1, deadline)
    after
      remaining(deadline) -> raise "Timed out waiting for consumer assignments"
    end
  end

  defp wait_count(table, key, count, deadline) do
    actual = Stats.get(table, key)

    cond do
      actual == count ->
        :ok

      actual > count ->
        raise "Duplicate benchmark deliveries: expected #{count}, got #{actual}"

      remaining(deadline) == 0 ->
        raise "Incomplete benchmark: expected #{count}, got #{actual}"

      true ->
        Process.sleep(1)
        wait_count(table, key, count, deadline)
    end
  end

  defp result(table, start, bytes) do
    elapsed = (now() - start) / 1_000_000
    count = max(Stats.get(table, :acked), Stats.get(table, :consumed))
    ack = Stats.percentiles(table, :ack)
    e2e = Stats.percentiles(table, :e2e)
    dropped = Stats.get(table, :dropped)

    %{
      records: count,
      elapsed_s: elapsed,
      records_s: count / elapsed,
      mib_s: count * bytes / elapsed / 1_048_576,
      ack_p50_ms: ack[50],
      ack_p95_ms: ack[95],
      ack_p99_ms: ack[99],
      e2e_p50_ms: e2e[50],
      e2e_p95_ms: e2e[95],
      e2e_p99_ms: e2e[99],
      dispatch_p99_ms: Stats.percentiles(table, :dispatch)[99],
      dropped: dropped,
      status: if(dropped == 0, do: :ok, else: :overloaded)
    }
  end

  defp verify_batch!(results) do
    Enum.each(results, fn
      {:ok, %Klife.Record{offset: offset}} when is_integer(offset) and offset >= 0 -> :ok
      other -> raise "Produce failed: #{inspect(other)}"
    end)
  end

  defp pool(topics, filler, tag \\ <<0::128>>) do
    for(
      {topic, partitions} <- topics,
      p <- 0..(partitions - 1),
      do: record(topic, p, tag, 0, filler)
    )
    |> List.to_tuple()
  end

  defp record(topic, partition, tag, scheduled, filler),
    do: %Klife.Record{
      topic: topic,
      partition: partition,
      key: <<0::400>>,
      value: <<tag::binary, scheduled::signed-64, filler::binary>>
    }

  defp now, do: System.monotonic_time(:microsecond)
  defp deadline, do: System.monotonic_time(:millisecond) + @timeout
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp wait_until(time) do
    delay = time - now()

    if delay > 0 do
      Process.sleep(ceil(delay / 1_000))
      wait_until(time)
    end
  end
end
