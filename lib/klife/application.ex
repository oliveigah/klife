defmodule Klife.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # TODO: Refactor and rethink auto topic creation feature
    create_topics()

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
      conn_opts = [{:cluster_name, cluster_name} | cluster_opts[:connection]]
      producer_opts = Keyword.delete(cluster_opts, :connection)

      [
        {Klife.Connection.Supervisor, conn_opts},
        {Klife.Producer.Supervisor, producer_opts}
      ]
    end)
  end

  defp create_topics() do
    do_create_topics(System.monotonic_time())
  end

  defp do_create_topics(init_time) do
    case Klife.Utils.create_topics!() do
      :ok ->
        :ok

      :error ->
        now = System.monotonic_time(:millisecond)

        if now - init_time > :timer.seconds(15) do
          raise "Timeout while creating topics"
        else
          do_create_topics(init_time)
        end
    end
  end
end
