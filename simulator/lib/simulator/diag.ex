defmodule Simulator.Diag do
  @moduledoc false
  # Snapshots of klife's connections while a record waits too long, to diagnose stalls.
  # Written to the simulation directory as diag-<kind>-<n>.txt, at most @max_dumps per kind,
  # @interval_ms apart.

  @max_dumps 4
  @interval_ms 5_000
  @call_timeout 3_000
  @revoke_wait_ms 6_000

  @revoked ~r/^Assignment revoked (\S+):(\d+) for consumer group (\S+) running module (\S+)$/

  # Dumps when a consumer is still alive @revoke_wait_ms after its partition was revoked
  def install do
    for kind <- [:lag, :revoke], do: :persistent_term.put({__MODULE__, :dumps, kind}, {0, nil})
    :logger.add_handler(:simulator_diag_revoke_watch, __MODULE__, %{level: :info})
  end

  def log(%{msg: {:string, msg}}, _config) do
    with true <- :binary.match(IO.iodata_to_binary(msg), "Assignment revoked") != :nomatch,
         [_, topic, partition, group, mod] <- Regex.run(@revoked, IO.iodata_to_binary(msg)) do
      spawn(fn -> watch_revoke(topic, String.to_integer(partition), group, mod) end)
    end

    :ok
  rescue
    _ -> :ok
  end

  def log(_event, _config), do: :ok

  defp watch_revoke(topic, partition, group, mod) do
    mod = String.to_existing_atom(mod)

    pids =
      for {{_, _client, ^mod, _tid, ^partition, ^group}, pid} <-
            registry(Klife.Consumer.ConsumerGroup.Consumer, 6),
          match?(%{topic_name: ^topic}, safe_state(pid)),
          do: pid

    Process.sleep(@revoke_wait_ms)

    alive = Enum.filter(pids, &Process.alive?/1)

    if alive != [] do
      maybe_dump(%{
        revoke_stuck: %{topic: topic, partition: partition, group: group, mod: mod},
        waited_ms: @revoke_wait_ms,
        consumers: alive
      })
    end
  end

  def maybe_dump(reason) do
    now = System.monotonic_time(:millisecond)
    kind = if Map.has_key?(reason, :revoke_stuck), do: :revoke, else: :lag
    {count, last} = :persistent_term.get({__MODULE__, :dumps, kind}, {0, nil})

    if count < @max_dumps and (last == nil or now - last >= @interval_ms) do
      :persistent_term.put({__MODULE__, :dumps, kind}, {count + 1, now})
      ts = :persistent_term.get(:simulation_timestamp, "unknown")
      path = Path.relative("simulations_data/#{ts}/diag-#{kind}-#{count + 1}.txt")
      spawn(fn -> File.write(path, dump(reason)) end)
    end

    :ok
  end

  def dump(reason) do
    tcp = proc_net_tcp()

    [
      "reason: #{inspect(reason)}\nat: #{DateTime.utc_now()}\n\n",
      "== consumers of the reason\n",
      for(pid <- Map.get(reason, :consumers, []), do: consumer(pid)),
      "\n== group members (a: assigned, c: consumer running, k: acked for processing)\n",
      groups(),
      "\n== committers\n",
      committers(),
      "\n== in flight requests\n",
      in_flight(),
      "\n",
      connections(tcp),
      "\n== processes blocked in klife or socket code\n",
      blocked_processes(),
      "\n== /proc/net/tcp (tx_queue/rx_queue in bytes)\n",
      Enum.map(tcp, &tcp_line/1),
      "\n== broker side, connections with queued bytes\n",
      broker_queues()
    ]
  end

  defp registry(mod, size) do
    Registry.select(Klife.ProcessRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {key, _pid} ->
      is_tuple(key) and tuple_size(key) == size and elem(key, 0) == mod
    end)
    |> Enum.sort()
  end

  defp safe_state(pid) do
    :sys.get_state(pid, 1_000)
  catch
    kind, error -> {kind, error}
  end

  defp consumer(pid) do
    state =
      case safe_state(pid) do
        %{latest_processed_offset: _} = s ->
          "  #{s.topic_name}:#{s.partition_idx} processed=#{s.latest_processed_offset} " <>
            "committed=#{s.latest_committed_offset} issued=#{s.latest_issued_commit_offset} " <>
            "committer=#{s.committer_id} queued_batches=#{s.records_batch_queue_count} " <>
            "fetch_ref=#{inspect(s.fetch_ref)}\n"

        other ->
          "  state: #{inspect(other)}\n"
      end

    [process(pid), state]
  end

  defp groups do
    for {{_, client, mod, group}, pid} <- registry(Klife.Consumer.ConsumerGroup, 4) do
      state =
        case safe_state(pid) do
          %Klife.Consumer.ConsumerGroup{} = s ->
            assigned =
              for %{topic_id: tid, partitions: ps} <- s.assigned_topic_partitions || [],
                  p <- ps,
                  do: {tid, p}

            consumers = Map.values(s.consumers_monitor_map || %{})
            acked = acked(client, mod, group)

            by_topic =
              (assigned ++ consumers ++ acked)
              |> Enum.map(&elem(&1, 0))
              |> Enum.uniq()
              |> Enum.map(fn tid ->
                pick = fn list -> for {^tid, p} <- list, do: p end
                name = topic_name(client, tid)

                "    #{String.slice(name, 0, 4)} a#{inspect(Enum.sort(pick.(assigned)), charlists: :as_lists)} " <>
                  "c#{inspect(Enum.sort(pick.(consumers)), charlists: :as_lists)} k#{inspect(Enum.sort(pick.(acked)), charlists: :as_lists)}\n"
              end)
              |> Enum.sort()

            [
              "  epoch=#{s.epoch} coordinator=#{s.coordinator_id} member=#{s.member_id} " <>
                "heartbeat_ms=#{s.heartbeat_interval_ms}\n",
              by_topic
            ]

          other ->
            "  state: #{inspect(other)}\n"
        end

      ["-- #{inspect(client)} #{inspect(mod)} #{group}\n", process(pid), state]
    end
  end

  defp topic_name(client, tid) do
    Klife.MetadataCache.get_topic_name_by_id(client, tid) || inspect(tid)
  rescue
    _ -> inspect(tid)
  end

  defp acked(client, mod, group) do
    :ets.tab2list(:"acked_topic_partitions.#{client}.#{mod}.#{group}")
    |> Enum.map(fn {key} -> key end)
  rescue
    _ -> []
  end

  defp committers do
    now = System.monotonic_time(:millisecond)

    for {{_, client, mod, group, id}, pid} <- registry(Klife.Consumer.Committer, 5) do
      state =
        case safe_state(pid) do
          %Klife.GenBatcher{user_state: u} = s ->
            timer = s.next_dispatch_msg_ref

            requests =
              for {ref, batch} <- u.requests, do: {ref, batch_items(batch)}

            "  epoch=#{u.member_epoch} broker=#{u.broker_id} in_flight=#{inspect(s.in_flight_pool)}\n" <>
              "  requests=#{inspect(requests)}\n" <>
              "  queued_batches=#{:queue.len(s.batch_queue)} current=#{inspect(batch_items(s.current_batch))}\n" <>
              "  last_sent_ago_ms=#{inspect(s.last_batch_sent_at && now - s.last_batch_sent_at)} " <>
              "next_dispatch=#{inspect(timer)} timer_left=#{inspect(timer && Process.read_timer(timer))}\n"

          other ->
            "  state: #{inspect(other)}\n"
        end

      ["-- #{inspect(client)} #{inspect(mod)} #{group} committer=#{id}\n", process(pid), state]
    end
  end

  defp batch_items(%{data: data}) when is_map(data),
    do: for({{t, p}, item} <- data, do: {String.slice(t, 0, 4), p, item.offset_to_commit})

  defp batch_items(other), do: other

  defp in_flight do
    clients =
      registry(Klife.Connection.Broker, 5)
      |> Enum.map(fn {{_, _broker, client, _conn, _idx}, _pid} -> client end)
      |> Enum.uniq()

    for client <- clients,
        table = :persistent_term.get({Klife.Connection.Controller, client, :in_flight_table}, nil),
        table != nil do
      entries = table |> :ets.tab2list() |> Enum.sort()

      [
        "-- #{inspect(client)} #{length(entries)} entries\n",
        entries |> Enum.take(400) |> Enum.map(&in_flight_entry/1)
      ]
    end
  end

  defp in_flight_entry({corr, pid}) when is_pid(pid),
    do: "  #{corr} sync #{inspect(pid)} #{inspect(Process.info(pid, :current_function))}\n"

  defp in_flight_entry({corr, {pid, ref, mod, _version, timer}}) do
    left = if is_reference(timer), do: Process.read_timer(timer)

    "  #{corr} async #{inspect(mod)} #{inspect(pid)} ref=#{inspect(ref)} timer_left=#{inspect(left)}\n"
  end

  defp in_flight_entry(other), do: "  #{inspect(other)}\n"

  defp connections(tcp) do
    registry(Klife.Connection.Broker, 5)
    |> Enum.map(fn {{_, broker_id, client, conn_name, idx}, pid} ->
      conn =
        :persistent_term.get({Klife.Connection.Broker, client, conn_name, broker_id, idx}, nil)

      [
        "== #{inspect(client)} #{inspect(conn_name)} broker=#{broker_id} idx=#{idx} broker_pid=#{inspect(pid)}\n",
        process(pid),
        socket(conn, tcp)
      ]
    end)
  end

  defp socket(nil, _tcp), do: "  no connection in persistent_term\n"

  defp socket(%Klife.Connection{socket: socket, ssl: ssl}, tcp) do
    mod = if ssl, do: :ssl, else: :inet

    stats =
      timed(fn ->
        mod.getstat(socket, [:recv_cnt, :recv_oct, :send_cnt, :send_oct, :send_pend])
      end)

    port =
      case timed(fn -> mod.sockname(socket) end) do
        {:ok, {:ok, {_ip, port}}} -> port
        _ -> nil
      end

    queues =
      for {local, remote, st, tx, rx} <- tcp,
          port != nil,
          String.ends_with?(local, ":#{port}"),
          do: "  tcp #{local} -> #{remote} st=#{st} tx_queue=#{tx} rx_queue=#{rx}\n"

    [
      "  socket=#{inspect(socket)} stats=#{inspect(stats)}\n",
      queues,
      for(p <- pids(socket), do: ["  socket process ", process(p)])
    ]
  end

  defp process(pid) do
    case Process.info(pid, [:status, :message_queue_len, :current_stacktrace]) do
      nil ->
        "  #{inspect(pid)} dead\n"

      info ->
        "  #{inspect(pid)} status=#{info[:status]} mq=#{info[:message_queue_len]}\n" <>
          Enum.map_join(info[:current_stacktrace], "", &"    #{inspect(&1)}\n")
    end
  end

  # Processes whose stack has a klife or socket frame below its top one, so not idle
  # in their own receive loop
  defp blocked_processes do
    for pid <- Process.list(),
        info = Process.info(pid, [:current_stacktrace, :registered_name, :status]),
        info != nil,
        stack = info[:current_stacktrace],
        interesting?(stack) do
      "#{inspect(pid)} #{inspect(info[:registered_name])} status=#{info[:status]}\n" <>
        Enum.map_join(stack, "", &"    #{inspect(&1)}\n") <> retry_backtrace(pid, stack)
    end
  end

  # The stack frames of a with_timeout! retry loop hold its last error
  defp retry_backtrace(pid, stack) do
    if Enum.any?(stack, &match?({Klife.Helpers, _, _, _}, &1)) do
      case Process.info(pid, :backtrace) do
        {:backtrace, bin} ->
          lines =
            bin
            |> String.split("\n")
            |> Enum.map(&String.slice(&1, 0, 4000))
            |> Enum.take(80)

          "    backtrace:\n" <> Enum.map_join(lines, "", &"      #{&1}\n")

        nil ->
          ""
      end
    else
      ""
    end
  end

  defp interesting?([{top_mod, _, _, _} | _] = stack) do
    idle = top_mod in [:gen_server, :gen_statem, :gen_event, :proc_lib, :erlang, :timer]

    klife_or_socket =
      Enum.any?(stack, fn {mod, fun, _, _} ->
        name = Atom.to_string(mod)

        String.starts_with?(name, "Elixir.Klife.") or
          mod in [:ssl, :ssl_gen_statem, :tls_sender, :prim_inet, :gen_tcp, :socket] or
          (mod == :tls_connection and fun != :init)
      end)

    klife_or_socket and not (idle and length(stack) <= 3)
  end

  defp interesting?(_), do: false

  defp pids(term) when is_pid(term), do: [term]
  defp pids(term) when is_tuple(term), do: term |> Tuple.to_list() |> pids()
  defp pids(term) when is_list(term), do: Enum.flat_map(term, &pids/1)
  defp pids(_), do: []

  defp timed(fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, @call_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> :timeout
    end
  end

  defp tcp_line({local, remote, st, tx, rx}),
    do: "#{local} -> #{remote} st=#{st} tx_queue=#{tx} rx_queue=#{rx}\n"

  defp broker_queues do
    for service <- Simulator.Cluster.services() do
      lines =
        case timed(fn -> Simulator.Cluster.proc_net_tcp(service) end) do
          {:ok, output} when is_binary(output) ->
            output |> parse_tcp() |> Enum.filter(fn t -> elem(t, 3) + elem(t, 4) > 0 end)

          other ->
            [inspect(other)]
        end

      [
        "-- #{service}\n",
        Enum.map(lines, fn
          l when is_tuple(l) -> tcp_line(l)
          l -> l <> "\n"
        end)
      ]
    end
  rescue
    error -> "broker queues failed: #{Exception.message(error)}\n"
  end

  defp proc_net_tcp do
    ["/proc/net/tcp", "/proc/net/tcp6"]
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, content} -> parse_tcp(content)
        _ -> []
      end
    end)
  end

  defp parse_tcp(content) do
    for line <- String.split(content, "\n", trim: true),
        [_, local, remote, st, queues | _] <- [String.split(line)],
        local != "local_address" do
      [tx, rx] = String.split(queues, ":")
      {addr(local), addr(remote), st, String.to_integer(tx, 16), String.to_integer(rx, 16)}
    end
  end

  defp addr(hex) do
    [ip, port] = String.split(hex, ":")
    "#{ip}:#{String.to_integer(port, 16)}"
  end
end
