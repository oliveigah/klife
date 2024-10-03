defmodule Klife.Producer.ProducerSupervisor do
  @moduledoc false

  use DynamicSupervisor

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts,
      name: via_tuple({__MODULE__, opts[:client_name]})
    )
  end

  @impl true
  def init(init_arg) do
    max_restarts =
      init_arg[:txn_pools]
      |> Enum.map(fn %{pool_size: p} -> p end)
      |> Enum.sum()

    DynamicSupervisor.init(
      strategy: :one_for_one,
      # Since the strategy for handle txn coordinator changes
      # is to restart the producer and we may have a very large
      # number of txn producers, we need to accomodate a restart
      # for each producer in order to prevent system crash in
      # the worst case scenario.
      max_restarts: max_restarts + 1,
      max_seconds: 10
    )

    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
