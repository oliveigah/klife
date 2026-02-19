defmodule Simulator.Engine do
  require Logger
  use GenServer, restart: :temporary

  alias Simulator.EngineConfig

  defstruct [
    :config,
    :total_produced_counter,
    :total_consumed_counters,
    :sup_pid,
    :init_ts,
    :cluster_log_pid,
    partition_counts: %{},
    partition_counts_updated_at: %{},
    last_partition_produced_counts: %{}
  ]

  def get_config, do: :persistent_term.get(:engine_config)

  def get_clients, do: get_config().clients

  def get_simulation_topics_data, do: get_config().topics

  @impl true
  def init(_init_args) do
    config = EngineConfig.generate_config()
    :persistent_term.put(:engine_config, config)
    :rand.seed(:exsss, config.root_seed)

    total_produced_counter = :atomics.new(1, [])

    consumed_counters =
      Enum.map(config.consumer_groups, fn %{name: cgname} ->
        total_consumed_counter = :atomics.new(1, [])
        :persistent_term.put({:total_consumed_counter, cgname}, total_consumed_counter)
        {cgname, total_consumed_counter}
      end)
      |> Map.new()

    :persistent_term.put(:total_produced_counter, total_produced_counter)
    :persistent_term.put(:simulation_start_ts, System.monotonic_time(:second))
    Logger.info("Engine started with timestamp: #{:persistent_term.get(:simulation_timestamp)}")
    save_data(:"config.exs", inspect(config, limit: :infinity) |> Code.format_string!())

    :ok = create_topics(config)

    # Wait metadata update (TODO: Use pubsub)
    Process.sleep(5_000)

    :ok = handle_tables(config)
    :ok = init_partition_resources(config)

    now = System.monotonic_time(:second)

    partition_counts =
      Map.new(config.topics, fn %{topic: t, partitions: pcount} -> {t, pcount} end)

    partition_counts_updated_at =
      Map.new(config.topics, fn %{topic: t} -> {t, now} end)

    {:ok, _pid} = Simulator.Engine.ProcessRegistry.start_link()
    {:ok, sup_pid} = DynamicSupervisor.start_link(max_restarts: 1000)

    :ok = handle_consumers(config, sup_pid)
    :ok = handle_producers(config, sup_pid)
    :ok = handle_event_executor(sup_pid)

    send(self(), :invariants_check_loop)

    ts = :persistent_term.get(:simulation_timestamp)
    cluster_log_path = Path.relative("simulations_data/#{ts}/cluster.log")
    compose_file = "../test/compose_files/docker-compose-kafka-4.1.yml"

    {pid_str, 0} =
      System.shell(
        "docker compose -f #{compose_file} logs -f --since 0s > #{cluster_log_path} 2>&1 & echo $!"
      )

    cluster_log_pid = String.trim(pid_str)

    state = %__MODULE__{
      config: config,
      total_produced_counter: total_produced_counter,
      total_consumed_counters: consumed_counters,
      sup_pid: sup_pid,
      cluster_log_pid: cluster_log_pid,
      partition_counts: partition_counts,
      partition_counts_updated_at: partition_counts_updated_at
    }

    {:ok, state}
  end

  def create_topics(%EngineConfig{} = config) do
    content = %{
      topics:
        Enum.map(config.topics, fn input ->
          %{
            name: input[:topic],
            num_partitions: input[:partitions],
            replication_factor: config.topics_replication_factor,
            assignments: [],
            configs: []
          }
        end),
      timeout_ms: 15_000,
      validate_only: false
    }

    client = Enum.random(config.clients)

    {:ok, %{content: %{topics: topics_response}}} =
      Klife.Connection.Broker.send_message(
        KlifeProtocol.Messages.CreateTopics,
        client,
        :controller,
        content
      )

    Enum.filter(topics_response, fn e -> e.error_code != 0 end)
    |> case do
      [] ->
        :ok

      err ->
        {:error, err}
    end
  end

  def start_link(args) do
    ts = ("_" <> (DateTime.utc_now() |> DateTime.to_iso8601())) |> String.slice(0..19)
    :persistent_term.put(:simulation_timestamp, ts)

    case System.get_env("RERUN_TS") do
      nil -> :noop
      val -> :persistent_term.put(:rerun_timestamp, val)
    end

    :ok = File.mkdir_p(Path.relative("simulations_data/#{ts}"))

    :ok =
      :logger.add_handler(
        :"engine_log_file_handler_#{ts}",
        :logger_std_h,
        %{
          config: %{
            file: Path.relative("simulations_data/#{ts}/runtime.log") |> to_charlist()
          }
        }
      )

    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def terminate() do
    GenServer.call(__MODULE__, :terminate, :infinity)
  end

  @impl true
  def handle_call({:init_consumer_group, opts}, _from, %__MODULE__{} = state) do
    result = start_consumer_group(opts, state.sup_pid)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_partition_count, topic}, _from, %__MODULE__{} = state) do
    {:reply, Map.fetch!(state.partition_counts, topic), state}
  end

  @impl true
  def handle_call({:update_partition_count, topic, new_count}, _from, %__MODULE__{} = state) do
    old_count = Map.fetch!(state.partition_counts, topic)

    for p <- old_count..(new_count - 1) do
      create_partition_resources(topic, p, state.config)
    end

    state = %{
      state
      | partition_counts: Map.put(state.partition_counts, topic, new_count),
        partition_counts_updated_at:
          Map.put(state.partition_counts_updated_at, topic, System.monotonic_time(:second))
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:terminate, from, %__MODULE__{} = state) do
    :ok = Simulator.Engine.EventExecutor.force_rollbacks()
    :ok = DynamicSupervisor.stop(state.sup_pid, :normal)

    ts = :persistent_term.get(:simulation_timestamp)
    :logger.remove_handler(:"engine_log_file_handler_#{ts}")

    if state.cluster_log_pid do
      System.shell("kill #{state.cluster_log_pid}")
    end

    # Need a last pass on the invariants_check_loopp in order
    # to guarantee that everything is properly save on files
    {:noreply, _} = handle_info(:invariants_check_loop, state)

    case :ets.tab2list(:invariants_violations) do
      [] ->
        :noop

      error_list ->
        old = Path.relative("simulations_data/#{ts}")

        base_name =
          error_list
          |> Enum.map(fn {_ts, type, _details} -> type end)
          |> Enum.uniq()
          |> Enum.join("__")

        new_name = String.trim(ts, "_") <> "__" <> base_name

        File.rename(old, "simulations_data/#{new_name}")
    end

    GenServer.reply(from, :ok)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:invariants_check_loop, %__MODULE__{} = state) do
    config = state.config
    total_produced_rec_count = :atomics.get(state.total_produced_counter, 1)
    total_invariants = :ets.info(:invariants_violations, :size)
    ts = :persistent_term.get(:simulation_timestamp)

    :ok =
      :ets.tab2file(
        :invariants_violations,
        Path.relative("simulations_data/#{ts}/invariants_violations.ets") |> to_charlist()
      )

    invariants_data =
      :ets.tab2list(:invariants_violations)
      |> Enum.map(fn e -> inspect(e) end)
      |> Enum.join("\n")

    save_data(:"invariants_violations.exs", invariants_data)

    Logger.info("Running invariants check!")
    Logger.info("Total invariants violations: #{total_invariants}")
    Logger.info("Total produced records: #{total_produced_rec_count}")

    Enum.each(config.consumer_groups, fn %{name: cgname} ->
      Logger.info(
        "Total consumed records for #{cgname}: #{:atomics.get(state.total_consumed_counters[cgname], 1)}"
      )
    end)

    Process.send_after(self(), :invariants_check_loop, config.invariants_check_interval_ms)

    if total_produced_rec_count > 0,
      do: {:noreply, do_check_invariants(state)},
      else: {:noreply, state}
  end

  defp do_check_invariants(%__MODULE__{} = state) do
    config = state.config
    now = System.monotonic_time(:millisecond)
    lag_threshold = :timer.seconds(100)

    for %{topic: t} <- config.topics,
        p <- 0..(Map.fetch!(state.partition_counts, t) - 1) do
      current_count =
        :persistent_term.get({:partition_produced_counter, t, p}) |> :atomics.get(1)

      {last_count, occurrences} = Map.get(state.last_partition_produced_counts, {t, p}, {0, 0})

      if last_count > 0 and current_count <= last_count and occurrences + 1 >= 15 do
        insert_violation(:stale_producer, %{
          topic: t,
          partition: p,
          last_count: last_count,
          current_count: current_count,
          consecutive_occurrences: occurrences + 1
        })
      end

      cg_latest_ts_map =
        Enum.map(config.consumer_groups, fn %{name: cgname} ->
          consumed_recs = :ets.info(idempotency_table_name(t, p, cgname), :size)

          time_since_partition_change =
            System.monotonic_time(:second) - Map.fetch!(state.partition_counts_updated_at, t)

          if(consumed_recs == 0 and time_since_partition_change > 90) do
            insert_violation(:no_produce, %{
              topic: t,
              partition: p
            })
          end

          :ets.lookup(consumer_table_name(t, p, cgname), :latest_timestamp)

          [{_, latest_ts}] = :ets.lookup(consumer_table_name(t, p, cgname), :latest_timestamp)
          {cgname, latest_ts}
        end)
        |> Map.new()

      all_data = :ets.tab2list(producer_table_name(t, p))

      grouped_data =
        Enum.group_by(all_data, fn {{_key, cg}, _hash, _time, _offset, _conf_ts} -> cg end)

      for {cg, list_of_items} <- grouped_data do
        Enum.filter(list_of_items, fn {{_key, cg}, _hash, _insert_time, offset, conf_ts} ->
          is_number(conf_ts) and is_number(offset) and
            (conf_ts < cg_latest_ts_map[cg] or now - conf_ts >= lag_threshold)
        end)
        |> case do
          [] ->
            :ok

          skipped_or_delayed ->
            skipped =
              Enum.filter(skipped_or_delayed, fn {{_key, _cg}, _hash, _insert_time, _offset,
                                                  conf_ts} ->
                conf_ts < cg_latest_ts_map[cg]
              end)

            if skipped != [] do
              {{_oldest_key, _cg}, _hash, _insert_ts, offset, conf_ts} =
                Enum.max_by(skipped, fn {{_key, _cg}, _hash, _insert_time, _offset, conf_ts} ->
                  now - conf_ts
                end)

              insert_violation(:skipped_record, %{
                consumer_group: cg,
                topic: t,
                partition: p,
                oldest_offset: offset,
                oldest_time_diff_ms: now - conf_ts
              })
            end

            delayed =
              Enum.filter(skipped_or_delayed, fn {{_key, _cg}, _hash, _insert_time, _offset,
                                                  conf_ts} ->
                now - conf_ts >= lag_threshold
              end)

            if delayed != [] do
              {{_oldest_key, _cg}, _hash, _insert_ts, offset, conf_ts} =
                Enum.max_by(delayed, fn {{_key, _cg}, _hash, _insert_time, _offset, conf_ts} ->
                  now - conf_ts
                end)

              insert_violation(:too_much_lag, %{
                consumer_group: cg,
                topic: t,
                partition: p,
                oldest_offset: offset,
                oldest_time_diff_ms: now - conf_ts
              })
            end
        end
      end
    end

    new_last_partition_produced_counts =
      for %{topic: t} <- config.topics,
          p <- 0..(Map.fetch!(state.partition_counts, t) - 1),
          into: %{} do
        current_count =
          :persistent_term.get({:partition_produced_counter, t, p}) |> :atomics.get(1)

        {last_count, occurrences} = Map.get(state.last_partition_produced_counts, {t, p}, {0, 0})

        new_occurrences =
          if last_count > 0 and current_count <= last_count,
            do: occurrences + 1,
            else: 0

        {{t, p}, {current_count, new_occurrences}}
      end

    %{state | last_partition_produced_counts: new_last_partition_produced_counts}
  end

  def handle_tables(%EngineConfig{} = _config) do
    :ets.new(:engine_support, [:set, :public, :named_table])
    :ets.new(:invariants_violations, [:bag, :public, :named_table])
    :ok
  end

  defp init_partition_resources(%EngineConfig{} = config) do
    for %{topic: t, partitions: pcount} <- config.topics,
        p <- 0..(pcount - 1) do
      create_partition_resources(t, p, config)
    end

    :ok
  end

  defp create_partition_resources(topic, partition, %EngineConfig{} = config) do
    ref = :atomics.new(1, [])
    :persistent_term.put({:partition_produced_counter, topic, partition}, ref)

    :ets.new(producer_table_name(topic, partition), [:ordered_set, :public, :named_table])

    Enum.each(config.consumer_groups, fn %{name: cg_name} ->
      ref = :atomics.new(1, [])
      :atomics.sub(ref, 1, 1)

      :persistent_term.put(consumer_counter_key(topic, partition, cg_name), ref)

      :ets.new(consumer_table_name(topic, partition, cg_name), [
        :ordered_set,
        :public,
        :named_table
      ])

      :ets.insert(
        consumer_table_name(topic, partition, cg_name),
        {:latest_timestamp, System.monotonic_time(:millisecond)}
      )

      :ets.new(idempotency_table_name(topic, partition, cg_name), [
        :set,
        :public,
        :named_table
      ])
    end)

    :ok
  end

  def insert_violation(type, details) do
    ts = System.monotonic_time(:second) - :persistent_term.get(:simulation_start_ts)
    true = :ets.insert(:invariants_violations, {ts, type, details})

    Logger.critical(%{
      timestamp: ts,
      invariant_type: type,
      details: details
    })

    :ok
  end

  def handle_producers(%EngineConfig{} = config, sup_pid) do
    for %{topic: t} <- config.topics,
        idx <- 0..(config.producer_concurrency - 1) do
      args =
        %{
          client: Enum.random(config.clients),
          topic: t,
          max_records: config.producer_max_rps,
          loop_interval_ms: config.producer_loop_interval_ms,
          record_value_bytes: config.record_value_bytes,
          record_key_bytes: config.record_key_bytes,
          index: idx
        }

      spec = %{
        id: {:producer, t, idx},
        start: {Simulator.Engine.Producer, :start_link, [args]},
        type: :worker
      }

      {:ok, _pid} = DynamicSupervisor.start_child(sup_pid, spec)
    end

    :ok
  end

  def init_consumer_group(opts) do
    GenServer.call(__MODULE__, {:init_consumer_group, opts}, 60_000)
  end

  def get_partition_count(topic) do
    GenServer.call(__MODULE__, {:get_partition_count, topic})
  end

  def update_partition_count(topic, new_count) do
    GenServer.call(__MODULE__, {:update_partition_count, topic, new_count})
  end

  def handle_event_executor(sup_pid) do
    spec = %{
      id: :event_executor,
      start: {Simulator.Engine.EventExecutor, :start_link, [[]]},
      type: :worker
    }

    {:ok, _pid} = DynamicSupervisor.start_child(sup_pid, spec)

    :ok
  end

  def consumer_counter_key(topic, partition, cgname) do
    {:consumer, :counter, topic, partition, cgname}
  end

  def producer_table_name(topic, partition),
    do: :"producer.#{topic}.#{partition}"

  def consumer_table_name(topic, partition, cg_name),
    do: :"consumer.#{topic}.#{partition}.#{cg_name}"

  def idempotency_table_name(topic, partition, cg_name),
    do: :"consumer_idempotency.#{topic}.#{partition}.#{cg_name}"

  def handle_consumers(%EngineConfig{} = config, sup_pid) do
    Enum.map(config.consumer_group_configs, fn opts ->
      :ets.insert(:engine_support, {{opts[:group_name], opts[:cg_mod]}, opts})
      {:ok, _pid} = start_consumer_group(opts, sup_pid)
    end)

    :ok
  end

  defp start_consumer_group(opts, sup_pid) do
    spec = %{
      id: {opts[:group_name], opts[:cg_mod]},
      start: {opts[:cg_mod], :start_link, [Keyword.delete(opts, :cg_mod)]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(sup_pid, spec)
  end

  def save_data(type, val) do
    ts = :persistent_term.get(:simulation_timestamp)
    File.write!(Path.relative("simulations_data/#{ts}/#{type}"), val)
  end

  def insert_consumed_record!(%Klife.Record{} = rec, cg_name, cg_mod) do
    counter = :persistent_term.get(consumer_counter_key(rec.topic, rec.partition, cg_name))
    latest_consummed_offset = :atomics.get(counter, 1)
    idempotency_table = idempotency_table_name(rec.topic, rec.partition, cg_name)
    producer_table = producer_table_name(rec.topic, rec.partition)

    to_take = {rec.key, cg_name}
    lookup_resp = :ets.lookup(producer_table, to_take)

    :ok = set_consumer_ready(rec.topic, rec.partition, cg_name)

    duplicated_message? = :ets.member(idempotency_table, rec.offset)

    expected_record? =
      case lookup_resp do
        [] ->
          true

        [{_key, hash_data, _insert_time, _offset, _confirmation_ts}] ->
          hash_data == hash_record(rec)
      end

    out_of_order? = latest_consummed_offset > rec.offset

    cond do
      duplicated_message? ->
        # It is not possible to guarantee that wont have any duplicated records
        # during failure scenarios. So lets just log it now, and not include it
        # as an invariant violation!
        #
        # :ok =
        #   insert_violation(:consumed_duplicate, %{
        #     consumer_group: cg_name,
        #     topic: rec.topic,
        #     partition: rec.partition,
        #     duplicated_offset: rec.offset
        #   })
        Logger.warning(
          "Duplicated record offset #{rec.offset} consumed by group #{cg_name} for topic #{rec.topic} partition #{rec.partition}"
        )

      not expected_record? ->
        :ok =
          insert_violation(:consumed_wrong_hash, %{
            consumer_group: cg_name,
            topic: rec.topic,
            partition: rec.partition
          })

      out_of_order? ->
        :ok =
          insert_violation(:consumed_out_of_order, %{
            consumer_group: cg_name,
            topic: rec.topic,
            partition: rec.partition
          })

      true ->
        case :atomics.compare_exchange(counter, 1, latest_consummed_offset, rec.offset) do
          :ok ->
            case :ets.take(producer_table, to_take) do
              [{_key, _hash, insert_time, _offset, _confirmation_ts}] ->
                :persistent_term.get({:total_consumed_counter, cg_name}) |> :atomics.add(1, 1)

                :ets.insert(
                  consumer_table_name(rec.topic, rec.partition, cg_name),
                  {:latest_timestamp, insert_time}
                )

              [] ->
                :noop
            end

            true = :ets.insert_new(idempotency_table, {rec.offset})
            :ok

          _ ->
            raise """
            CONCURRENT CHANGES TO LATEST_CONSUMMED_OFFSET

            TOPIC: #{rec.topic}
            PARTITION: #{rec.partition}
            OFFSET: #{rec.offset}
            GROUP NAME: #{cg_name}

            #{inspect(get_cg_config(cg_name, cg_mod))}
            """
        end
    end
  end

  def hash_record(%Klife.Record{} = rec) do
    data =
      [
        inspect(rec.topic),
        inspect(rec.partition),
        inspect(rec.value),
        inspect(rec.key),
        inspect(rec.headers)
      ]

    :crypto.hash(:md5, data)
  end

  def insert_produced_record(%Klife.Record{} = rec) do
    config = get_config()

    all_ready? =
      Enum.map(config.consumer_groups, fn %{name: cg} ->
        consumer_ready?(rec.topic, rec.partition, cg)
      end)
      |> Enum.all?()

    if all_ready? do
      table = producer_table_name(rec.topic, rec.partition)
      hash_data = hash_record(rec)

      to_insert =
        Enum.map(config.consumer_groups, fn %{name: cg_name} ->
          {{rec.key, cg_name}, hash_data, System.monotonic_time(:millisecond), nil, nil}
        end)

      true = :ets.insert_new(table, to_insert)
      :persistent_term.get(:total_produced_counter) |> :atomics.add(1, 1)
      :ok
    else
      :ok
    end
  end

  def confirm_produced_record(%Klife.Record{} = rec) do
    config = get_config()
    table = producer_table_name(rec.topic, rec.partition)

    Enum.map(config.consumer_groups, fn %{name: cg_name} ->
      :ets.update_element(table, {rec.key, cg_name}, [
        {4, rec.offset},
        {5, System.monotonic_time(:millisecond)}
      ])
    end)

    :persistent_term.get({:partition_produced_counter, rec.topic, rec.partition})
    |> :atomics.add(1, 1)

    :ok
  end

  def rollback_produced_record(%Klife.Record{} = rec) do
    config = get_config()
    table = producer_table_name(rec.topic, rec.partition)

    Enum.map(config.consumer_groups, fn %{name: cg_name} ->
      true = :ets.delete(table, {rec.key, cg_name})
    end)

    :persistent_term.get(:total_produced_counter) |> :atomics.sub(1, 1)
    :ok
  end

  def get_cg_config(cg_name, cg_mod) do
    :ets.lookup(:engine_support, {cg_name, cg_mod})
    |> List.first()
    |> elem(1)
  end

  def set_consumer_ready(topic, partition, cg_name) do
    true = :ets.insert(:engine_support, {{:consumer_ready, topic, partition, cg_name}, true})
    :ok
  end

  def consumer_ready?(topic, partition, cg_name) do
    case :ets.lookup(:engine_support, {:consumer_ready, topic, partition, cg_name}) do
      [{_key, val}] -> val
      [] -> false
    end
  end
end
