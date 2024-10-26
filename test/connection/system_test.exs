defmodule Klife.Connection.SystemTest do
  use ExUnit.Case
  alias Klife.Utils
  alias Klife.PubSub
  alias Klife.TestUtils
  alias Klife.Connection.Broker
  alias Klife.Connection.MessageVersions, as: MV
  alias KlifeProtocol.Messages.ApiVersions

  defp check_broker_connection(client_name, broker_id) do
    parent = self()
    ref = make_ref()

    assert {:ok, %{content: resp_content}} =
             Broker.send_message(ApiVersions, client_name, broker_id)

    assert is_list(resp_content.api_keys)

    assert :ok = Broker.send_message(ApiVersions, client_name, broker_id, %{}, %{}, async: true)

    assert :ok =
             Broker.send_message(ApiVersions, client_name, broker_id, %{}, %{},
               async: true,
               callback_pid: parent,
               callback_ref: ref
             )

    mv = MV.get(client_name, ApiVersions)

    assert_receive({:async_broker_response, ^ref, binary_resp, ApiVersions, ^mv}, 200)

    assert {:ok, %{content: ^resp_content}} = ApiVersions.deserialize_response(binary_resp, mv)
  end

  test "setup non ssl", %{test: test_name} do
    client_name = :"#{__MODULE__}.#{test_name}"

    input =
      [
        client_name: client_name,
        bootstrap_servers: ["localhost:19092", "localhost:29092"],
        ssl: false,
        connect_opts: [],
        socket_opts: [],
        sasl_opts: []
      ]
      |> Map.new()

    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input})

    brokers_list = Utils.get_brokers(client_name)
    assert length(brokers_list) == 3

    Enum.each(brokers_list, &check_broker_connection(client_name, &1))
  end

  test "setup ssl", %{test: test_name} do
    client_name = :"#{__MODULE__}.#{test_name}"

    input =
      [
        client_name: client_name,
        bootstrap_servers: ["localhost:19093", "localhost:29093"],
        ssl: true,
        connect_opts: [
          verify: :verify_peer,
          cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
        ],
        socket_opts: [
          delay_send: true
        ],
        sasl_opts: []
      ]
      |> Map.new()

    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input})

    brokers_list = Utils.get_brokers(client_name)
    assert length(brokers_list) == 3

    Enum.each(brokers_list, &check_broker_connection(client_name, &1))
  end

  test "setup ssl with sasl auth", %{test: test_name} do
    client_name = :"#{__MODULE__}.#{test_name}"

    input =
      [
        client_name: client_name,
        bootstrap_servers: ["localhost:19094", "localhost:29094"],
        ssl: true,
        connect_opts: [
          verify: :verify_peer,
          cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
        ],
        socket_opts: [
          delay_send: true
        ],
        sasl_opts: [
          mechanism: "PLAIN",
          mechanism_opts: [
            username: "klifeusr",
            password: "klifepwd"
          ]
        ]
      ]
      |> Map.new()

    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input})

    brokers_list = Utils.get_brokers(client_name)
    assert length(brokers_list) == 3

    Enum.each(brokers_list, &check_broker_connection(client_name, &1))
  end

  test "multiple clients", %{test: test_name} do
    client_name_1 = :"#{__MODULE__}.#{test_name}_1"

    input_1 =
      [
        client_name: client_name_1,
        bootstrap_servers: ["localhost:19092", "localhost:29092"],
        ssl: false,
        connect_opts: [],
        socket_opts: [],
        sasl_opts: []
      ]
      |> Map.new()

    client_name_2 = :"#{__MODULE__}.#{test_name}_2"

    input_2 =
      [
        client_name: client_name_2,
        bootstrap_servers: ["localhost:19093", "localhost:29093"],
        ssl: true,
        connect_opts: [
          verify: :verify_peer,
          cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
        ],
        socket_opts: [
          delay_send: true
        ],
        sasl_opts: []
      ]
      |> Map.new()

    client_name_3 = :"#{__MODULE__}.#{test_name}_3"

    input_3 =
      [
        client_name: client_name_3,
        bootstrap_servers: ["localhost:19092", "localhost:29092"],
        ssl: false,
        connect_opts: [],
        socket_opts: [],
        sasl_opts: []
      ]
      |> Map.new()

    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input_1})
    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input_2})
    assert {:ok, _pid} = start_supervised({Klife.Connection.Supervisor, input_3})

    brokers_list_1 = Utils.get_brokers(client_name_1)
    brokers_list_2 = Utils.get_brokers(client_name_2)
    brokers_list_3 = Utils.get_brokers(client_name_3)

    assert length(brokers_list_1) == 3
    assert length(brokers_list_2) == 3
    assert length(brokers_list_3) == 3

    Enum.each(brokers_list_1, &check_broker_connection(client_name_1, &1))
    Enum.each(brokers_list_2, &check_broker_connection(client_name_2, &1))
    Enum.each(brokers_list_3, &check_broker_connection(client_name_3, &1))
  end

  @tag cluster_change: true, capture_log: true
  test "cluster changes events" do
    config = [
      connection: [
        bootstrap_servers: ["localhost:19092", "localhost:29092"],
        ssl: false
      ],
      topics: [
        [
          name: "crazy_test_topic"
        ]
      ]
    ]

    Application.put_env(:klife, __MODULE__.MyOtherClient, config)

    defmodule MyOtherClient do
      use Klife.Client, otp_app: :klife
    end

    client_name = __MODULE__.MyOtherClient

    assert {:ok, _pid} = start_supervised(client_name)

    :ok = TestUtils.wait_client(client_name, 3)

    brokers = :persistent_term.get({:known_brokers_ids, client_name})
    broker_id_to_remove = List.first(brokers)
    cb_ref = make_ref()

    :ok = PubSub.subscribe({:cluster_change, client_name}, %{some_data: cb_ref})

    {:ok, service_name} = TestUtils.stop_broker(client_name, broker_id_to_remove)

    assert_receive({{:cluster_change, ^client_name}, event_data, %{some_data: ^cb_ref}}, 200)
    assert broker_id_to_remove in Enum.map(event_data.removed_brokers, fn {b, _h} -> b end)
    assert broker_id_to_remove not in :persistent_term.get({:known_brokers_ids, client_name})

    {:ok, broker_id} = TestUtils.start_broker(service_name, client_name)

    assert_receive({{:cluster_change, ^client_name}, event_data, %{some_data: ^cb_ref}}, 200)
    assert broker_id in Enum.map(event_data.added_brokers, fn {b, _h} -> b end)
    assert broker_id in :persistent_term.get({:known_brokers_ids, client_name})

    :ok = PubSub.unsubscribe({:cluster_change, client_name})
  end
end
