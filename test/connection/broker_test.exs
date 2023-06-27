defmodule Klife.Connection.BrokerTest do
  use ExUnit.Case

  alias Klife.Connection.Broker
  alias Klife.TestUtils
  alias KlifeProtocol.Messages

  @cluster_name :my_cluster_1

  setup_all do
    TestUtils.wait_for_broker_connection(@cluster_name)
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
