defmodule Klife.TestUtils do
  use Retry

  def wait_for_broker_connection(cluster_name) do
    wait constant_backoff(50) |> expiry(1_000) do
      :persistent_term.get({:known_brokers_ids, cluster_name}, false)
    end

    :ok
  end
end
