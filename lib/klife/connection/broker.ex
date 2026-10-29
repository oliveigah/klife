defmodule Klife.Connection.Broker do
  @moduledoc false

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Connection
  alias Klife.Connection.Controller
  alias Klife.Connection.MessageVersions

  @reconnect_delays_seconds [1, 1, 1, 1, 5, 5, 10]

  # Replies a socket delivers before going passive. Re-arming it once per reply
  # (active: :once) costs a round trip with the socket for each of them
  @active_n 100

  # At most two connections at a time: `conn` is the active one, where callers send
  # requests, and `draining_conn` the one it replaced on re-authentication, still
  # receiving replies to requests sent before the swap
  @derive {Inspect, except: [:sasl_opts]}
  defstruct [
    :broker_id,
    :client_name,
    :conn,
    :draining_conn,
    :ssl,
    :connect_opts,
    :socket_opts,
    :sasl_opts,
    :url,
    :reconnect_attempts,
    :broker_index
  ]

  def start_link(args) do
    broker_id = Keyword.fetch!(args, :broker_id)
    client_name = Keyword.fetch!(args, :client_name)
    count = Keyword.fetch!(args, :broker_index)

    GenServer.start_link(__MODULE__, args,
      name: via_tuple({__MODULE__, broker_id, client_name, count})
    )
  end

  def init(args) do
    connect_opts = Keyword.fetch!(args, :connect_opts)
    client_name = Keyword.fetch!(args, :client_name)
    broker_id = Keyword.fetch!(args, :broker_id)
    url = Keyword.fetch!(args, :url)
    ssl = Keyword.fetch!(args, :ssl)
    socket_opts = Keyword.fetch!(args, :socket_opts)
    sasl_opts = Keyword.fetch!(args, :sasl_opts)
    bidx = Keyword.fetch!(args, :broker_index)

    state = %__MODULE__{
      broker_id: broker_id,
      client_name: client_name,
      connect_opts: connect_opts,
      socket_opts: socket_opts,
      url: url,
      reconnect_attempts: 0,
      ssl: ssl,
      sasl_opts: sasl_opts,
      broker_index: bidx
    }

    # This is done here instead of `send(self(), :connect)` because
    # it only makes sense for the process to be added to the supervision tree
    # if the connection is successful.
    # This also simplifies the usage of the global :persistent_term entry because
    # it will only exist if the process is already valid.
    state = do_connect(state)

    {:ok, state}
  end

  def handle_info(:connect, %__MODULE__{} = state), do: {:noreply, do_connect(state)}

  def handle_info({:tcp, _socket, msg}, %__MODULE__{} = state) do
    reply_message(msg, state)
    {:noreply, state}
  end

  def handle_info({:ssl, _socket, msg}, %__MODULE__{} = state) do
    reply_message(msg, state)
    {:noreply, state}
  end

  # The socket delivered its @active_n replies and waits to be re-armed
  def handle_info({:tcp_passive, socket}, %__MODULE__{} = state) do
    :ok = rearm(socket, state)
    {:noreply, state}
  end

  def handle_info({:ssl_passive, socket}, %__MODULE__{} = state) do
    :ok = rearm(socket, state)
    {:noreply, state}
  end

  # Unexpected disconnection of the active connection. It is dropped before reconnecting
  # so its pending re-authentication can't fire if the reconnection fails
  def handle_info({:tcp_closed, socket}, %__MODULE__{conn: %Connection{socket: socket}} = state),
    do: {:noreply, do_connect(%__MODULE__{state | conn: nil})}

  def handle_info({:ssl_closed, socket}, %__MODULE__{conn: %Connection{socket: socket}} = state),
    do: {:noreply, do_connect(%__MODULE__{state | conn: nil})}

  # The draining connection (or an older one): nothing depends on it anymore
  def handle_info({:tcp_closed, _socket}, %__MODULE__{} = state), do: {:noreply, state}
  def handle_info({:ssl_closed, _socket}, %__MODULE__{} = state), do: {:noreply, state}

  # The session is about to end: callers move to a newly authenticated connection
  # while the old one drains
  def handle_info({:reauth, socket}, %__MODULE__{conn: %Connection{socket: socket} = old} = state) do
    {:ok, conn} = open_conn(state)

    # Only when sessions are barely longer than the drain: the previous draining
    # connection has drained for 85% of a session by now, so it makes room
    if state.draining_conn, do: Connection.close(state.draining_conn)

    Process.send_after(self(), {:close_draining, socket}, Connection.drain_ms(state.client_name))

    {:noreply, activate_conn(%__MODULE__{state | draining_conn: old}, conn)}
  end

  # Set for a connection that was replaced by a reconnection meanwhile
  def handle_info({:reauth, _socket}, %__MODULE__{} = state), do: {:noreply, state}

  def handle_info(
        {:close_draining, socket},
        %__MODULE__{draining_conn: %Connection{socket: socket} = conn} = state
      ) do
    Connection.close(conn)
    {:noreply, %__MODULE__{state | draining_conn: nil}}
  end

  # Already closed to make room for a newer draining connection
  def handle_info({:close_draining, _socket}, %__MODULE__{} = state), do: {:noreply, state}

  def terminate(reason, %__MODULE__{} = state) do
    :persistent_term.erase({__MODULE__, state.client_name, state.broker_id, state.broker_index})
    reason
  end

  def send_message(
        message_mod,
        client_name,
        broker_id,
        content \\ %{},
        headers \\ %{},
        opts \\ []
      ) do
    correlation_id = Controller.get_next_correlation_id(client_name)

    input = %{
      headers: Map.put(headers, :correlation_id, correlation_id),
      content: content
    }

    version = MessageVersions.get(client_name, message_mod)
    data = message_mod.serialize_request(input, version)

    if Keyword.get(opts, :async, false) do
      send_raw_async(data, message_mod, version, correlation_id, broker_id, client_name, opts)
    else
      send_raw_sync(data, message_mod, version, correlation_id, broker_id, client_name, opts)
    end
  end

  def send_raw_sync(
        raw_data,
        message_mod,
        msg_version,
        correlation_id,
        broker_id,
        client_name,
        opts
      ) do
    broker_id = get_broker_id(broker_id, client_name)
    conn = get_connection(client_name, broker_id)
    true = Controller.insert_in_flight(client_name, correlation_id)

    timeout =
      Keyword.get(opts, :timeout_ms, Controller.get_default_request_timeout_ms(client_name))

    case Connection.write(raw_data, conn) do
      :ok ->
        # The receive must be selective on the correlation id, otherwise a
        # response that arrives after a previous call of this process timed
        # out could be consumed here as if it belonged to this request.
        receive do
          {:broker_response, ^correlation_id, response} ->
            message_mod.deserialize_response(response, msg_version)
        after
          timeout ->
            case Controller.take_from_in_flight(client_name, correlation_id) do
              nil ->
                # The broker process took the in flight entry first, which
                # means the response is being routed to this process right
                # now. Reap it here, otherwise it would stay on the mailbox
                # until a future call selectively receives it.
                receive do
                  {:broker_response, ^correlation_id, response} ->
                    message_mod.deserialize_response(response, msg_version)
                after
                  1000 ->
                    log_sync_timeout(message_mod, client_name, broker_id, conn)
                    {:error, :timeout}
                end

              _entry ->
                log_sync_timeout(message_mod, client_name, broker_id, conn)
                {:error, :timeout}
            end
        end

      {:error, reason} ->
        Controller.take_from_in_flight(client_name, correlation_id)

        Logger.error(
          "Error sending #{inspect(message_mod)} to broker #{broker_id}: #{inspect(reason)} (client=#{inspect(client_name)})",
          client: client_name,
          broker_id: broker_id,
          host: conn.host,
          message: inspect(message_mod),
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  def send_raw_async(
        raw_data,
        msg_mod,
        msg_version,
        correlation_id,
        broker_id,
        client_name,
        opts
      ) do
    broker_id = get_broker_id(broker_id, client_name)
    conn = get_connection(client_name, broker_id)

    callback_pid = Keyword.get(opts, :callback_pid)
    callback_ref = Keyword.get(opts, :callback_ref)

    timeout_ms =
      Keyword.get(opts, :timeout_ms, Controller.get_default_request_timeout_ms(client_name))

    timeout_ref =
      if callback_pid != nil do
        Process.send_after(
          callback_pid,
          {:async_broker_response, callback_ref, :timeout},
          timeout_ms
        )
      end

    in_flight_data =
      if callback_pid,
        do: {callback_pid, callback_ref, msg_mod, msg_version, timeout_ref},
        else: :noop

    true = Controller.insert_in_flight(client_name, correlation_id, in_flight_data)

    case Connection.write(raw_data, conn) do
      :ok ->
        :ok

      {:error, reason} ->
        Controller.take_from_in_flight(client_name, correlation_id)

        Logger.error(
          "Error sending async #{inspect(msg_mod)} to broker #{broker_id}: #{inspect(reason)} (client=#{inspect(client_name)})",
          client: client_name,
          broker_id: broker_id,
          host: conn.host,
          message: inspect(msg_mod),
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Replies arrive on the active connection or the draining one, so either may need
  # re-arming. A connection closed by now has nothing left to receive
  defp rearm(socket, %__MODULE__{} = state) do
    case state do
      %__MODULE__{conn: %Connection{socket: ^socket} = conn} ->
        Connection.socket_opts(conn, active: @active_n)

      %__MODULE__{draining_conn: %Connection{socket: ^socket} = conn} ->
        Connection.socket_opts(conn, active: @active_n)

      %__MODULE__{} ->
        :ok
    end
  end

  defp reply_message(<<correlation_id::32-signed, _rest::binary>> = reply, state) do
    client_name = state.client_name

    case Controller.take_from_in_flight(client_name, correlation_id) do
      # sync send
      {^correlation_id, waiting_pid} when is_pid(waiting_pid) ->
        send(waiting_pid, {:broker_response, correlation_id, reply})

      # async send function callback
      {^correlation_id, {callback_pid, callback_ref, msg_mod, msg_version, timeout_ref}} ->
        before_timeout? =
          if timeout_ref != nil do
            Process.cancel_timer(timeout_ref) |> is_integer()
          else
            true
          end

        if before_timeout? do
          send(callback_pid, {:async_broker_response, callback_ref, reply, msg_mod, msg_version})
        else
          Logger.warning(
            "Delivery confirmation arrived after timeout for #{inspect(msg_mod)} (client=#{inspect(client_name)})",
            client: client_name,
            broker_id: state.broker_id,
            host: state.url,
            message: inspect(msg_mod)
          )
        end

      # async send with no callback and no timeout
      {^correlation_id, :noop} ->
        :noop

      nil ->
        # TODO: HOW TO HANDLE THIS?
        #
        # A sync message was sent but the caller gave up waiting the response
        #
        # The caller will assume that the message was not delivered and may send it again.
        #
        # Depending on the message being sent and the idempotency configuration
        # this may not be a problem.
        #
        # Must revisit this later.
        #
        # For the producer case the mechanism being used to avoid this is to only
        # retry a delivery if there is enough time where the producing process
        # wont give up in the middle of a request. The rule is:
        # now + req_timeout - base_time < delivery_timeout - :timer.seconds(2)

        nil
    end
  end

  defp reply_message(_, state) do
    Logger.warning(
      "Unknown message received (missing correlation ID) (client=#{inspect(state.client_name)})",
      client: state.client_name,
      host: state.url
    )
  end

  defp log_sync_timeout(message_mod, client_name, broker_id, conn) do
    Logger.error(
      "Timeout waiting for #{inspect(message_mod)} response from broker #{broker_id} (client=#{inspect(client_name)})",
      client: client_name,
      broker_id: broker_id,
      host: conn.host,
      message: inspect(message_mod)
    )
  end

  defp get_reconnect_delay(%__MODULE__{reconnect_attempts: attempts}) do
    max_idx = length(@reconnect_delays_seconds) - 1
    base_delay_seconds = Enum.at(@reconnect_delays_seconds, min(attempts, max_idx))
    jitter_delay = base_delay_seconds * 1000 * (Enum.random(50..150) / 100)
    round(jitter_delay)
  end

  defp get_broker_id(:any, client_name), do: Controller.get_random_broker_id(client_name)

  defp get_broker_id(:controller, client_name),
    do: Controller.get_cluster_controller(client_name)

  defp get_broker_id(broker_id, _client_name), do: broker_id

  def get_connection(client_name, broker_id) do
    bidx = :erlang.phash2(self(), Controller.get_connection_count(client_name))
    get_connection(client_name, broker_id, bidx)
  end

  def get_connection(client_name, broker_id, bidx) do
    case :persistent_term.get({__MODULE__, client_name, broker_id, bidx}, :not_found) do
      :not_found ->
        :ok = Controller.trigger_brokers_verification(client_name)
        :persistent_term.get({__MODULE__, client_name, broker_id, bidx})

      %Connection{} = conn ->
        conn
    end
  end

  defp do_connect(%__MODULE__{} = state) do
    case open_conn(state) do
      {:ok, conn} ->
        activate_conn(%__MODULE__{state | reconnect_attempts: 0}, conn)

      {:error, _reason} = res ->
        Logger.error(
          "Error connecting to broker #{state.broker_id} on host #{state.url}: #{inspect(res)} (client=#{inspect(state.client_name)})",
          client: state.client_name,
          broker_id: state.broker_id,
          host: state.url,
          reason: inspect(res)
        )

        :ok = Controller.trigger_brokers_verification_async(state.client_name)

        Process.send_after(self(), :connect, get_reconnect_delay(state))

        %__MODULE__{state | reconnect_attempts: state.reconnect_attempts + 1}
    end
  end

  defp open_conn(%__MODULE__{} = state) do
    # Here we need active false because the current
    # SASL implementation rely on being able to manually
    # control IO operations on the socket during authentication
    connect_opts = Keyword.merge(state.connect_opts, active: false)

    with {:ok, conn} <-
           Connection.new(state.url, state.ssl, connect_opts, state.socket_opts, state.sasl_opts) do
      # After authentication we can go back to active.
      # The underlying socket is stateful, so that's why
      # we don't care about the return value of `socket_opts`.
      Connection.socket_opts(conn, active: @active_n)
      {:ok, conn}
    end
  end

  # Callers send their requests on `conn` from now on
  defp activate_conn(%__MODULE__{} = state, %Connection{} = conn) do
    # Raises on sessions too short to drain, before callers could use them
    reauth_in_ms = Connection.reauth_in_ms(conn, Connection.drain_ms(state.client_name))

    :persistent_term.put(
      {__MODULE__, state.client_name, state.broker_id, state.broker_index},
      conn
    )

    if reauth_in_ms, do: Process.send_after(self(), {:reauth, conn.socket}, reauth_in_ms)

    %__MODULE__{state | conn: conn}
  end
end
