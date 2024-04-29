defmodule Klife.Producer.Supervisor do
  use Supervisor

  import Klife.ProcessRegistry

  def start_link(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)

    children = [
      {Task.Supervisor, name: via_tuple({Klife.Producer.BatcherTaskSupervisor, cluster_name})},
      {Klife.Producer.ProducerSupervisor, opts},
      {Klife.Producer.BatcherSupervisor, opts},
      {Klife.Producer.Controller, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
