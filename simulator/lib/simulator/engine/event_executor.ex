defmodule Simulator.Engine.EventExecutor do
  use GenServer

  require Logger

  import Simulator.Engine.ProcessRegistry, only: [via_tuple: 1]

  alias Simulator.Engine
  alias Simulator.EngineConfig

  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Connection.Broker

  @loop_interval_ms :timer.seconds(10)

  @rollback_min_ms :timer.seconds(30)
  @rollback_max_ms :timer.seconds(120)
  @event_threshold 0.5

  @max_partitions 50

  @port_to_service_name %{
    19092 => "kafka1",
    19093 => "kafka1",
    19094 => "kafka1",
    29092 => "kafka2",
    29093 => "kafka2",
    29094 => "kafka2",
    39092 => "kafka3",
    39093 => "kafka3",
    39094 => "kafka3"
  }

  @actions [
    :kill_consumer_group,
    :stop_consumer_group,
    :add_partitions,
    :kill_broker
  ]

  defstruct pending_rollbacks: [], shutting_down: false

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__}))
  end

  def force_rollbacks do
    GenServer.call(via_tuple({__MODULE__}), :force_rollbacks, 120_000)
  end

  @broker_count @port_to_service_name |> Map.values() |> Enum.uniq() |> length()
  @broker_check_interval_ms :timer.seconds(1)
  @broker_check_timeout_ms :timer.seconds(90)

  def ensure_all_brokers do
    docker_compose_file = get_docker_compose_file()

    @port_to_service_name
    |> Map.values()
    |> Enum.uniq()
    |> Enum.each(fn service_name ->
      Logger.info("EventExecutor: ensuring broker #{service_name} is running")

      System.shell(
        "docker compose -f #{docker_compose_file} start #{service_name} > /dev/null 2>&1"
      )
    end)

    :ok = wait_for_broker(:all)
  end

  defp wait_for_broker(broker_id) do
    deadline = System.monotonic_time(:millisecond) + @broker_check_timeout_ms
    do_wait_for_broker(broker_id, deadline)
  end

  defp do_wait_for_broker(broker_id, deadline) do
    clients = [Simulator.NormalClient, Simulator.TLSClient]

    all_ready =
      Enum.all?(clients, fn client ->
        known = ConnController.get_known_brokers(client)

        case broker_id do
          :all -> length(known) >= @broker_count
          id -> id in known
        end
      end)

    cond do
      all_ready ->
        Logger.info("EventExecutor: broker #{inspect(broker_id)} detected on all clients")
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "EventExecutor: timed out waiting for broker #{inspect(broker_id)} to be detected"
        )

        :timeout

      true ->
        Process.sleep(@broker_check_interval_ms)
        do_wait_for_broker(broker_id, deadline)
    end
  end

  @impl true
  def init(_init_args) do
    %EngineConfig{random_seeds_map: seeds_map} = Engine.get_config()

    seed = Map.fetch!(seeds_map, :event_executor)

    :rand.seed(:exsss, seed)

    state = %__MODULE__{}

    Process.send_after(self(), :execute_loop, @loop_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:force_rollbacks, _from, %__MODULE__{} = state) do
    Logger.info("EventExecutor: Forcing rollback executions!")
    state = %{state | shutting_down: true}

    state =
      Enum.reduce(state.pending_rollbacks, state, fn {_time, action, args}, acc ->
        if action == :restart_broker do
          execute_rollback(action, args, acc)
        else
          acc
        end
      end)

    state = %{state | pending_rollbacks: []}

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:execute_loop, %__MODULE__{shutting_down: true} = state) do
    {:noreply, state}
  end

  def handle_info(:execute_loop, %__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    {to_rollback, remaining} =
      Enum.split_with(state.pending_rollbacks, fn {time, _action, _args} -> time <= now end)

    state =
      Enum.reduce(to_rollback, state, fn {_time, action, args}, acc ->
        execute_rollback(action, args, acc)
      end)

    state = %{state | pending_rollbacks: remaining}

    state =
      if :rand.uniform() >= @event_threshold do
        available_actions = filter_available_actions(@actions, state.pending_rollbacks)

        if available_actions != [] do
          action = Enum.random(available_actions)
          execute_action(action, state)
        else
          state
        end
      else
        state
      end

    Process.send_after(self(), :execute_loop, @loop_interval_ms)
    {:noreply, state}
  end

  defp schedule_rollback(%__MODULE__{} = state, action, args) do
    rollback_delay = Enum.random(@rollback_min_ms..@rollback_max_ms)
    rollback_time = System.monotonic_time(:millisecond) + rollback_delay

    Logger.info("EventExecutor: scheduled rollback #{action} in #{div(rollback_delay, 1000)}s")

    %{state | pending_rollbacks: [{rollback_time, action, args} | state.pending_rollbacks]}
  end

  defp log_event(type, action, details) do
    ts = NaiveDateTime.local_now()
    line = "#{ts} [#{type}] #{action} #{inspect(details)}\n"

    sim_ts = :persistent_term.get(:simulation_timestamp)
    path = Path.relative("simulations_data/#{sim_ts}/events.log")
    File.write!(path, line, [:append])
  end

  defp filter_available_actions(actions, pending_rollbacks) do
    has_broker_rollback =
      Enum.any?(pending_rollbacks, fn {_time, action, _args} -> action == :restart_broker end)

    consumer_group_rollback_count =
      Enum.count(pending_rollbacks, fn {_time, action, _args} ->
        action == :restart_consumer_group
      end)

    Enum.filter(actions, fn
      :kill_broker ->
        not has_broker_rollback

      action when action in [:kill_consumer_group, :stop_consumer_group] ->
        consumer_group_rollback_count < 2

      _action ->
        true
    end)
  end

  # Actions

  defp execute_action(:kill_consumer_group, %__MODULE__{} = state) do
    %EngineConfig{consumer_group_configs: cg_configs} = Engine.get_config()

    chosen = Enum.random(cg_configs)

    cg_mod = chosen[:cg_mod]
    client = chosen[:client]
    group_name = chosen[:group_name]

    name =
      {:via, Registry,
       {Klife.ProcessRegistry, {Klife.Consumer.ConsumerGroup, client, cg_mod, group_name}}}

    case GenServer.whereis(name) do
      nil ->
        Logger.info("EventExecutor: kill_consumer_group - #{inspect(cg_mod)} not found, skipping")
        state

      pid ->
        Logger.info(
          "EventExecutor: kill_consumer_group - terminating #{inspect(cg_mod)} (group=#{group_name})"
        )

        Process.exit(pid, :kill)
        log_event(:action, :kill_consumer_group, %{cg_mod: cg_mod, group_name: group_name})
        schedule_rollback(state, :restart_consumer_group, chosen)
    end
  end

  defp execute_action(:stop_consumer_group, %__MODULE__{} = state) do
    %EngineConfig{consumer_group_configs: cg_configs} = Engine.get_config()

    chosen = Enum.random(cg_configs)

    cg_mod = chosen[:cg_mod]
    client = chosen[:client]
    group_name = chosen[:group_name]

    name =
      {:via, Registry,
       {Klife.ProcessRegistry, {Klife.Consumer.ConsumerGroup, client, cg_mod, group_name}}}

    case GenServer.whereis(name) do
      nil ->
        Logger.info("EventExecutor: stop_consumer_group - #{inspect(cg_mod)} not found, skipping")
        state

      pid ->
        Logger.info(
          "EventExecutor: stop_consumer_group - gracefully stopping #{inspect(cg_mod)} (group=#{group_name})"
        )

        GenServer.stop(pid, :normal)
        log_event(:action, :stop_consumer_group, %{cg_mod: cg_mod, group_name: group_name})
        schedule_rollback(state, :restart_consumer_group, chosen)
    end
  end

  defp execute_action(:add_partitions, %__MODULE__{} = state) do
    %EngineConfig{topics: topics, clients: clients} = Engine.get_config()

    %{topic: topic} = Enum.random(topics)
    current_count = Engine.get_partition_count(topic)
    new_count = current_count + Enum.random(1..3)

    if new_count > @max_partitions do
      Logger.info(
        "EventExecutor: add_partitions - #{topic} already at #{current_count} partitions (max #{@max_partitions}), skipping"
      )

      state
    else
      client = Enum.random(clients)

      content = %{
        topics: [
          %{
            name: topic,
            count: new_count,
            assignments: nil
          }
        ],
        timeout_ms: 15_000,
        validate_only: false
      }

      # Create engine resources before the Kafka request so that
      # producers/consumers don't hit missing tables if Kafka creates
      # the partitions before update_partition_count completes.
      :ok = Engine.update_partition_count(topic, new_count)

      case Klife.Connection.Broker.send_message(
             KlifeProtocol.Messages.CreatePartitions,
             client,
             :controller,
             content
           ) do
        {:ok, %{content: %{results: [%{error_code: 0}]}}} ->
          Logger.info(
            "EventExecutor: add_partitions - #{topic} from #{current_count} to #{new_count} partitions"
          )

          log_event(:action, :add_partitions, %{
            topic: topic,
            old_count: current_count,
            new_count: new_count
          })

        {:ok, %{content: %{results: [%{error_code: code, error_message: msg}]}}} ->
          Logger.warning(
            "EventExecutor: add_partitions - failed for #{topic}: error_code=#{code} message=#{msg}"
          )

          log_event(:action, :add_partitions, %{
            topic: topic,
            result: {:error, code, msg}
          })

        {:error, reason} ->
          Logger.warning(
            "EventExecutor: add_partitions - request failed for #{topic}: #{inspect(reason)}"
          )
      end

      state
    end
  end

  defp execute_action(:kill_broker, %__MODULE__{} = state) do
    %EngineConfig{clients: clients} = Engine.get_config()

    client = Enum.random(clients)
    broker_ids = ConnController.get_known_brokers(client)

    case broker_ids do
      [] ->
        Logger.info("EventExecutor: kill_broker - no known brokers, skipping")
        state

      _ ->
        broker_id = Enum.random(broker_ids)

        {:ok, service_name} = do_stop_broker(client, broker_id)

        Logger.info("EventExecutor: kill_broker - broker #{broker_id} (#{service_name}) stopped")

        log_event(:action, :kill_broker, %{
          broker_id: broker_id,
          service_name: service_name
        })

        schedule_rollback(state, :restart_broker, %{
          service_name: service_name,
          broker_id: broker_id
        })
    end
  end

  defp do_stop_broker(client_name, broker_id) do
    service_name = get_service_name(client_name, broker_id)

    System.shell(
      "docker compose -f #{get_docker_compose_file()} stop #{service_name} > /dev/null 2>&1"
    )

    {:ok, service_name}
  end

  defp do_start_broker(service_name) do
    System.shell(
      "docker compose -f #{get_docker_compose_file()} start #{service_name} > /dev/null 2>&1"
    )

    :ok
  end

  defp get_service_name(client_name, broker_id) do
    content = %{
      include_topic_authorized_operations: true,
      topics: [],
      allow_auto_topic_creation: false
    }

    {:ok, resp} =
      Broker.send_message(KlifeProtocol.Messages.Metadata, client_name, :any, content)

    broker = Enum.find(resp.content.brokers, fn b -> b.node_id == broker_id end)

    Map.fetch!(@port_to_service_name, broker.port)
  end

  defp get_docker_compose_file do
    vsn = "4.1"
    Path.relative("../test/compose_files/docker-compose-kafka-#{vsn}.yml")
  end

  # Rollbacks

  defp execute_rollback(:restart_consumer_group, opts, %__MODULE__{} = state) do
    cg_mod = opts[:cg_mod]
    group_name = opts[:group_name]

    Logger.info(
      "EventExecutor: restart_consumer_group - restarting #{inspect(cg_mod)} (group=#{group_name})"
    )

    case Engine.init_consumer_group(opts) do
      {:ok, _pid} ->
        Logger.info("EventExecutor: restart_consumer_group - #{inspect(cg_mod)} restarted")

        log_event(:rollback, :restart_consumer_group, %{
          cg_mod: cg_mod,
          group_name: group_name,
          result: :ok
        })

      {:error, reason} ->
        Logger.warning(
          "EventExecutor: restart_consumer_group - failed to restart #{inspect(cg_mod)}: #{inspect(reason)}"
        )

        log_event(:rollback, :restart_consumer_group, %{
          cg_mod: cg_mod,
          group_name: group_name,
          result: {:error, reason}
        })
    end

    state
  end

  defp execute_rollback(:restart_broker, args, %__MODULE__{} = state) do
    %{service_name: service_name, broker_id: broker_id} = args

    Logger.info(
      "EventExecutor: restart_broker - restarting #{service_name} (broker=#{broker_id})"
    )

    :ok = do_start_broker(service_name)

    Logger.info(
      "EventExecutor: restart_broker - #{service_name} restarted, waiting for detection"
    )

    :ok = wait_for_broker(broker_id)

    log_event(:rollback, :restart_broker, %{
      broker_id: broker_id,
      service_name: service_name,
      result: :ok
    })

    state
  end
end
