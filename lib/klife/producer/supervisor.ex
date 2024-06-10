defmodule Klife.Producer.Supervisor do
  @moduledoc false

  use Supervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  def start_link(opts) do
    cluster_name = Keyword.fetch!(opts, :cluster_name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(opts) do
    children = [
      {Klife.Producer.ProducerSupervisor, opts},
      {Klife.Producer.Controller, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
