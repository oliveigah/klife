defmodule Klife.Connection.Supervisor do
  use Supervisor

  import Klife.ProcessRegistry

  def start_link(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(opts) do
    children = [
      {Klife.Connection.BrokerSupervisor, opts},
      {Klife.Connection.Controller, opts},
      {Task.Supervisor, name: Klife.Connection.CallbackSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
