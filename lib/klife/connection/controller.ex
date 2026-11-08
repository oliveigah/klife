defmodule Klife.Connection.Controller do
  @moduledoc false

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1, registry_lookup: 1]

  require Logger

  alias Klife.PubSub

  alias KlifeProtocol.Messages

  alias Klife.Connection
  alias Klife.Connection.Broker
  alias Klife.Connection.MessageVersions

  # Since the biggest signed int32 is 2,147,483,647
  # We need to eventually reset the correlation counter value
  # in order to avoid reaching this limit.

  @max_correlation_counter 1_000_000_000

  @check_cluster_delay Application.compile_env(:klife, :metadata_check_interval_ms, 10_000)

  @custom_connection_opts [
    name: [
      type: :atom,
      required: true,
      doc:
        "Connection name, used as the `:connection` option of producers, txn pools, fetchers and consumer groups. Using the name of a default connection (see the `default_*connection` options) configures it."
    ],
    connection_count: [
      type: :pos_integer,
      doc: "Replaces the client's `connection_count`."
    ],
    connect_opts: [
      type: {:list, :any},
      doc: "Merged over the client's `connect_opts`."
    ],
    socket_opts: [
      type: {:list, :any},
      doc: "Merged over the client's `socket_opts`."
    ],
    sasl_opts: [
      type: {:list, :any},
      doc:
        "Replaces the client's `sasl_opts`, so this connection can authenticate as another user."
    ]
  ]

  @connection_opts [
    bootstrap_servers: [
      type: {:list, :string},
      required: true,
      doc:
        "List of servers to establish the initial connection. (eg: [\"localhost:9092\", \"localhost:9093\"])"
    ],
    ssl: [
      type: :boolean,
      required: false,
      default: false,
      doc: "Specify the underlying socket module. Use `:ssl` if true and `:gen_tcp` if false."
    ],
    connection_count: [
      type: :pos_integer,
      required: false,
      default: 1,
      doc:
        "How many TCP connections each of the client's connections keeps to each broker, unless it sets its own. With the 3 default connections, that is `3 * connection_count` TCP connections to each broker. See [Connections](guides/examples/client_configuration.md#connections)."
    ],
    connect_opts: [
      type: {:list, :any},
      required: false,
      default: [
        inet_backend: :socket,
        active: false
      ],
      doc:
        "Options used to configure the socket connection, which are forwarded to the `connect/3` function of the underlying socket module (see ssl option above.)."
    ],
    socket_opts: [
      type: {:list, :any},
      required: false,
      default: [keepalive: true],
      doc:
        "Options used to configure the open socket, which are forwarded to the `setopts/2` function of the underlying socket module `:inet` for `:gen_tcp` and `:ssl` for `:ssl` (see ssl option above.)."
    ],
    sasl_opts: [
      type: {:list, :any},
      required: false,
      default: [],
      doc:
        "Options to configure SASL authentication, see the [SASL section](guides/examples/client_configuration.md#sasl) for supported mechanisms and examples."
    ],
    default_request_timeout_ms: [
      type: :pos_integer,
      required: false,
      default: :timer.seconds(30),
      doc:
        "The default request timeout ms to be used on all requests to brokers. Some other options may override this value in specific scenarios"
    ],
    default_connection: [
      type: :atom,
      required: false,
      default: :klife_default_connection,
      doc:
        "Name of the connection used by producers and txn pools that don't set one. If no custom connection has this name, one is created with the client's options."
    ],
    default_fetch_connection: [
      type: :atom,
      required: false,
      default: :klife_fetch_connection,
      doc:
        "Name of the connection used by fetchers that don't set one. If no custom connection has this name, one is created with the client's options."
    ],
    default_critical_connection: [
      type: :atom,
      required: false,
      default: :klife_critical_connection,
      doc:
        "Name of the connection used by consumer groups that don't set one, and by metadata refreshes. If no custom connection has this name, one is created with the client's options."
    ],
    custom_connections: [
      type: {:list, {:keyword_list, @custom_connection_opts}},
      type_doc: "list of keyword lists",
      required: false,
      default: [],
      doc: """
      Connections to declare, each with its own TCP connections to every broker. \
      Options they don't set come from the client's options above, and `ssl`, `bootstrap_servers` \
      and `default_request_timeout_ms` are always the client's. See [Connections](guides/examples/client_configuration.md#connections).

      #{NimbleOptions.docs(@custom_connection_opts, nest_level: 1)}
      """
    ]
  ]
  # `connections` maps each connection name to the options of its TCP connections:
  # connection_count, connect_opts, socket_opts and sasl_opts. The other fields
  # configure the bootstrap connection, which takes the client's options
  @derive {Inspect, except: [:sasl_opts, :connections]}
  defstruct [
    :bootstrap_servers,
    :client_name,
    :known_brokers,
    :connect_opts,
    :bootstrap_conn,
    :check_cluster_timer_ref,
    :check_cluster_waiting_pids,
    :ssl,
    :socket_opts,
    :sasl_opts,
    :broker_supervisor,
    :connections,
    :default_request_timeout_ms
  ]

  def get_opts(), do: @connection_opts

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple({__MODULE__, opts[:client_name]}))
  end

  def child_spec(arg) do
    %{
      id: {__MODULE__, arg[:client_name]},
      start: {__MODULE__, :start_link, [arg]}
    }
  end

  @impl true
  def init(args) do
    %{
      connect_opts: connect_defaults,
      socket_opts: socket_defaults
    } =
      @connection_opts
      |> Keyword.take([:connect_opts, :socket_opts])
      |> Enum.map(fn {k, opt} -> {k, opt[:default] || []} end)
      |> Map.new()

    bootstrap_servers = args.bootstrap_servers
    connect_opts = Keyword.merge(connect_defaults, args.connect_opts)
    socket_opts = Keyword.merge(socket_defaults, args.socket_opts)
    sasl_opts = args.sasl_opts
    ssl = args.ssl
    client = args.client_name

    default_names = %{
      default_connection: args.default_connection,
      default_fetch_connection: args.default_fetch_connection,
      default_critical_connection: args.default_critical_connection
    }

    # Raises on invalid custom connections, before anything is set up
    connections =
      build_connections(
        %{
          connection_count: args.connection_count,
          connect_opts: connect_opts,
          socket_opts: socket_opts,
          sasl_opts: sasl_opts
        },
        args.custom_connections,
        Map.values(default_names),
        client
      )

    {:ok, broker_sup_pid} = DynamicSupervisor.start_link([])

    # Built once: every request and reply looks it up
    in_flight_table = :"in_flight_messages.#{client}"
    :persistent_term.put({__MODULE__, client, :in_flight_table}, in_flight_table)

    :ets.new(in_flight_table, [
      :set,
      :public,
      :named_table,
      write_concurrency: true
    ])

    :persistent_term.put({:correlation_counter, client}, :atomics.new(1, signed: false))

    default_request_timeout_ms = args.default_request_timeout_ms
    put_default_request_timeout_ms(client, default_request_timeout_ms)

    :persistent_term.put({__MODULE__, client, :connection_names}, Map.keys(connections))

    for {option, name} <- default_names do
      :persistent_term.put({__MODULE__, client, option}, name)
    end

    for {name, %{connection_count: count}} <- connections do
      :persistent_term.put({__MODULE__, client, :connection_count, name}, count)
    end

    state = %__MODULE__{
      bootstrap_servers: bootstrap_servers,
      client_name: client,
      connect_opts: connect_opts,
      socket_opts: socket_opts,
      ssl: ssl,
      known_brokers: [],
      bootstrap_conn: nil,
      check_cluster_timer_ref: nil,
      check_cluster_waiting_pids: [],
      sasl_opts: sasl_opts,
      broker_supervisor: broker_sup_pid,
      default_request_timeout_ms: default_request_timeout_ms,
      connections: connections
    }

    {:ok, do_init(state)}
  end

  # The custom connections, plus a connection with the client's options for each default
  # name no custom connection has. A custom connection takes the client's options too,
  # except for the ones it sets
  defp build_connections(client_conn_opts, custom_connections, default_names, client) do
    defaults = Map.new(default_names, &{&1, client_conn_opts})

    Enum.reduce(custom_connections, defaults, fn custom, acc ->
      name = custom.name

      if Enum.count(custom_connections, &(&1.name == name)) > 1 do
        raise ArgumentError,
              "custom connection #{inspect(name)} is declared more than once (client=#{inspect(client)})"
      end

      Map.put(acc, name, %{
        connection_count: custom[:connection_count] || client_conn_opts.connection_count,
        connect_opts: Keyword.merge(client_conn_opts.connect_opts, custom[:connect_opts] || []),
        socket_opts: Keyword.merge(client_conn_opts.socket_opts, custom[:socket_opts] || []),
        sasl_opts: custom[:sasl_opts] || client_conn_opts.sasl_opts
      })
    end)
  end

  # The client can't start without a bootstrap connection, so this one raises
  defp do_init(%__MODULE__{} = state) do
    conn =
      case connect_bootstrap_server(
             state.bootstrap_servers,
             state.ssl,
             state.connect_opts,
             state.socket_opts,
             # For the first connection we do not have the API versions yet so we can not pass sasl_opts
             []
           ) do
        {:ok, conn} ->
          conn

        {:error, errors} ->
          raise """
          Could not connect with any boostrap server provided on configuration.
          Errors: #{inspect(errors)}
          """
      end

    :ok = negotiate_api_versions(conn, state.client_name)
    new_sasl_opts = Connection.build_sasl_opts(state.sasl_opts, state.client_name)
    {:ok, conn} = Connection.authenticate_sasl(conn, new_sasl_opts)
    :ok = schedule_bootstrap_reauth(conn, state.client_name)

    connections =
      Map.new(state.connections, fn {name, conn_opts} ->
        sasl_opts = Connection.build_sasl_opts(conn_opts.sasl_opts, state.client_name)
        {name, %{conn_opts | sasl_opts: sasl_opts}}
      end)

    new_state = %__MODULE__{
      state
      | bootstrap_conn: conn,
        sasl_opts: new_sasl_opts,
        connections: connections
    }

    {_, new_state} = handle_info(:check_cluster, new_state)

    new_state
  end

  @impl true

  # Replaces a bootstrap connection that failed. Callers wait on this process (see
  # trigger_brokers_verification/1) and each server that is down can take seconds to
  # fail (a stopped broker's name can take ~4s to resolve), so the server that failed
  # is tried last and a single replacement is pending at a time (bootstrap_conn is nil
  # until it succeeds)
  def handle_info(:init_bootstrap_conn, %__MODULE__{bootstrap_conn: nil} = state) do
    case connect_bootstrap_server(
           state.bootstrap_servers,
           state.ssl,
           state.connect_opts,
           state.socket_opts,
           state.sasl_opts
         ) do
      {:ok, conn} ->
        :ok = schedule_bootstrap_reauth(conn, state.client_name)
        handle_info(:check_cluster, %__MODULE__{state | bootstrap_conn: conn})

      {:error, errors} ->
        Logger.warning(
          "Could not connect to any bootstrap server, will retry (errors=#{inspect(errors)}) (client=#{inspect(state.client_name)})",
          client: state.client_name
        )

        Process.send_after(self(), :init_bootstrap_conn, :timer.seconds(1))
        {:noreply, state}
    end
  end

  # Only scheduled while bootstrap_conn is nil, kept so a stray one can't replace a
  # working connection
  def handle_info(:init_bootstrap_conn, %__MODULE__{} = state), do: {:noreply, state}

  # The session is about to end. Requests on the bootstrap connection are sent and read
  # inside this process, so nothing is in flight on it and it is replaced at once.
  # Its server may be down by now, so any bootstrap server will do
  def handle_info(
        {:reauth_bootstrap_conn, socket},
        %__MODULE__{bootstrap_conn: %Connection{socket: socket} = old} = state
      ) do
    Connection.close(old)
    handle_info(:init_bootstrap_conn, %__MODULE__{state | bootstrap_conn: nil})
  end

  # Set for a bootstrap connection that was initialized again meanwhile
  def handle_info({:reauth_bootstrap_conn, _socket}, %__MODULE__{} = state),
    do: {:noreply, state}

  # A replacement of the bootstrap connection is pending, and it checks the cluster
  # once connected
  def handle_info(:check_cluster, %__MODULE__{bootstrap_conn: nil} = state),
    do: {:noreply, state}

  def handle_info(:check_cluster, %__MODULE__{} = state) do
    # Prevent subtle edge case when
    # messages may accumullate idefinitely due to
    # multiple cluster changes
    if state.check_cluster_timer_ref do
      Process.cancel_timer(state.check_cluster_timer_ref)
    end

    case get_cluster_info(state.bootstrap_conn) do
      {:ok, %{brokers: new_brokers_list, controller: controller}} ->
        set_cluster_controller(controller, state.client_name)

        old_brokers = state.known_brokers
        to_remove = old_brokers -- new_brokers_list
        to_start = new_brokers_list -- old_brokers

        next_ref = Process.send_after(self(), :check_cluster, @check_cluster_delay)

        new_state = %__MODULE__{
          state
          | known_brokers: new_brokers_list,
            check_cluster_timer_ref: next_ref
        }

        new_state = handle_brokers(to_start, to_remove, new_state)

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "Failed to get cluster info, will re-initialize bootstrap connection (reason=#{inspect(reason)}) (client=#{inspect(state.client_name)})",
          client: state.client_name
        )

        %Connection{host: host, port: port} = failed = state.bootstrap_conn
        Connection.close(failed)

        {failed_servers, servers} =
          Enum.split_with(state.bootstrap_servers, &(&1 == "#{host}:#{port}"))

        Process.send_after(self(), :init_bootstrap_conn, :timer.seconds(1))

        {:noreply,
         %__MODULE__{state | bootstrap_conn: nil, bootstrap_servers: servers ++ failed_servers}}
    end
  end

  @impl true
  def handle_call(:trigger_check_cluster, from, %__MODULE__{} = state) do
    case state do
      %__MODULE__{check_cluster_waiting_pids: []} ->
        new_ref = Process.send_after(self(), :check_cluster, 0)

        {:noreply,
         %__MODULE__{
           state
           | check_cluster_waiting_pids: [from],
             check_cluster_timer_ref: new_ref
         }}

      %__MODULE__{} ->
        {:noreply,
         %__MODULE__{
           state
           | check_cluster_waiting_pids: [from | state.check_cluster_waiting_pids]
         }}
    end
  end

  @impl true
  def handle_cast(:trigger_check_cluster, %__MODULE__{} = state) do
    case state do
      %__MODULE__{check_cluster_waiting_pids: []} ->
        new_ref = Process.send_after(self(), :check_cluster, 0)

        {:noreply,
         %__MODULE__{
           state
           | check_cluster_timer_ref: new_ref
         }}

      _ ->
        {:noreply, state}
    end
  end

  ## PUBLIC INTERFACE

  def insert_in_flight(client_name, correlation_id) do
    client_name
    |> get_in_flight_messages_table_name()
    |> :ets.insert({correlation_id, self()})
  end

  def insert_in_flight(client_name, correlation_id, callback) do
    client_name
    |> get_in_flight_messages_table_name()
    |> :ets.insert({correlation_id, callback})
  end

  def take_from_in_flight(client_name, correlation_id) do
    client_name
    |> get_in_flight_messages_table_name()
    |> :ets.take(correlation_id)
    |> List.first()
  end

  def get_connection_count(client_name, connection_name) do
    :persistent_term.get({__MODULE__, client_name, :connection_count, connection_name})
  end

  def get_connection_names(client_name) do
    :persistent_term.get({__MODULE__, client_name, :connection_names})
  end

  def get_default_connection(client_name),
    do: :persistent_term.get({__MODULE__, client_name, :default_connection})

  def get_default_fetch_connection(client_name),
    do: :persistent_term.get({__MODULE__, client_name, :default_fetch_connection})

  def get_default_critical_connection(client_name),
    do: :persistent_term.get({__MODULE__, client_name, :default_critical_connection})

  # For components to refuse, when they start, a connection the client doesn't have
  def validate_connection!(client_name, connection_name) do
    names = get_connection_names(client_name)

    if connection_name in names do
      :ok
    else
      raise ArgumentError,
            "unknown connection #{inspect(connection_name)} for client #{inspect(client_name)}, its connections are #{inspect(Enum.sort(names))}"
    end
  end

  def put_default_request_timeout_ms(client_name, timeout_ms) do
    :persistent_term.put({__MODULE__, client_name, :default_request_timeout_ms}, timeout_ms)
  end

  def get_default_request_timeout_ms(client_name) do
    :persistent_term.get({__MODULE__, client_name, :default_request_timeout_ms})
  end

  def get_next_correlation_id(client_name) do
    # atomics wraps arround when overflowed
    # since atomics can only be int64 we use
    # rem/2 in order to guarantee the max value
    # will never be reached
    val =
      {:correlation_counter, client_name}
      |> :persistent_term.get()
      |> :atomics.add_get(1, 1)

    rem(val, @max_correlation_counter)
  end

  def get_random_broker_id(client_name) do
    {:known_brokers_ids, client_name}
    |> :persistent_term.get()
    |> Enum.random()
  end

  # Returns once the cluster was checked, or {:error, :timeout} if no check succeeded
  # meanwhile (no bootstrap server answers, for example)
  def trigger_brokers_verification(client_name) do
    GenServer.call(
      via_tuple({__MODULE__, client_name}),
      :trigger_check_cluster,
      get_default_request_timeout_ms(client_name) + :timer.seconds(5)
    )
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  def trigger_brokers_verification_async(client_name) do
    GenServer.cast(via_tuple({__MODULE__, client_name}), :trigger_check_cluster)
  end

  def get_cluster_controller(client_name),
    do: :persistent_term.get({:cluster_controller, client_name})

  def get_known_brokers(client_name),
    do: :persistent_term.get({:known_brokers_ids, client_name})

  def get_cluster_info(%Connection{} = conn) do
    req = %{
      headers: %{correlation_id: 0},
      content: %{include_client_authorized_operations: true, topics: []}
    }

    serialized_req = Messages.Metadata.serialize_request(req, 1)

    with :ok <- Connection.write(serialized_req, conn),
         {:ok, received_data} <- Connection.read(conn) do
      {:ok, %{content: resp}} = Messages.Metadata.deserialize_response(received_data, 1)

      {:ok,
       %{
         brokers: Enum.map(resp.brokers, fn b -> {b.node_id, "#{b.host}:#{b.port}"} end),
         controller: resp.controller_id
       }}
    else
      {:error, _reason} = res ->
        res
    end
  end

  def disable_feature(:connection, client_name) do
    raise "Could not agree on a required message for the connection system. Check logs for details (client=#{inspect(client_name)})"
  end

  def disable_feature(:producer = feature, client_name) do
    Logger.warning(
      "Producer feature disabled due to API version negotiation failure or client configuration (client=#{inspect(client_name)})",
      client: client_name,
      feature: feature
    )

    :persistent_term.put({__MODULE__, client_name, feature, :disabled?}, true)
  end

  def disable_feature(:txn_producer = feature, client_name) do
    Logger.warning(
      "Transactions feature disabled due to API version negotiation failure or client configuration (client=#{inspect(client_name)})",
      client: client_name,
      feature: feature
    )

    :persistent_term.put({__MODULE__, client_name, feature, :disabled?}, true)
  end

  def disable_feature(:producer_idempotence = feature, client_name) do
    Logger.warning(
      "Producer idempotence feature disabled due to API version negotiation failure (client=#{inspect(client_name)})",
      client: client_name,
      feature: feature
    )

    :persistent_term.put({__MODULE__, client_name, feature, :disabled?}, true)
  end

  def disable_feature(:sasl = feature, client_name) do
    Logger.warning(
      "SASL feature disabled due to API version negotiation failure (client=#{inspect(client_name)})",
      client: client_name,
      feature: feature
    )

    :persistent_term.put({__MODULE__, client_name, feature, :disabled?}, true)
  end

  def disable_feature(:consumer_group = feature, client_name) do
    Logger.warning(
      "Consumer Group feature disabled due to API version negotiation failure (client=#{inspect(client_name)})",
      client: client_name,
      feature: feature
    )

    :persistent_term.put({__MODULE__, client_name, feature, :disabled?}, true)
  end

  def disabled_feature?(client_name, feature),
    do: :persistent_term.get({__MODULE__, client_name, feature, :disabled?}, false)

  ## PRIVATE FUNCTIONS

  # Every connection keeps its connection_count TCP connections to each broker
  defp handle_brokers(to_start, to_remove, %__MODULE__{} = state) do
    for {broker_id, url} <- to_start,
        {conn_name, conn_opts} <- state.connections,
        idx <- 0..(conn_opts.connection_count - 1) do
      {broker_id, url, conn_name, conn_opts, idx}
    end
    |> Task.async_stream(
      fn {broker_id, url, conn_name, conn_opts, idx} ->
        broker_opts = [
          connect_opts: conn_opts.connect_opts,
          client_name: state.client_name,
          connection_name: conn_name,
          socket_opts: conn_opts.socket_opts,
          sasl_opts: conn_opts.sasl_opts,
          broker_id: broker_id,
          url: url,
          ssl: state.ssl,
          broker_index: idx
        ]

        spec = %{
          id: {Broker, broker_id, state.client_name, conn_name, idx},
          start: {Broker, :start_link, [broker_opts]},
          type: :worker
        }

        case DynamicSupervisor.start_child(state.broker_supervisor, spec) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      end,
      timeout: 15_000
    )
    |> Enum.each(fn resp -> {:ok, :ok} = resp end)

    for {broker_id, _url} <- to_remove,
        {conn_name, conn_opts} <- state.connections,
        idx <- 0..(conn_opts.connection_count - 1) do
      case registry_lookup({Broker, broker_id, state.client_name, conn_name, idx}) do
        [] ->
          :ok

        [{pid, _}] ->
          DynamicSupervisor.terminate_child(
            state.broker_supervisor,
            pid
          )
      end
    end

    new_brokers =
      ((state.known_brokers ++ to_start) -- to_remove)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    :persistent_term.put({:known_brokers_ids, state.client_name}, new_brokers)

    if to_start != [] or to_remove != [] do
      PubSub.publish({:cluster_change, state.client_name}, %{
        added_brokers: to_start,
        removed_brokers: to_remove
      })
    end

    state.check_cluster_waiting_pids
    |> Enum.reverse()
    |> Enum.each(&GenServer.reply(&1, :ok))

    %__MODULE__{state | check_cluster_waiting_pids: []}
  end

  defp get_in_flight_messages_table_name(client_name),
    do: :persistent_term.get({__MODULE__, client_name, :in_flight_table})

  # The first server that connects, in order, or every server's error
  defp connect_bootstrap_server(servers, ssl, connect_opts, socket_opts, sasl_opts) do
    Enum.reduce_while(servers, {:error, []}, fn url, {:error, errors} ->
      case Connection.new(
             url,
             ssl,
             Keyword.merge(connect_opts, active: false),
             socket_opts,
             sasl_opts
           ) do
        {:ok, conn} ->
          {:halt, {:ok, conn}}

        {:error, reason} ->
          {:cont, {:error, errors ++ [{url, reason}]}}
      end
    end)
  end

  # Raises on sessions shorter than the drain, the same rule broker connections follow
  defp schedule_bootstrap_reauth(%Connection{} = conn, client_name) do
    case Connection.reauth_in_ms(conn, Connection.drain_ms(client_name)) do
      nil ->
        :ok

      reauth_in_ms ->
        Process.send_after(self(), {:reauth_bootstrap_conn, conn.socket}, reauth_in_ms)
        :ok
    end
  end

  defp set_cluster_controller(broker_id, client_name),
    do: :persistent_term.put({:cluster_controller, client_name}, broker_id)

  defp negotiate_api_versions(%Connection{} = conn, client_name) do
    :ok =
      %{headers: %{correlation_id: 0}, content: %{}}
      |> Messages.ApiVersions.serialize_request(0)
      |> Connection.write(conn)

    {:ok, received_data} = Connection.read(conn)
    {:ok, %{content: resp}} = Messages.ApiVersions.deserialize_response(received_data, 0)

    resp.api_keys
    |> Map.new(&{&1.api_key, %{min: &1.min_version, max: &1.max_version}})
    |> MessageVersions.setup_versions(client_name)

    :ok
  end
end
