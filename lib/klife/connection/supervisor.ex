defmodule Klife.Connection.Supervisor do
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
      {Klife.Connection.BrokerSupervisor, opts},
      {Klife.Connection.Controller, opts},
      {Task.Supervisor, name: via_tuple({Klife.Connection.CallbackSupervisor, cluster_name})}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def child_spec(init_arg) do
    cluster_name = Keyword.fetch!(init_arg, :cluster_name)

    %{
      id: {__MODULE__, cluster_name},
      start: {__MODULE__, :start_link, [init_arg]},
      type: :supervisor
    }
  end
end
