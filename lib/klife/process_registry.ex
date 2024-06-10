defmodule Klife.ProcessRegistry do
  @moduledoc false

  def start_link() do
    Registry.start_link(name: __MODULE__, keys: :unique, partitions: System.schedulers_online())
  end

  def child_spec(_) do
    Supervisor.child_spec(
      Registry,
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    )
  end

  def via_tuple(key), do: {:via, Registry, {__MODULE__, key}}

  def registry_lookup(key), do: Registry.lookup(__MODULE__, key)
end
