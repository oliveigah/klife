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
      Klife.PubSub,
      handle_clusters()
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Klife.Supervisor]
    Supervisor.start_link(List.flatten(children), opts)
  end

  defp handle_clusters() do
    [
      Klife.MyCluster
    ]
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
