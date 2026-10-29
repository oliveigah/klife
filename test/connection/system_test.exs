defmodule Klife.Connection.SystemTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Klife.Utils
  alias Klife.PubSub
  alias Klife.TestUtils
  alias Klife.Connection.Broker
  alias Klife.Connection.MessageVersions, as: MV
  alias KlifeProtocol.Messages.ApiVersions
  alias Klife.ProcessRegistry
  alias Klife.Connection.Controller, as: ConnController

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

    assert_receive({:async_broker_response, ^ref, binary_resp, ApiVersions, ^mv}, 1000)

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
        sasl_opts: [],
        connection_count: 1,
        default_request_timeout_ms: 30_000
      ]
      |> Map.new()

    assert {:ok, _pid} = start_supervised({Klife.Connection.Controller, input})

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
        sasl_opts: [],
        connection_count: 1,
        default_request_timeout_ms: 30_000
      ]
      |> Map.new()

    assert {:ok, _pid} = start_supervised({Klife.Connection.Controller, input})

    brokers_list = Utils.get_brokers(client_name)
    assert length(brokers_list) == 3

    Enum.each(brokers_list, &check_broker_connection(client_name, &1))
  end

  for mechanism <- ["PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512"] do
    test "setup ssl with sasl #{mechanism} auth", %{test: test_name} do
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
            mechanism: unquote(mechanism),
            mechanism_opts: [
              username: "klifeusr",
              password: "klifepwd"
            ]
          ],
          connection_count: 1,
          default_request_timeout_ms: 30_000
        ]
        |> Map.new()

      assert {:ok, _pid} = start_supervised({Klife.Connection.Controller, input})

      brokers_list = Utils.get_brokers(client_name)
      assert length(brokers_list) == 3

      Enum.each(brokers_list, &check_broker_connection(client_name, &1))
    end
  end

  # Brokers without a configured validator accept unsecured JWTs ("alg": "none"),
  # and OAUTHBEARER sessions end when their token expires
  def unsecured_jwt(expires_in_seconds) do
    exp = System.os_time(:second) + expires_in_seconds
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)
    claims = Base.url_encode64(~s({"sub":"klifeusr","exp":#{exp}}), padding: false)
    "#{header}.#{claims}."
  end

  defp oauth_input(client_name, token_seconds) do
    %{
      client_name: client_name,
      bootstrap_servers: ["localhost:19094", "localhost:29094"],
      ssl: true,
      connect_opts: [
        verify: :verify_peer,
        cacertfile: Path.relative("test/compose_files/ssl/ca.crt")
      ],
      socket_opts: [],
      sasl_opts: [
        mechanism: "OAUTHBEARER",
        mechanism_opts: [token_mfa: {__MODULE__, :unsecured_jwt, [token_seconds]}]
      ],
      connection_count: 2,
      # sessions must outlast it + 5s
      default_request_timeout_ms: 1_000
    }
  end

  defp check_connections_until(client_name, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Enum.each(Utils.get_brokers(client_name), &check_broker_connection(client_name, &1))
      check_connections_until(client_name, deadline)
    end
  end

  defp sockets(client_name, controller_pid) do
    broker_sockets =
      for broker_id <- Utils.get_brokers(client_name), idx <- 0..1 do
        :persistent_term.get({Broker, client_name, broker_id, idx}).socket
      end

    [:sys.get_state(controller_pid).bootstrap_conn.socket | broker_sockets]
  end

  @tag timeout: 60_000
  test "replaces connections before their sasl sessions end", %{test: test_name} do
    client_name = :"#{__MODULE__}.#{test_name}"

    # The test config silences every log, but the warning refuted below must be seen
    level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log(fn ->
        # 8s tokens: sessions of 7-8s, replaced every 6-7.6s, about twice in the 16s below
        pid = start_supervised!({ConnController, oauth_input(client_name, 8)})
        first_sockets = sockets(client_name, pid)

        # Many concurrent callers, so requests are in flight on every swap.
        # Any request sent on an expired session gets no reply and fails here
        deadline = System.monotonic_time(:millisecond) + 16_000

        1..20
        |> Enum.map(fn _ ->
          Task.async(fn -> check_connections_until(client_name, deadline) end)
        end)
        |> Task.await_many(:infinity)

        for {first, last} <- Enum.zip(first_sockets, sockets(client_name, pid)) do
          assert first != last
        end
      end)

    # An expired bootstrap connection is only noticed by failing the cluster check
    refute log =~ "will re-initialize bootstrap connection"
  end

  @tag capture_log: true
  test "refuses sasl sessions shorter than the request timeout + 5s", %{test: test_name} do
    client_name = :"#{__MODULE__}.#{test_name}"

    assert {:error, reason} = start_supervised({ConnController, oauth_input(client_name, 3)})
    assert inspect(reason) =~ "shorter than default_request_timeout_ms + 5000"
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
        sasl_opts: [],
        connection_count: 1,
        default_request_timeout_ms: 30_000
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
        sasl_opts: [],
        connection_count: 1,
        default_request_timeout_ms: 30_000
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
        sasl_opts: [],
        connection_count: 1,
        default_request_timeout_ms: 30_000
      ]
      |> Map.new()

    assert {:ok, _pid} = start_supervised({Klife.Connection.Controller, input_1})
    assert {:ok, _pid} = start_supervised({Klife.Connection.Controller, input_2})
    assert {:ok, _pid} = start_supervised({Klife.Connection.Controller, input_3})

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

  test "sync calls must not consume broker responses from other correlation ids" do
    client_name = MyClient
    broker_id = ConnController.get_known_brokers(client_name) |> List.first()

    # Simulates stale responses sitting on the mailbox, as left behind by a
    # previous call of this process that gave up waiting on them.
    stale_untagged = {:broker_response, <<0, 0, 0, 99, 1, 2, 3>>}
    stale_tagged = {:broker_response, 999_999_999, <<0, 0, 0, 99, 1, 2, 3>>}

    send(self(), stale_untagged)
    send(self(), stale_tagged)

    assert {:ok, %{content: resp_content}} =
             Broker.send_message(ApiVersions, client_name, broker_id)

    assert is_list(resp_content.api_keys)

    # The stale messages must remain untouched on the mailbox
    assert_receive ^stale_untagged, 0
    assert_receive ^stale_tagged, 0
  end

  @tag capture_log: true
  test "sync calls that time out do not leak responses to subsequent calls" do
    client_name = MyClient
    broker_id = ConnController.get_known_brokers(client_name) |> List.first()

    case Broker.send_message(ApiVersions, client_name, broker_id, %{}, %{}, timeout_ms: 0) do
      {:error, :timeout} ->
        :ok

      # If the response arrives while the timeout is being handled, it is
      # reaped and returned as a normal response instead of leaking to the
      # mailbox, so this outcome is also valid.
      {:ok, %{content: resp_content}} ->
        assert is_list(resp_content.api_keys)
    end

    assert {:ok, %{content: resp_content}} =
             Broker.send_message(ApiVersions, client_name, broker_id)

    assert is_list(resp_content.api_keys)

    refute_receive {:broker_response, _, _}, 200
    refute_receive {:broker_response, _}, 0
  end

  @tag cluster_change: true, capture_log: true, timeout: 90_000
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

    brokers = ConnController.get_known_brokers(client_name)
    broker_id_to_remove = List.first(brokers)
    cb_ref = make_ref()

    :ok = PubSub.subscribe({:cluster_change, client_name}, %{some_data: cb_ref})

    {:ok, service_name} = TestUtils.stop_broker(client_name, broker_id_to_remove)

    assert_receive({{:cluster_change, ^client_name}, event_data, %{some_data: ^cb_ref}}, 1000)
    assert broker_id_to_remove in Enum.map(event_data.removed_brokers, fn {b, _h} -> b end)
    assert broker_id_to_remove not in ConnController.get_known_brokers(client_name)

    {:ok, broker_id} = TestUtils.start_broker(service_name, client_name)

    assert_receive({{:cluster_change, ^client_name}, event_data, %{some_data: ^cb_ref}}, 1000)
    assert broker_id in Enum.map(event_data.added_brokers, fn {b, _h} -> b end)
    assert broker_id in ConnController.get_known_brokers(client_name)

    :ok = PubSub.unsubscribe({:cluster_change, client_name})
  end

  @tag cluster_change: true, capture_log: true, timeout: 90_000
  test "auto handle broker specific resources when broker leaves/enter cluster" do
    config = [
      connection: [bootstrap_servers: ["localhost:19092", "localhost:29092"], ssl: false],
      default_fetcher: :my_default_fetcher,
      fetchers: [
        [name: :my_default_fetcher, batchers_count: 1]
      ],
      topics: [
        [
          name: "test_no_batch_topic"
        ]
      ]
    ]

    Application.put_env(:klife, __MODULE__.MyTestClient, config)

    defmodule MyTestClient do
      use Klife.Client, otp_app: :klife
    end

    client_name = __MODULE__.MyTestClient

    :ok = PubSub.subscribe({:cluster_change, client_name})

    assert {:ok, _client_pid} = start_supervised(client_name)

    brokers = ConnController.get_known_brokers(client_name)
    broker_id_to_remove = Enum.random(brokers)

    assert [{producer_pid, _}] =
             ProcessRegistry.registry_lookup(
               {Klife.Producer, client_name, :klife_default_producer}
             )

    assert %Klife.Producer{
             batcher_supervisor: producer_batcher_sup_pid
           } = :sys.get_state(producer_pid)

    assert [expected_producer_batcher_to_die] =
             find_batcher_pid_for_broker_on_supervisor(
               producer_batcher_sup_pid,
               broker_id_to_remove
             )

    assert [{fetcher_pid, _}] =
             ProcessRegistry.registry_lookup(
               {Klife.Consumer.Fetcher, client_name, :my_default_fetcher}
             )

    assert %Klife.Consumer.Fetcher{
             batcher_supervisor: fetcher_batcher_sup_pid
           } = :sys.get_state(fetcher_pid)

    # One for each iso level
    assert [expected_fetcher_batcher_to_die1, expected_fetcher_batcher_to_die2] =
             find_batcher_pid_for_broker_on_supervisor(
               fetcher_batcher_sup_pid,
               broker_id_to_remove
             )

    producer_mon_ref = Process.monitor(expected_producer_batcher_to_die)
    fetcher_mon_ref1 = Process.monitor(expected_fetcher_batcher_to_die1)
    fetcher_mon_ref2 = Process.monitor(expected_fetcher_batcher_to_die2)

    {:ok, service_name} = TestUtils.stop_broker(client_name, broker_id_to_remove)

    assert_receive {:DOWN, ^producer_mon_ref, :process, ^expected_producer_batcher_to_die,
                    {:shutdown, {:cluster_change, {:removed_broker, ^broker_id_to_remove}}}},
                   1000

    assert_receive {:DOWN, ^fetcher_mon_ref1, :process, ^expected_fetcher_batcher_to_die1,
                    {:shutdown, {:cluster_change, {:removed_broker, ^broker_id_to_remove}}}},
                   1000

    assert_receive {:DOWN, ^fetcher_mon_ref2, :process, ^expected_fetcher_batcher_to_die2,
                    {:shutdown, {:cluster_change, {:removed_broker, ^broker_id_to_remove}}}},
                   1000

    # sleeps to ensure it keeps dead after a while (transient behaviour)!
    Process.sleep(2000)

    assert [] =
             find_batcher_pid_for_broker_on_supervisor(
               producer_batcher_sup_pid,
               broker_id_to_remove
             )

    assert [] =
             find_batcher_pid_for_broker_on_supervisor(
               fetcher_batcher_sup_pid,
               broker_id_to_remove
             )

    {:ok, new_broker_id} = TestUtils.start_broker(service_name, client_name)

    assert_receive(
      {{:cluster_change, ^client_name}, %{added_brokers: [{^new_broker_id, _host}]}, _},
      5000
    )

    Process.sleep(2000)

    assert [_new_pid] =
             find_batcher_pid_for_broker_on_supervisor(producer_batcher_sup_pid, new_broker_id)

    assert [_new_pid1, _new_pid2] =
             find_batcher_pid_for_broker_on_supervisor(fetcher_batcher_sup_pid, new_broker_id)
  end

  defp find_batcher_pid_for_broker_on_supervisor(sup_pid, broker) do
    sup_pid
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, :worker, [_mod]} -> pid end)
    |> Enum.filter(fn b_pid ->
      %Klife.GenBatcher{
        user_state: %{
          broker_id: broker_id
        }
      } = :sys.get_state(b_pid)

      broker_id == broker
    end)
  end
end
