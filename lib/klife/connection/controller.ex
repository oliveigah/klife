defmodule Klife.Connection.Controller do
  @moduledoc false

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1, registry_lookup: 1]

  alias Klife.PubSub

  alias KlifeProtocol.Messages

  alias Klife.Connection
  alias Klife.Connection.Broker
  alias Klife.Connection.BrokerSupervisor
  alias Klife.Connection.MessageVersions

  # Since the biggest signed int32 is 2,147,483,647
  # We need to eventually reset the correlation counter value
  # in order to avoid reaching this limit.

  @max_correlation_counter 1_000_000_000

  @check_cluster_delay :timer.seconds(10)

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
        "Options to configure SASL authentication, see SASL section for supported mechanisms and examples."
    ]
  ]
  @derive {Inspect, except: [:sasl_opts]}
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
    :sasl_opts
  ]

  def get_opts(), do: @connection_opts

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple({__MODULE__, opts[:client_name]}))
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

    :ets.new(get_in_flight_messages_table_name(client), [
      :set,
      :public,
      :named_table
    ])

    :persistent_term.put({:correlation_counter, client}, :atomics.new(1, signed: false))

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
      sasl_opts: sasl_opts
    }

    new_state = do_init(state)
    {:ok, new_state}
  end

  defp do_init(state) do
    {_, state} = handle_info(:init_bootstrap_conn, state)
    {_, state} = handle_info(:check_cluster, state)

    state
  end

  @impl true
  def handle_info(:init_bootstrap_conn, %__MODULE__{} = state) do
    conn =
      connect_bootstrap_server(
        state.bootstrap_servers,
        state.ssl,
        state.connect_opts,
        state.socket_opts
      )

    negotiate_api_versions(conn, state.client_name)
    new_sasl_opts = Connection.build_sasl_opts(state.sasl_opts, state.client_name)
    :ok = Connection.authenticate_sasl(conn, new_sasl_opts)

    new_state = %__MODULE__{
      state
      | bootstrap_conn: conn,
        sasl_opts: new_sasl_opts
    }

    {_, new_state} = handle_info(:check_cluster, new_state)

    {:noreply, new_state}
  end

  def handle_info(:check_cluster, %__MODULE__{} = state) do
    case get_cluster_info(state.bootstrap_conn) do
      {:ok, %{brokers: new_brokers_list, controller: controller}} ->
        set_client_controller(controller, state.client_name)

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

      {:error, _reason} ->
        Process.send_after(self(), :init_bootstrap_conn, :timer.seconds(1))
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:trigger_check_cluster, from, %__MODULE__{} = state) do
    case state do
      %__MODULE__{check_cluster_waiting_pids: []} ->
        Process.cancel_timer(state.check_cluster_timer_ref)
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
        Process.cancel_timer(state.check_cluster_timer_ref)
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

  def trigger_brokers_verification(client_name) do
    GenServer.call(via_tuple({__MODULE__, client_name}), :trigger_check_cluster)
  end

  def trigger_brokers_verification_async(client_name) do
    GenServer.cast(via_tuple({__MODULE__, client_name}), :trigger_check_cluster)
  end

  def get_client_controller(client_name),
    do: :persistent_term.get({:client_controller, client_name})

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

  ## PRIVATE FUNCTIONS

  defp handle_brokers(to_start, to_remove, %__MODULE__{} = state) do
    Enum.each(to_start, fn {broker_id, url} ->
      broker_opts = [
        connect_opts: state.connect_opts,
        client_name: state.client_name,
        socket_opts: state.socket_opts,
        sasl_opts: state.sasl_opts,
        broker_id: broker_id,
        url: url,
        ssl: state.ssl
      ]

      DynamicSupervisor.start_child(
        via_tuple({BrokerSupervisor, state.client_name}),
        {Broker, broker_opts}
      )
      |> case do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end)

    Enum.each(to_remove, fn {broker_id, _url} ->
      case registry_lookup({Broker, broker_id, state.client_name}) do
        [] ->
          :ok

        [{pid, _}] ->
          DynamicSupervisor.terminate_child(
            via_tuple({BrokerSupervisor, state.client_name}),
            pid
          )
      end
    end)

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
    do: :"in_flight_messages.#{client_name}"

  defp connect_bootstrap_server(servers, ssl, connect_opts, socket_opts) do
    conn =
      Enum.reduce_while(servers, [], fn url, acc ->
        case Connection.new(
               url,
               ssl,
               Keyword.merge(connect_opts, active: false),
               socket_opts,
               # For the first connection we do not have the API versions yet so we can not pass sasl_opts
               []
             ) do
          {:ok, conn} ->
            {:halt, conn}

          {:error, reason} ->
            {:cont, [{url, reason} | acc]}
        end
      end)

    if match?(%Connection{}, conn),
      do: conn,
      else:
        raise("""
        Could not connect with any boostrap server provided on configuration.
        Errors: #{inspect(conn)}
        """)
  end

  defp set_client_controller(broker_id, client_name),
    do: :persistent_term.put({:client_controller, client_name}, broker_id)

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
  end
end
