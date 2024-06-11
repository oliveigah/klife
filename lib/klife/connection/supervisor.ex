defmodule Klife.Connection.Supervisor do
  @moduledoc false

  use Supervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  def start_link(args) do
    cluster_name = args.cluster_name
    Supervisor.start_link(__MODULE__, args, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(opts) do
    children = [
      {Klife.Connection.BrokerSupervisor, opts},
      {Klife.Connection.Controller, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def child_spec(init_arg) do
    %{
      id: {__MODULE__, init_arg.cluster_name},
      start: {__MODULE__, :start_link, [init_arg]},
      type: :supervisor
    }
  end
end
