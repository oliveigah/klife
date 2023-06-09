defmodule Klife.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @opts [
    cluster_name: :my_cluster_1,
    connection: [
      bootstrap_servers: ["localhost:29092", "localhost:29093"],
      socket_opts: [
        ssl: true,
        ssl_opts: [
          verify: :verify_peer,
          cacertfile: Path.relative("test/compose_files/truststore/ca.crt")
        ]
      ]
    ]
  ]

  @impl true
  def start(_type, _args) do
    children = [
      Klife.ProcessRegistry,
      {Klife.Connection.Supervisor, [{:cluster_name, @opts[:cluster_name]} | @opts[:connection]]}
      # Starts a worker by calling: Klife.Worker.start_link(arg)
      # {Klife.Worker, arg}
      # {Klife.Connection.Controller, [bootstrap_servers: @servers]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Klife.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
