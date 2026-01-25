defmodule Simulator.MultiRunner do
  use GenServer, restart: :transient
  require Logger

  @run_timeout_ms :timer.minutes(10)
  @total_timeout_ms :timer.hours(15)
  @check_interval_ms :timer.seconds(5)

  defstruct [
    :engine_pid,
    :run_start_time,
    :total_start_time,
    :run_count,
    :engine_monitor_ref,
    :sup_pid
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, sup_pid} = DynamicSupervisor.start_link([])

    state = %__MODULE__{
      run_count: 0,
      total_start_time: System.monotonic_time(:millisecond),
      sup_pid: sup_pid
    }

    send(self(), :start_engine)

    {:ok, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %__MODULE__{engine_pid: pid, engine_monitor_ref: ref} = state
      ) do
    send(self(), :start_engine)
    new_state = %{state | engine_pid: nil, engine_monitor_ref: nil, run_start_time: nil}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:start_engine, %__MODULE__{} = state) do
    total_elapsed = System.monotonic_time(:millisecond) - state.total_start_time

    if total_elapsed >= @total_timeout_ms do
      Logger.info(
        "MultiRunner: Total timeout reached, shutting down after #{state.run_count} runs"
      )

      {:stop, :normal, state}
    else
      run_count = state.run_count + 1
      Logger.info("MultiRunner: Starting run ##{run_count}")

      spec = %{
        id: :simulation,
        start: {Simulator.Engine, :start_link, [[]]},
        restart: :transient,
        type: :worker
      }

      {:ok, engine_pid} = DynamicSupervisor.start_child(state.sup_pid, spec)

      ref = Process.monitor(engine_pid)

      state = %{
        state
        | engine_pid: engine_pid,
          run_start_time: System.monotonic_time(:millisecond),
          run_count: run_count,
          engine_monitor_ref: ref
      }

      Process.send_after(self(), :check_status, @check_interval_ms)
      {:noreply, state}
    end
  end

  def handle_info(:check_status, %__MODULE__{} = state) do
    run_elapsed = System.monotonic_time(:millisecond) - state.run_start_time
    violations_count = get_violations_count()
    cpu_usage = get_cpu_usage()

    Logger.info("MultiRunner: CPU usage: #{cpu_usage}%")

    cond do
      violations_count > 0 ->
        Logger.info(
          "MultiRunner: Found #{violations_count} invariant violations, stopping run ##{state.run_count}"
        )

        # Give some time to have more error datapoints
        Process.sleep(15_000)

        :ok = Simulator.Engine.terminate()

        {:noreply, state}

      run_elapsed >= @run_timeout_ms ->
        Logger.info("MultiRunner: Run timeout reached, stopping run ##{state.run_count}")

        :ok = Simulator.Engine.terminate()

        {:noreply, state}

      true ->
        Process.send_after(self(), :check_status, @check_interval_ms)
        {:noreply, state}
    end
  end

  defp get_violations_count do
    case :ets.whereis(:invariants_violations) do
      :undefined -> 0
      _ref -> :ets.info(:invariants_violations, :size)
    end
  end

  defp get_cpu_usage do
    case apply(:cpu_sup, :util, []) do
      {:error, _reason} -> "N/A"
      usage when is_number(usage) -> Float.round(usage, 1)
    end
  end
end
