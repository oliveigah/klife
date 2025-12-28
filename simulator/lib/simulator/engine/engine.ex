defmodule Simulator.Engine do
  use GenServer

  @simulation_topics_data [
    %{topic: "simulator_topic_1", partitions: 10},
    %{topic: "simulator_topic_2", partitions: 10},
    %{topic: "simulator_topic_3", partitions: 10}
  ]

  @clients [
    Simulator.NormalClient,
    Simulator.TLSClient
  ]

  @consumer_groups [
    %{name: "SimulatorGroup1", max_consumers: 1},
    %{name: "SimulatorGroup2", max_consumers: 1},
    %{name: "SimulatorGroup3", max_consumers: 1}
  ]

  def get_clients, do: @clients

  def get_simulation_topics_data, do: @simulation_topics_data

  @impl true
  def init(_init_args) do
    :ok = handle_tables()

    {:ok, _pid} = Simulator.Engine.ProcessRegistry.start_link()
    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    handle_consumers(consumer_sup_pid)

    Process.sleep(10_000)

    :ok = handle_producers()

    send(self(), :invariants_check_loop)

    {:ok, nil}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def handle_info(:invariants_check_loop, _state) do
    for %{topic: t, partitions: pcount} <- @simulation_topics_data,
        p <- 0..(pcount - 1) do
      all_produced = :ets.tab2list(producer_table_name(t, p))

      Enum.each(@consumer_groups, fn %{name: cg_name} ->
        all_consumed = :ets.tab2list(consumer_table_name(t, p, cg_name))
        diff = all_produced -- all_consumed

        if length(all_produced) > 0 and length(all_consumed) == 0 do
          IO.inspect("Consumed length is 0 for #{t} #{p} #{cg_name}")
        end

        # IO.inspect("Produced length for #{t} #{p} #{cg_name}: #{length(all_produced)}")
        # IO.inspect("Consumed length for #{t} #{p} #{cg_name}: #{length(all_consumed)}")
        # IO.inspect("Diff length for #{t} #{p} #{cg_name}: #{length(diff)}")
      end)
    end

    Process.send_after(self(), :invariants_check_loop, 5_000)

    {:noreply, nil}
  end

  def handle_tables() do
    :ets.new(:engine_support, [:set, :public, :named_table])

    for %{topic: t, partitions: pcount} <- @simulation_topics_data,
        p <- 0..(pcount - 1) do
      :ok = :persistent_term.put(producer_counter_key(t, p), :atomics.new(1, []))
      :ets.new(producer_table_name(t, p), [:ordered_set, :public, :named_table])

      Enum.each(@consumer_groups, fn %{name: cg_name} ->
        :ok = :persistent_term.put(consumer_counter_key(t, p, cg_name), :atomics.new(1, []))
        :ets.new(consumer_table_name(t, p, cg_name), [:ordered_set, :public, :named_table])
        :ets.new(idempotency_table_name(t, p, cg_name), [:set, :public, :named_table])
      end)
    end

    :ok
  end

  def handle_producers() do
    for %{topic: t, partitions: pcount} <- @simulation_topics_data,
        p <- 0..(pcount - 1) do
      args = %{
        client: Enum.random(@clients),
        topic: t,
        partition: p
      }

      {:ok, _pid} = Simulator.Engine.Producer.start_link(args)
    end

    :ok
  end

  def producer_counter_key(topic, partition) do
    {:producer, :counter, topic, partition}
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

  def get_produced_records_counter(topic, partition) do
    :persistent_term.get({__MODULE__, :counter, topic, partition}, nil)
  end

  def handle_consumers(sup_pid) do
    for %{name: cg_name, max_consumers: mc} <- @consumer_groups,
        idx <- 1..mc do
      opts = Simulator.Engine.ConfigGenerator.generate_config(:consumer_group)
      opts = Keyword.replace(opts, :group_name, cg_name)

      cg_mod =
        case opts[:client] do
          Simulator.NormalClient -> :"#{Simulator.Engine.Consumer.NormalClient}#{idx}"
          Simulator.TLSClient -> :"#{Simulator.Engine.Consumer.TLSClient}#{idx}"
        end

      IO.inspect({cg_mod, opts}, label: "started!")

      spec = %{
        id: {cg_name, cg_mod},
        start: {cg_mod, :start_link, [opts]},
        restart: :transient,
        type: :worker
      }

      :ets.insert(:engine_support, {{cg_name, cg_mod}, opts})

      {:ok, _pid} = DynamicSupervisor.start_child(sup_pid, spec)
    end
  end

  def insert_consumed_record!(%Klife.Record{} = rec, cg_name, cg_mod) do
    counter = :persistent_term.get(consumer_counter_key(rec.topic, rec.partition, cg_name))
    table = consumer_table_name(rec.topic, rec.partition, cg_name)
    idempotency_table = idempotency_table_name(rec.topic, rec.partition, cg_name)

    if :ets.insert_new(idempotency_table, {rec.offset, rec}) == false do
      raise """
      CONSUMED DUPLICATED MESSAGE!

      TOPIC: #{rec.topic}
      PARTITION: #{rec.partition}
      GROUP NAME: #{cg_name}
      DUPLICATED OFFSET: #{rec.offset}

      CONSUMER GROUP CONFIG:

      #{inspect(get_cg_config(cg_name, cg_mod))}
      """
    end

    true = :ets.insert_new(table, {:atomics.add_get(counter, 1, 1), hash_record(rec)})

    :ok
  end

  def hash_record(%Klife.Record{} = rec) do
    data =
      [
        inspect(rec.offset),
        inspect(rec.topic),
        inspect(rec.partition),
        inspect(rec.value),
        inspect(rec.key),
        inspect(rec.headers)
      ]

    :crypto.hash(:md5, data)
  end

  def insert_produced_record(%Klife.Record{} = rec) do
    counter = :persistent_term.get(producer_counter_key(rec.topic, rec.partition))
    table = producer_table_name(rec.topic, rec.partition)
    true = :ets.insert_new(table, {:atomics.add_get(counter, 1, 1), hash_record(rec)})
    :ok
  end

  def get_cg_config(cg_name, cg_mod) do
    :ets.lookup(:engine_support, {cg_name, cg_mod})
    |> List.first()
    |> elem(1)
  end
end
