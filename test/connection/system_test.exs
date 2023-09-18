defmodule Klife.Connection.SystemTest do
  use ExUnit.Case
  alias Klife.Utils
  alias Klife.Connection.Broker
  alias KlifeProtocol.Messages.ApiVersions

  def check_broker_connection(cluster_name, broker_id) do
    parent = self()

    assert {:ok, response} = Broker.send_message(ApiVersions, cluster_name, broker_id)
    assert is_list(response.content.api_keys)

    assert :ok = Broker.send_message(ApiVersions, cluster_name, broker_id, %{}, %{}, async: true)

    assert :ok =
             Broker.send_message(ApiVersions, cluster_name, broker_id, %{}, %{},
               async: true,
               callback: fn _ ->
                 send(parent, {:ping, broker_id})
               end
             )

    assert_receive {:ping, ^broker_id}, :timer.seconds(2)
  end

  test "setup non ssl", %{test: test_name} do
    cluster_name = :"#{__MODULE__}.#{test_name}"

    input = [
      cluster_name: cluster_name,
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      socket_opts: [ssl: false]
    ]

    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input})

    brokers_list = Utils.wait_connection!(cluster_name)
    assert length(brokers_list) == 3

    Enum.each(brokers_list, &check_broker_connection(cluster_name, &1))
  end

  test "setup ssl", %{test: test_name} do
    cluster_name = :"#{__MODULE__}.#{test_name}"

    input = [
      cluster_name: cluster_name,
      bootstrap_servers: ["localhost:19093", "localhost:29093"],
      socket_opts: [
        ssl: true,
        ssl_opts: [
          verify: :verify_peer,
          cacertfile: Path.relative("test/compose_files/truststore/ca.crt")
        ]
      ]
    ]

    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input})

    brokers_list = Utils.wait_connection!(cluster_name)
    assert length(brokers_list) == 3

    Enum.each(brokers_list, &check_broker_connection(cluster_name, &1))
  end

  test "multiple clusters", %{test: test_name} do
    cluster_name_1 = :"#{__MODULE__}.#{test_name}_1"

    input_1 = [
      cluster_name: cluster_name_1,
      bootstrap_servers: ["localhost:19092", "localhost:29092"],
      socket_opts: [ssl: false]
    ]

    cluster_name_2 = :"#{__MODULE__}.#{test_name}_2"

    input_2 = [
      cluster_name: cluster_name_2,
      bootstrap_servers: ["localhost:19093", "localhost:29093"],
      socket_opts: [
        ssl: true,
        ssl_opts: [
          verify: :verify_peer,
          cacertfile: Path.relative("test/compose_files/truststore/ca.crt")
        ]
      ]
    ]

    cluster_name_3 = :"#{__MODULE__}.#{test_name}_3"

    input_3 = [
      cluster_name: cluster_name_3,
      bootstrap_servers: ["localhost:39092"],
      socket_opts: [ssl: false]
    ]

    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input_1})
    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input_2})
    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input_3})

    brokers_list_1 = Utils.wait_connection!(cluster_name_1)
    brokers_list_2 = Utils.wait_connection!(cluster_name_2)
    brokers_list_3 = Utils.wait_connection!(cluster_name_3)

    assert length(brokers_list_1) == 3
    assert length(brokers_list_2) == 3
    assert length(brokers_list_3) == 3

    Enum.each(brokers_list_1, &check_broker_connection(cluster_name_1, &1))
    Enum.each(brokers_list_2, &check_broker_connection(cluster_name_2, &1))
    Enum.each(brokers_list_3, &check_broker_connection(cluster_name_3, &1))
  end
end
