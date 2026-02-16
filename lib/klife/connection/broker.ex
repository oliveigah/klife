defmodule Klife.Connection.Broker do
  @moduledoc false

  use GenServer

  import Klife.ProcessRegistry, only: [via_tuple: 1]

  require Logger

  alias Klife.Connection
  alias Klife.Connection.Controller
  alias Klife.Connection.MessageVersions

  @reconnect_delays_seconds [1, 1, 1, 1, 5, 5, 10]

  defstruct [
    :broker_id,
    :client_name,
    :conn,
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

  def handle_info({:tcp, _port, msg}, %__MODULE__{} = state) do
    :ok = reply_message(msg, state.client_name, state.conn)
    {:noreply, state}
  end

  def handle_info({:ssl, _ssl_details, msg}, %__MODULE__{} = state) do
    :ok = reply_message(msg, state.client_name, state.conn)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _port}, %__MODULE__{} = state) do
    {:noreply, do_connect(state)}
  end

  def handle_info({:ssl_closed, _ssl_details}, %__MODULE__{} = state) do
    {:noreply, do_connect(state)}
  end

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
        receive do
          {:broker_response, response} ->
            message_mod.deserialize_response(response, msg_version)
        after
          timeout ->
            Controller.take_from_in_flight(client_name, correlation_id)

            Logger.error(
              "Timeout waiting for #{inspect(message_mod)} response from broker #{broker_id} (client=#{inspect(client_name)})",
              client: client_name,
              broker_id: broker_id,
              host: conn.host,
              message: inspect(message_mod)
            )

            {:error, :timeout}
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

  defp reply_message(<<correlation_id::32-signed, _rest::binary>> = reply, client_name, conn) do
    case Controller.take_from_in_flight(client_name, correlation_id) do
      # sync send
      {^correlation_id, waiting_pid} when is_pid(waiting_pid) ->
        send(waiting_pid, {:broker_response, reply})

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
            broker_id: conn.host,
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

    Connection.socket_opts(conn, active: :once)
  end

  defp reply_message(_, client_name, conn) do
    Logger.warning(
      "Unknown message received (missing correlation ID) (client=#{inspect(client_name)})",
      client: client_name,
      host: conn.host
    )

    :ok
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

  defp do_connect(
         %__MODULE__{
           url: url,
           ssl: ssl,
           connect_opts: connect_opts,
           socket_opts: socket_opts,
           sasl_opts: sasl_opts
         } = state
       ) do
    case Connection.new(
           url,
           ssl,
           # Here we need active false because the current
           # SASL implementation rely on being able to manually
           # control IO operations on the socket during authentication
           Keyword.merge(connect_opts, active: false),
           socket_opts,
           sasl_opts
         ) do
      {:ok, conn} ->
        # After authentication we can go back to once.
        # The underlying socket is stateful, so that's why
        # we don't care about the return value of `socket_opts`.
        Connection.socket_opts(conn, active: :once)

        :persistent_term.put(
          {__MODULE__, state.client_name, state.broker_id, state.broker_index},
          conn
        )

        %__MODULE__{state | conn: conn, reconnect_attempts: 0}

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
end
