defmodule Klife.Producer.Supervisor do
  use Supervisor

  import Klife.ProcessRegistry

  def start_link(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(opts) do
    children = [
      {Klife.Producer.ProducerSupervisor, opts},
      {Klife.Producer.DispatcherSupervisor, opts},
      {Klife.Producer.Controller, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
