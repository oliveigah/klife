defmodule Klife.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Klife.ProcessRegistry,
      handle_clusters()
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Klife.Supervisor]
    Supervisor.start_link(List.flatten(children), opts)
  end

  defp handle_clusters() do
    :klife
    |> Application.fetch_env!(:clusters)
    |> Enum.map(fn cluster_opts ->
      cluster_name = Keyword.fetch!(cluster_opts, :cluster_name)

      [
        {Klife.Connection.Supervisor, [{:cluster_name, cluster_name} | cluster_opts[:connection]]},
        {Klife.Producer.Supervisor, cluster_opts}
      ]
    end)
  end
end
