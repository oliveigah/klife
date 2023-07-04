defmodule Klife.TestUtils do
  def wait_for_broker_connection(cluster_name, timeout \\ :timer.seconds(5)) do
    deadline = System.monotonic_time() + System.convert_time_unit(timeout, :millisecond, :native)
    do_wait_for_broker_connection(cluster_name, deadline)
  end

  defp do_wait_for_broker_connection(cluster_name, deadline) do
    if System.monotonic_time() <= deadline do
      case :persistent_term.get({:known_brokers_ids, cluster_name}, :not_found) do
        :not_found ->
          Process.sleep(50)
          do_wait_for_broker_connection(cluster_name, deadline)
        data ->
          data
      end
    else
      raise "timeout while waiting for broker connection"
    end
  end
end
