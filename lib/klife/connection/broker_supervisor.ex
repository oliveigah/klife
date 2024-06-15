defmodule Klife.Connection.BrokerSupervisor do
  @moduledoc false

  use DynamicSupervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts,
      name: via_tuple({__MODULE__, opts[:client_name]})
    )
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
