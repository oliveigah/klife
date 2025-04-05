defmodule Klife.Consumer.Supervisor do
  @moduledoc false

  use Supervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: via_tuple({__MODULE__, args.client_name}))
  end

  @impl true
  def init(args) do
    children =
      [
        handle_fetchers(args)
      ]

    Supervisor.init(List.flatten(children), strategy: :one_for_all)
  end

  defp handle_fetchers(args) do
    for fetcher_conf <- args.fetchers do
      opts = Map.put(fetcher_conf, :client_name, args.client_name)

      {Klife.Consumer.Fetcher, opts}
    end
  end
end
