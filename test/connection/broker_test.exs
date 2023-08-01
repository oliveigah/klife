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
    {:ok, response} = Broker.send_message_sync(Messages.ApiVersions, @cluster_name, :any)
    assert is_list(response.content.api_keys)
  end

  test "sends asynchronous message" do
    pid = self()

    assert :ok ==
             Broker.send_message_async(
               Messages.ApiVersions,
               @cluster_name,
               :any,
               %{},
               %{},
               fn -> send(pid, :written_to_socket) end
             )

    assert_receive :written_to_socket, 1_000
  end
end
