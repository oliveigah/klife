defmodule Klife.PubSub do
  def start_link() do
    Registry.start_link(
      name: __MODULE__,
      keys: :duplicate,
      partitions: System.schedulers_online()
    )
  end

  def child_spec(_) do
    Supervisor.child_spec(
      Registry,
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    )
  end

  def subscribe(event, callback_data \\ nil) do
    case Registry.register(__MODULE__, event, callback_data) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  def unsubscribe(event) do
    Registry.unregister(__MODULE__, event)
  end

  def publish(event, event_data) do
    Registry.dispatch(__MODULE__, event, fn pids ->
      Enum.each(pids, fn {pid, callback_data} -> send(pid, {event, event_data, callback_data}) end)
    end)
  end
end
