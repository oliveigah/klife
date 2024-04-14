defmodule Klife.Connection.Broker do
  @moduledoc """
  Represents a connection to a specific broker

  Responsible for housekeeping the connection and
  forward responses to waiting pids

  """
  use GenServer

  import Klife.ProcessRegistry

  require Logger

  alias Klife.Connection
  alias Klife.Connection.Controller
  alias Klife.Connection.MessageVersions

  @reconnect_delays_seconds [1, 1, 1, 1, 5, 5, 10]

  defstruct [:broker_id, :cluster_name, :conn, :socket_opts, :url, :reconnect_attempts]

  def start_link(args) do
    broker_id = Keyword.fetch!(args, :broker_id)
    cluster_name = Keyword.fetch!(args, :cluster_name)
    GenServer.start_link(__MODULE__, args, name: via_tuple({__MODULE__, broker_id, cluster_name}))
  end

  def init(args) do
    socket_opts = Keyword.fetch!(args, :socket_opts)
    cluster_name = Keyword.fetch!(args, :cluster_name)
    broker_id = Keyword.fetch!(args, :broker_id)
    url = Keyword.fetch!(args, :url)

    state = %__MODULE__{
      broker_id: broker_id,
      cluster_name: cluster_name,
      socket_opts: socket_opts,
      url: url,
      reconnect_attempts: 0
    }

    # This needs to be done instead of send(self(), :connect)
    # in order to prevent a race condition where the
    # manual broker verification returns :ok to the caller
    # before a connection is properly initialized.
    #
    # This bug can be reproduced by artificially increasing
    # the time it takes to complete the connect action
    #
    # Since we do not expect this process to restart often
    # it is safe to go with a longer initialization time
    state = do_connect(state)

    {:ok, state}
  end

  def handle_info(:connect, %__MODULE__{} = state), do: {:noreply, do_connect(state)}

  def handle_info({:tcp, _port, msg}, %__MODULE__{} = state) do
    :ok = reply_message(msg, state.cluster_name, state.conn)
    {:noreply, state}
  end

  def handle_info({:ssl, {:sslsocket, _socket_details, _pids}, msg}, %__MODULE__{} = state) do
    :ok = reply_message(msg, state.cluster_name, state.conn)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _port}, %__MODULE__{} = state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info({:ssl_closed, {:sslsocket, _socket_details, _pids}}, %__MODULE__{} = state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def terminate(reason, %__MODULE__{} = state) do
    :persistent_term.erase({__MODULE__, state.cluster_name, state.broker_id})
    reason
  end

  def send_message(
        message_mod,
        cluster_name,
        broker_id,
        content \\ %{},
        headers \\ %{},
        opts \\ []
      ) do
    correlation_id = Controller.get_next_correlation_id(cluster_name)

    input = %{
      headers: Map.put(headers, :correlation_id, correlation_id),
      content: content
    }

    version = MessageVersions.get(cluster_name, message_mod)
    data = apply(message_mod, :serialize_request, [input, version])

    if Keyword.get(opts, :async, false),
      do: send_raw_async(data, correlation_id, broker_id, cluster_name, opts[:callback]),
      else: send_raw_sync(data, message_mod, correlation_id, broker_id, cluster_name)
  end

  def send_raw_sync(raw_data, message_mod, correlation_id, broker_id, cluster_name) do
    broker_id = get_broker_id(broker_id, cluster_name)
    conn = get_connection(cluster_name, broker_id)
    true = Controller.insert_in_flight(cluster_name, correlation_id)

    case Connection.write(raw_data, conn) do
      :ok ->
        receive do
          {:broker_response, response} ->
            apply(message_mod, :deserialize_response, [
              response,
              MessageVersions.get(cluster_name, message_mod)
            ])
        after
          conn.read_timeout + 2000 ->
            Controller.take_from_in_flight(cluster_name, correlation_id)

            Logger.error("""
            Timeout while waiting reponse from broker #{broker_id} on host #{conn.host}.
            """)

            {:error, :timeout}
        end

      {:error, reason} = res ->
        Logger.error("""
        Error while sending message to broker #{broker_id} on host #{conn.host}. Reason: #{inspect(res)}
        """)

        {:error, reason}
    end
  end

  def send_raw_async(raw_data, correlation_id, broker_id, cluster_name, callback) do
    broker_id = get_broker_id(broker_id, cluster_name)
    conn = get_connection(cluster_name, broker_id)

    in_flight_data =
      cond do
        is_function(callback) -> callback
        match?({_m, _f, _a}, callback) -> callback
        true -> :noop
      end

    true = Controller.insert_in_flight(cluster_name, correlation_id, in_flight_data)

    case Connection.write(raw_data, conn) do
      :ok ->
        :ok

      {:error, reason} = res ->
        Logger.error("""
        Error while sending async message to broker #{broker_id} on host #{conn.host}. Reason: #{inspect(res)}
        """)

        {:error, reason}
    end
  end

  defp reply_message(<<correlation_id::32-signed, _rest::binary>> = reply, cluster_name, conn) do
    case Controller.take_from_in_flight(cluster_name, correlation_id) do
      # sync send
      {^correlation_id, waiting_pid} when is_pid(waiting_pid) ->
        Process.send(waiting_pid, {:broker_response, reply}, [])

      # async send function callback
      {^correlation_id, callback} when is_function(callback) ->
        Task.Supervisor.start_child(
          via_tuple({Klife.Connection.CallbackSupervisor, cluster_name}),
          fn -> callback.(reply) end
        )

      # async send mfa callback
      {^correlation_id, {mod, fun, args}} ->
        Task.Supervisor.start_child(
          via_tuple({Klife.Connection.CallbackSupervisor, cluster_name}),
          mod,
          fun,
          [reply, args]
        )

      # async send with no callback
      {^correlation_id, :noop} ->
        :noop

      nil ->
        # TODO: HOW TO HANDLE THIS?
        #
        # A sync message was sent but the caller gave up waiting the response
        #
        # The caller will assume that the message was not delivered and may send it again.
        #
        # Dependeing on the message being sent and the idempotency configuration
        # this may not be a problem.
        #
        # Must revisit this later.
        #
        # For the producer case the mechanism being used to avoid this is to only
        # retry a delivery if there is a safe time where the producing process
        # wont give up in the middle of a request. The rule is:
        # now + req_timeout - base_time < delivery_timeout - :timer.seconds(5)
        #
        Logger.warning("""
        Unkown correlation id received from cluster #{inspect(cluster_name)}.

        correlation_id: #{inspect(correlation_id)}

        conn: #{inspect(conn)}
        """)

        nil
    end

    Connection.set_opts(conn, active: :once)
  end

  defp reply_message(_, cluster_name, conn) do
    Logger.warning("""
    Unkown message received from cluster #{inspect(cluster_name)}.

    conn: #{inspect(conn)}
    """)

    :ok
  end

  defp get_reconnect_delay(%__MODULE__{reconnect_attempts: attempts}) do
    max_idx = length(@reconnect_delays_seconds) - 1
    base_delay = Enum.at(@reconnect_delays_seconds, min(attempts, max_idx))
    jitter_delay = base_delay * (Enum.random(50..150) / 100)
    :timer.seconds(round(jitter_delay))
  end

  defp get_broker_id(:any, cluster_name), do: Controller.get_random_broker_id(cluster_name)

  defp get_broker_id(:controller, cluster_name),
    do: Controller.get_cluster_controller(cluster_name)

  defp get_broker_id(broker_id, _cluster_name), do: broker_id

  defp get_connection(cluster_name, broker_id) do
    case :persistent_term.get({__MODULE__, cluster_name, broker_id}, :not_found) do
      :not_found ->
        :ok = Controller.trigger_brokers_verification(cluster_name)
        :persistent_term.get({__MODULE__, cluster_name, broker_id})

      %Connection{} = conn ->
        conn
    end
  end

  defp do_connect(%__MODULE__{} = state) do
    case Connection.new(state.url, Keyword.merge(state.socket_opts, active: :once)) do
      {:ok, conn} ->
        :persistent_term.put({__MODULE__, state.cluster_name, state.broker_id}, conn)
        %__MODULE__{state | conn: conn, reconnect_attempts: 0}

      {:error, _reason} = res ->
        Logger.error("""
        Error while connecting to broker #{state.broker_id} on host #{state.url}. Reason: #{inspect(res)}
        """)

        Process.send_after(self(), :connect, get_reconnect_delay(state))

        %__MODULE__{state | reconnect_attempts: state.reconnect_attempts + 1}
    end
  end
end
