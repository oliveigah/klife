defmodule Simulator.Engine do
  require Logger
  use GenServer

  alias Simulator.EngineConfig

  defstruct [
    :config,
    :total_produced_counter,
    :total_consumed_counters
  ]

  def get_config, do: :persistent_term.get(:engine_config)

  def get_clients, do: get_config().clients

  def get_simulation_topics_data, do: get_config().topics

  @impl true
  def init(_init_args) do
    config = EngineConfig.generate_config()
    :persistent_term.put(:engine_config, config)

    total_produced_counter = :atomics.new(1, [])

    consumed_counters =
      Enum.map(config.consumer_groups, fn %{name: cgname} ->
        total_consumed_counter = :atomics.new(1, [])
        :persistent_term.put({:total_consumed_counter, cgname}, total_consumed_counter)
        {cgname, total_consumed_counter}
      end)
      |> Map.new()

    :persistent_term.put(:total_produced_counter, total_produced_counter)

    save_data(:config_bin, :erlang.term_to_binary(config))
    save_data(:config, inspect(config, limit: :infinity) |> Code.format_string!())

    :ok = create_topics(config)

    # Wait metadata update (TODO: Use pubsub)
    Process.sleep(5_000)

    :ok = handle_tables(config)

    {:ok, _pid} = Simulator.Engine.ProcessRegistry.start_link()
    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    :ok = handle_consumers(config, consumer_sup_pid)

    :ok = handle_producers(config)

    send(self(), :invariants_check_loop)

    state = %__MODULE__{
      config: config,
      total_produced_counter: total_produced_counter,
      total_consumed_counters: consumed_counters
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

    # TODO: Think about how to reuse the same topic!
    Enum.filter(topics_response, fn e -> e.error_code != 0 end)
    |> case do
      [] ->
        :ok

      err ->
        {:error, err}
    end
  end

  def start_link(args) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    :persistent_term.put(:simulation_timestamp, ts)

    case System.get_env("RERUN_TS") do
      nil -> :noop
      val -> :persistent_term.put(:rerun_timestamp, val)
    end

    :ok = File.mkdir_p(Path.relative("simulations_data/#{ts}"))

    :ok =
      :logger.add_handler(
        :engine_log_file_handler,
        :logger_std_h,
        %{
          config: %{
            file: Path.relative("simulations_data/#{ts}/runtime.log") |> to_charlist()
          }
        }
      )

    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def handle_info(:invariants_check_loop, %__MODULE__{} = state) do
    config = state.config
    total_produced_rec_count = :atomics.get(state.total_produced_counter, 1)
    Logger.info("Running invariants check!")
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
    lag_threshold = EngineConfig.lag_warning_threshold(config)

    for %{topic: t, partitions: pcount} <- config.topics,
        p <- 0..(pcount - 1) do
      cg_latest_ts_map =
        Enum.map(config.consumer_groups, fn %{name: cgname} ->
          [{_, latest_ts}] = :ets.lookup(consumer_table_name(t, p, cgname), :latest_timestamp)
          {cgname, latest_ts}
        end)
        |> Map.new()

      all_data = :ets.tab2list(producer_table_name(t, p))

      all_data
      |> Enum.frequencies_by(fn {{_key, cg}, _hash, _time, _offset, _conf_ts} -> cg end)
      |> Enum.each(fn {cg, rec_count} ->
        if rec_count >= lag_threshold do
          Logger.warning("Too much lag (#{rec_count}) for #{cg} #{t} #{p}")
        end
      end)

      grouped_data =
        Enum.group_by(all_data, fn {{_key, cg}, _hash, _time, _offset, _conf_ts} -> cg end)

      for {cg, list_of_items} <- grouped_data do
        Enum.filter(list_of_items, fn {{_key, cg}, _hash, _insert_time, offset, conf_ts} ->
          is_number(conf_ts) and is_number(offset) and conf_ts < cg_latest_ts_map[cg]
        end)
        |> case do
          [] ->
            :ok

          skipped ->
            {{_oldest_key, _cg}, _hash, _insert_ts, offset, conf_ts} =
              Enum.max_by(skipped, fn {{_key, _cg}, _hash, _insert_time, _offset, conf_ts} ->
                now - conf_ts
              end)

            Logger.warning(
              "Skipped #{length(skipped)} records on #{cg} #{t} #{p}! oldest offset #{offset} oldest time diff #{now - conf_ts}"
            )
        end
      end
    end

    state
  end

  def handle_tables(%EngineConfig{} = config) do
    :ets.new(:engine_support, [:set, :public, :named_table])

    for %{topic: t, partitions: pcount} <- config.topics,
        p <- 0..(pcount - 1) do
      :ets.new(producer_table_name(t, p), [:ordered_set, :public, :named_table])

      Enum.each(config.consumer_groups, fn %{name: cg_name} ->
        ref = :atomics.new(1, [])
        :atomics.sub(ref, 1, 1)

        :ok =
          :persistent_term.put(consumer_counter_key(t, p, cg_name), ref)

        :ets.new(consumer_table_name(t, p, cg_name), [:ordered_set, :public, :named_table])

        :ets.insert(
          consumer_table_name(t, p, cg_name),
          {:latest_timestamp, System.monotonic_time(:millisecond)}
        )

        :ets.new(idempotency_table_name(t, p, cg_name), [:set, :public, :named_table])
      end)
    end

    :ok
  end

  def handle_producers(%EngineConfig{} = config) do
    for %{topic: t, partitions: pcount} <- config.topics,
        p <- 0..(pcount - 1),
        idx <- 1..config.producer_concurrency do
      args = %{
        client: Enum.random(config.clients),
        topic: t,
        partition: p,
        max_records: config.producer_max_rps,
        loop_interval_ms: config.producer_loop_interval_ms,
        record_value_bytes: config.record_value_bytes,
        record_key_bytes: config.record_key_bytes,
        index: idx
      }

      {:ok, _pid} = Simulator.Engine.Producer.start_link(args)
    end

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
      spec = %{
        id: {opts[:group_name], opts[:cg_mod]},
        start: {opts[:cg_mod], :start_link, [Keyword.delete(opts, :cg_mod)]},
        restart: :transient,
        type: :worker
      }

      :ets.insert(:engine_support, {{opts[:group_name], opts[:cg_mod]}, opts})

      {:ok, _pid} = DynamicSupervisor.start_child(sup_pid, spec)
    end)

    :ok
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

    duplicated_message? = :ets.member(idempotency_table, rec.offset)
    not_produced_message? = lookup_resp == []

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
        raise """
        CONSUMED DUPLICATED MESSAGE!

        TOPIC: #{rec.topic}
        PARTITION: #{rec.partition}
        GROUP NAME: #{cg_name}
        DUPLICATED OFFSET: #{rec.offset}

        CONSUMER GROUP CONFIG:

        #{inspect(get_cg_config(cg_name, cg_mod))}
        """

      not_produced_message? ->
        # TODO: This may be ok for the :earliest reset policy
        raise """
        CONSUMED NOT PRODUCED MESSAGE!

        TOPIC: #{rec.topic}
        PARTITION: #{rec.partition}
        OFFSET: #{rec.offset}
        GROUP NAME: #{cg_name}
        RECORD: #{inspect(rec)}

        CONSUMER GROUP CONFIG:

        #{inspect(get_cg_config(cg_name, cg_mod))}
        """

      not expected_record? ->
        raise """
        CONSUMED UNEXPECTED MESSAGE!

        TOPIC: #{rec.topic}
        PARTITION: #{rec.partition}
        OFFSET: #{rec.offset}
        GROUP NAME: #{cg_name}
        RECORD: #{inspect(rec)}

        CONSUMER GROUP CONFIG:

        #{inspect(get_cg_config(cg_name, cg_mod))}
        """

      out_of_order? ->
        raise """
        CONSUMED OUT OF ORDER MESSAGE!

        TOPIC: #{rec.topic}
        PARTITION: #{rec.partition}
        OFFSET: #{rec.offset}
        GROUP NAME: #{cg_name}
        RECORD: #{inspect(rec)}

        CONSUMER GROUP CONFIG:

        #{inspect(get_cg_config(cg_name, cg_mod))}
        """

      true ->
        case :atomics.compare_exchange(counter, 1, latest_consummed_offset, rec.offset) do
          :ok ->
            :persistent_term.get({:total_consumed_counter, cg_name}) |> :atomics.add(1, 1)

            [{_key, _hash, insert_time, _offset, _confirmation_ts}] =
              :ets.take(producer_table, to_take)

            :ets.insert(
              consumer_table_name(rec.topic, rec.partition, cg_name),
              {:latest_timestamp, insert_time}
            )

            true = :ets.insert_new(idempotency_table, {rec.offset, rec})
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
    table = producer_table_name(rec.topic, rec.partition)
    hash_data = hash_record(rec)

    to_insert =
      Enum.map(config.consumer_groups, fn %{name: cg_name} ->
        {{rec.key, cg_name}, hash_data, System.monotonic_time(:millisecond), nil, nil}
      end)

    true = :ets.insert_new(table, to_insert)
    :persistent_term.get(:total_produced_counter) |> :atomics.add(1, 1)
    :ok
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

  def allowed_to_produce?(topic, partition) do
    config = get_config()

    Enum.map(config.consumer_groups, fn %{name: cg} ->
      case :ets.lookup(:engine_support, {:consumer_ready, topic, partition, cg}) do
        [{_key, val}] -> val
        [] -> false
      end
    end)
    |> Enum.all?()
  end
end
