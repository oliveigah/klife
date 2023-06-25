defmodule Klife.Connection.BrokerTest do
  use ExUnit.Case

  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages

  @cluster_name :my_cluster_1
  use Retry

  setup_all do
    wait constant_backoff(50) |> expiry(1_000) do
      :persistent_term.get({:known_brokers_ids, @cluster_name}, false)
    end

    :ok
  end

  test "sends synchronous message" do
    {:ok, response} = Broker.send_message_sync(Messages.ApiVersions, 0, @cluster_name, :any)
    assert is_list(response.content.api_keys)
  end

  test "sends asynchronous message" do
    assert :ok == Broker.send_message_async(Messages.ApiVersions, 0, @cluster_name, :any)
  end
end
