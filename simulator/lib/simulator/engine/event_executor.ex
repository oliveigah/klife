defmodule Simulator.Engine.EventExecutor do
  use GenServer

  require Logger

  import Simulator.Engine.ProcessRegistry, only: [via_tuple: 1]

  alias Simulator.Engine
  alias Simulator.EngineConfig

  @loop_interval_ms :timer.seconds(10)

  @rollback_min_ms :timer.seconds(30)
  @rollback_max_ms :timer.seconds(180)
  @event_threshold 0.7

  @max_partitions 50

  @actions [
    :kill_consumer_group,
    :stop_consumer_group,
    :add_partitions
  ]

  defstruct pending_rollbacks: []

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__}))
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
  def handle_info(:execute_loop, %__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    {to_rollback, remaining} =
      Enum.split_with(state.pending_rollbacks, fn {time, _action, _args} -> time <= now end)

    state =
      Enum.reduce(to_rollback, state, fn {_time, action, args}, acc ->
        execute_rollback(action, args, acc)
      end)

    state = %{state | pending_rollbacks: remaining}

    # TODO: Think how to keep invariants with unbounded events
    # Im bounding to 2 active events because the min amount of consumers
    # is 3, but we probaly need to find a better way to do this. Maybe
    # filter possible events basend on active events, so we can do
    # somehting like no kill broker event if another broker is already
    # dead, and so on
    state =
      if :rand.uniform() >= @event_threshold and length(state.pending_rollbacks) < 2 do
        action = Enum.random(@actions)
        execute_action(action, state)
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
end
