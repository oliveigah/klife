defmodule Klife.Connection.Supervisor do
  @moduledoc false

  use Supervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  def start_link(args) do
    client_name = args.client_name
    Supervisor.start_link(__MODULE__, args, name: via_tuple({__MODULE__, client_name}))
  end

  @impl true
  def init(opts) do
    children = [
      {Klife.Connection.BrokerSupervisor, opts},
      {Klife.Connection.Controller, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def child_spec(init_arg) do
    %{
      id: {__MODULE__, init_arg.client_name},
      start: {__MODULE__, :start_link, [init_arg]},
      type: :supervisor
    }
  end
end
