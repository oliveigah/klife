defmodule Simulator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    engine_child =
      if System.get_env("MULTI_RUN") == "true",
        do: Simulator.MultiRunner,
        else: Simulator.Engine

    children = [
      Simulator.NormalClient,
      Simulator.TLSClient,
      engine_child
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Simulator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
