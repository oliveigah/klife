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
    :ets.new(:engine_support, [:set, :public, :named_table])
    :ets.new(:consumer_support, [:set, :public, :named_table])

    {:ok, _pid} = Simulator.Engine.ProcessRegistry.start_link()
    :ok = handle_producers()
    {:ok, consumer_sup_pid} = DynamicSupervisor.start_link([])

    handle_consumers(consumer_sup_pid)

    {:ok, nil}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def handle_producers() do
    for c <- @clients,
        %{topic: t, partitions: pcount} <- @simulation_topics_data,
        p <- 0..(pcount - 1) do
      :ok = maybe_init_produced_records_counter(t, p)

      :ets.new(producer_table_name(c, t, p), [:set, :public, :named_table])

      args = %{
        client: c,
        topic: t,
        partition: p
      }

      {:ok, _pid} = Simulator.Engine.Producer.start_link(args)
    end

    :ok
  end

  def producer_table_name(client, topic, partition),
    do: :"producer.#{client}.#{topic}.#{partition}"

  def maybe_init_produced_records_counter(topic, partition) do
    case get_produced_records_counter(topic, partition) do
      nil -> :persistent_term.put({__MODULE__, :counter, topic, partition}, :atomics.new(1, []))
      _ref -> :noop
    end

    :ok
  end

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

      spec = %{
        id: {cg_name, cg_mod},
        start: {cg_mod, :start_link, [opts]},
        restart: :transient,
        type: :worker
      }

      :ets.insert(:engine_support, {{cg_name, cg_mod}, opts})

      {:ok, pid} = DynamicSupervisor.start_child(sup_pid, spec)
    end
  end

  def get_cg_config(cg_name, cg_mod) do
    :ets.lookup(:engine_support, {cg_name, cg_mod})
    |> List.first()
    |> elem(1)
  end
end
