defmodule Klife.Producer.DispatcherSupervisor do
  use DynamicSupervisor

  import Klife.ProcessRegistry

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts,
      name: via_tuple({__MODULE__, opts[:cluster_name]})
    )
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
