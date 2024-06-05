defmodule Klife.Connection.SystemTest do
  use ExUnit.Case
  alias Klife.Utils
  alias Klife.PubSub
  alias Klife.TestUtils
  alias Klife.Connection.Broker
  alias Klife.Connection.MessageVersions, as: MV
  alias KlifeProtocol.Messages.ApiVersions

  defp check_broker_connection(cluster_name, broker_id) do
    parent = self()
    ref = make_ref()

    assert {:ok, %{content: resp_content}} =
             Broker.send_message(ApiVersions, cluster_name, broker_id)

    assert is_list(resp_content.api_keys)

    assert :ok = Broker.send_message(ApiVersions, cluster_name, broker_id, %{}, %{}, async: true)

    assert :ok =
             Broker.send_message(ApiVersions, cluster_name, broker_id, %{}, %{},
               async: true,
               callback_pid: parent,
               callback_ref: ref
             )

    mv = MV.get(cluster_name, ApiVersions)

    assert_receive {:async_broker_response, ^ref, binary_resp, ApiVersions, ^mv}

    assert {:ok, %{content: ^resp_content}} = ApiVersions.deserialize_response(binary_resp, mv)
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
          cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
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
          cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
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

  @tag :cluster_change
  test "cluster changes events" do
    cluster_name = :my_test_cluster_1
    brokers = :persistent_term.get({:known_brokers_ids, cluster_name})
    broker_id_to_remove = List.first(brokers)
    cb_ref = make_ref()

    :ok = PubSub.subscribe({:cluster_change, cluster_name}, %{some_data: cb_ref})

    {:ok, service_name} = TestUtils.stop_broker(cluster_name, broker_id_to_remove)

    assert_received({{:cluster_change, ^cluster_name}, event_data, %{some_data: ^cb_ref}})
    assert broker_id_to_remove in Enum.map(event_data.removed_brokers, fn {b, _h} -> b end)
    assert broker_id_to_remove not in :persistent_term.get({:known_brokers_ids, cluster_name})

    {:ok, broker_id} = TestUtils.start_broker(service_name, cluster_name)

    assert_received({{:cluster_change, ^cluster_name}, event_data, %{some_data: ^cb_ref}})
    assert broker_id in Enum.map(event_data.added_brokers, fn {b, _h} -> b end)
    assert broker_id in :persistent_term.get({:known_brokers_ids, cluster_name})

    :ok = PubSub.unsubscribe({:cluster_change, cluster_name})
  end
end
