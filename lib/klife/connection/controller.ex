defmodule Klife.Connection.Controller do
  use GenServer

  import Klife.ProcessRegistry

  alias KlifeProtocol.Messages

  alias Klife.Connection
  alias Klife.Connection.Broker
  alias Klife.Connection.BrokerSupervisor
  alias Klife.Connection.MessageVersions

  # Since the biggest signed int32 is 2,147,483,647
  # We need to eventually reset the correlation counter value
  # in order to avoid reaching this limit.
  @max_correlation_counter 200_000_000
  @check_correlation_counter_delay :timer.seconds(300)
  @check_cluster_delay :timer.seconds(180)

  defstruct [:bootstrap_servers, :cluster_name, :known_brokers, :socket_opts, :bootstrap_conn]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple({__MODULE__, opts[:cluster_name]}))
  end

  @impl true
  def init(opts) do
    bootstrap_servers = Keyword.fetch!(opts, :bootstrap_servers)
    socket_opts = Keyword.get(opts, :socket_opts, [])
    cluster_name = Keyword.fetch!(opts, :cluster_name)

    :persistent_term.put(
      {:in_flight_messages, cluster_name},
      String.to_atom("in_flight_messages.#{cluster_name}")
    )

    :ets.new(get_in_flight_messages_table_name(cluster_name), [
      :set,
      :public,
      :named_table,
      write_concurrency: true,
      decentralized_counters: true
    ])

    :persistent_term.put({:correlation_counter, cluster_name}, :atomics.new(1, []))

    state = %__MODULE__{
      bootstrap_servers: bootstrap_servers,
      cluster_name: cluster_name,
      socket_opts: socket_opts,
      known_brokers: [],
      bootstrap_conn: nil
    }

    send(self(), :init_bootstrap_conn)
    send(self(), :check_correlation_counter)
    {:ok, state}
  end

  @impl true
  def handle_info(:init_bootstrap_conn, %__MODULE__{} = state) do
    conn = connect_bootstrap_server(state.bootstrap_servers, state.socket_opts)
    negotiate_api_versions(conn, state.cluster_name)
    Process.send(self(), :check_cluster, [])
    {:noreply, %__MODULE__{state | bootstrap_conn: conn}}
  end

  def handle_info(:check_cluster, %__MODULE__{} = state) do
    case get_cluster_info(state.bootstrap_conn) do
      {:ok, %{brokers: new_brokers_list, controller: controller}} ->
        set_cluster_controller(controller, state.cluster_name)

        old_brokers = state.known_brokers
        to_remove = old_brokers -- new_brokers_list
        to_start = new_brokers_list -- old_brokers

        Process.send(self(), {:remove_brokers, to_remove}, [])
        Process.send(self(), {:start_brokers, to_start, nil}, [])
        Process.send_after(self(), :check_cluster, @check_cluster_delay)
        {:noreply, %__MODULE__{state | known_brokers: new_brokers_list}}

      {:error, _reason} ->
        Process.send(self(), :init_bootstrap_conn, [])
        {:noreply, state}
    end
  end

  def handle_info({:start_brokers, brokers_list, from}, %__MODULE__{} = state) do
    Enum.each(brokers_list, fn {broker_id, url} ->
      broker_opts = [
        socket_opts: state.socket_opts,
        cluster_name: state.cluster_name,
        broker_id: broker_id,
        url: url
      ]

      {:ok, _} =
        DynamicSupervisor.start_child(
          via_tuple({BrokerSupervisor, state.cluster_name}),
          {Broker, broker_opts}
        )
    end)

    :persistent_term.put(
      {:known_brokers_ids, state.cluster_name},
      Enum.map(state.known_brokers, &elem(&1, 0))
    )

    if from != nil, do: GenServer.reply(from, :ok)

    {:noreply, state}
  end

  def handle_info({:remove_brokers, brokers_list}, %__MODULE__{} = state) do
    :persistent_term.put(
      {:known_brokers_ids, state.cluster_name},
      Enum.map(state.known_brokers -- brokers_list, &elem(&1, 0))
    )

    Enum.map(brokers_list, fn {broker_id, _url} ->
      case registry_lookup({Broker, broker_id, state.cluster_name}) do
        [] ->
          :ok

        [{pid, _}] ->
          DynamicSupervisor.terminate_child(
            via_tuple({BrokerSupervisor, state.cluster_name}),
            pid
          )
      end
    end)

    {:noreply, state}
  end

  def handle_info(:check_correlation_counter, %__MODULE__{} = state) do
    if read_correlation_id(state.cluster_name) >= @max_correlation_counter do
      {:correlation_counter, state.cluster_name}
      |> :persistent_term.get()
      |> :atomics.exchange(1, 0)
    end

    Process.send_after(self(), :check_correlation_counter, @check_correlation_counter_delay)
    {:noreply, state}
  end

  @impl true
  def handle_call(:check_cluster_manual, from, %__MODULE__{} = state) do
    case get_cluster_info(state.bootstrap_conn) do
      {:ok, %{brokers: new_brokers_list, controller: controller}} ->
        set_cluster_controller(controller, state.cluster_name)

        old_brokers = state.known_brokers
        to_remove = old_brokers -- new_brokers_list
        to_start = new_brokers_list -- old_brokers

        Process.send(self(), {:remove_brokers, to_remove}, [])
        Process.send(self(), {:start_brokers, to_start, from}, [])

        {:noreply, %__MODULE__{state | known_brokers: new_brokers_list}}

      {:error, _reason} ->
        new_conn = connect_bootstrap_server(state.bootstrap_servers, state.socket_opts)

        case get_cluster_info(new_conn) do
          {:ok, %{brokers: new_brokers_list, controller: controller}} ->
            set_cluster_controller(controller, state.cluster_name)

            old_brokers = state.known_brokers
            to_remove = old_brokers -- new_brokers_list
            to_start = new_brokers_list -- old_brokers

            Process.send(self(), {:remove_brokers, to_remove}, [])
            Process.send(self(), {:start_brokers, to_start, from}, [])

            {:noreply,
             %__MODULE__{
               state
               | known_brokers: new_brokers_list,
                 bootstrap_conn: new_conn
             }}

          _ ->
            {:reply, :error, state}
        end
    end
  end

  ## PUBLIC INTERFACE

  def insert_in_flight(cluster_name, correlation_id) do
    cluster_name
    |> get_in_flight_messages_table_name()
    |> :ets.insert({correlation_id, self()})
  end

  def insert_in_flight(cluster_name, correlation_id, callback) do
    cluster_name
    |> get_in_flight_messages_table_name()
    |> :ets.insert({correlation_id, callback})
  end

  def take_from_in_flight(cluster_name, correlation_id) do
    cluster_name
    |> get_in_flight_messages_table_name()
    |> :ets.take(correlation_id)
    |> List.first()
  end

  def get_next_correlation_id(cluster_name) do
    {:correlation_counter, cluster_name}
    |> :persistent_term.get()
    |> :atomics.add_get(1, 1)
  end

  def get_random_broker_id(cluster_name) do
    {:known_brokers_ids, cluster_name}
    |> :persistent_term.get()
    |> Enum.random()
  end

  def trigger_brokers_verification(cluster_name) do
    GenServer.call(via_tuple({__MODULE__, cluster_name}), :check_cluster_manual)
  end

  def get_cluster_controller(cluster_name),
    do: :persistent_term.get({:cluster_controller, cluster_name})

  def get_known_brokers(cluster_name),
    do: :persistent_term.get({:known_brokers_ids, cluster_name})

  def get_cluster_info(%Connection{} = conn) do
    %{
      headers: %{correlation_id: 0},
      content: %{include_cluster_authorized_operations: true, topics: []}
    }
    |> Messages.Metadata.serialize_request(1)
    |> Connection.write(conn)
    |> case do
      :ok ->
        {:ok, received_data} = Connection.read(conn)

        {:ok, %{content: resp}} = Messages.Metadata.deserialize_response(received_data, 1)

        {:ok,
         %{
           brokers: Enum.map(resp.brokers, fn b -> {b.node_id, "#{b.host}:#{b.port}"} end),
           controller: resp.controller_id
         }}

      {:error, _reason} = res ->
        res
    end
  end

  ## PRIVATE FUNCTIONS

  defp get_in_flight_messages_table_name(cluster_name),
    do: :persistent_term.get({:in_flight_messages, cluster_name})

  defp connect_bootstrap_server(servers, socket_opts) do
    conn =
      Enum.reduce_while(servers, [], fn url, acc ->
        case Connection.new(url, Keyword.merge(socket_opts, active: false)) do
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

  defp read_correlation_id(cluster_name) do
    {:correlation_counter, cluster_name}
    |> :persistent_term.get()
    |> :atomics.get(1)
  end

  defp set_cluster_controller(broker_id, cluster_name),
    do: :persistent_term.put({:cluster_controller, cluster_name}, broker_id)

  defp negotiate_api_versions(%Connection{} = conn, cluster_name) do
    :ok =
      %{headers: %{correlation_id: 0}, content: %{}}
      |> Messages.ApiVersions.serialize_request(0)
      |> Connection.write(conn)

    {:ok, received_data} = Connection.read(conn)
    {:ok, %{content: resp}} = Messages.ApiVersions.deserialize_response(received_data, 0)

    resp.api_keys
    |> Enum.map(&{&1.api_key, %{min: &1.min_version, max: &1.max_version}})
    |> Map.new()
    |> MessageVersions.setup_versions(cluster_name)
  end
end
