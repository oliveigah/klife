defmodule Klife.Producer.Supervisor do
  @moduledoc false

  use Supervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: via_tuple({__MODULE__, args.cluster_name}))
  end

  @impl true
  def init(args) do
    children = [
      {Klife.Producer.ProducerSupervisor, args},
      {Klife.Producer.Controller, args}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
