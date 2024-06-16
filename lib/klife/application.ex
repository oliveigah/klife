defmodule Klife.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Klife.ProcessRegistry,
      Klife.PubSub
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Klife.Supervisor]
    Supervisor.start_link(List.flatten(children), opts)
  end
end
