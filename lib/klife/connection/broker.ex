defmodule Klife.Connection.Broker do
  use GenServer

  import Klife.ProcessRegistry

  require Logger

  alias Klife.Connection
  alias Klife.Connection.Controller

  @reconnect_delays_seconds [5, 10, 30, 60, 90, 120, 300]

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

    send(self(), :connect)
    {:ok, state}
  end

  def handle_info(:connect, %__MODULE__{} = state) do
    case Connection.new(state.url, Keyword.merge(state.socket_opts, active: :once)) do
      {:ok, conn} ->
        :persistent_term.put({__MODULE__, state.cluster_name, state.broker_id}, conn)
        {:noreply, %__MODULE__{state | conn: conn, reconnect_attempts: 0}}

      {:error, _reason} = res ->
        :persistent_term.erase({__MODULE__, state.cluster_name, state.broker_id})

        Logger.error("""
        Error while connecting to broker #{state.broker_id} on host #{state.url}. Reason: #{inspect(res)}
        """)

        Process.send_after(self(), :connect, get_reconnect_delay(state))

        {:noreply, %__MODULE__{state | reconnect_attempts: state.reconnect_attempts + 1}}
    end
  end

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

  def send_message_sync(
        message_mod,
        version,
        cluster_name,
        broker_id,
        content \\ %{},
        headers \\ %{}
      ) do
    correlation_id = Controller.get_next_correlation_id(cluster_name)
    broker_id = get_broker_id(broker_id, cluster_name)
    conn = get_connection(cluster_name, broker_id)

    input = %{
      headers: Map.put(headers, :correlation_id, correlation_id),
      content: content
    }

    serialized_msg = apply(message_mod, :serialize_request, [input, version])

    true = Controller.insert_in_flight(cluster_name, correlation_id)

    case Connection.write(serialized_msg, conn) do
      :ok ->
        receive do
          {:broker_response, response} ->
            apply(message_mod, :deserialize_response, [response, version])
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

  def send_message_async(
        message_mod,
        version,
        cluster_name,
        broker_id,
        content \\ %{},
        headers \\ %{},
        callback \\ fn -> :noop end
      ) do
    correlation_id = Controller.get_next_correlation_id(cluster_name)
    broker_id = get_broker_id(broker_id, cluster_name)

    conn = get_connection(cluster_name, broker_id)

    input = %{
      headers: Map.put(headers, :correlation_id, correlation_id),
      content: content
    }

    serialized_msg = apply(message_mod, :serialize_request, [input, version])

    true = Controller.insert_in_flight(cluster_name, correlation_id, callback)

    case Connection.write(serialized_msg, conn) do
      :ok ->
        :ok

      {:error, reason} = res ->
        Logger.error("""
        Error while sending async message to broker #{broker_id} on host #{conn.host}. Reason: #{inspect(res)}
        """)

        {:error, reason}
    end
  end

  def reply_message(<<correlation_id::32-signed, _rest::binary>> = reply, cluster_name, conn) do
    case Controller.take_from_in_flight(cluster_name, correlation_id) do
      nil ->
        # TODO: HOW TO HANDLE THIS?
        # There are 2 possibilities to this case
        #
        # 1 - An async message was sent which does not populate the inflight table ()
        # 2 - A sync message was sent but the caller gave up waiting the response
        #
        # The only problematic case is the second one since the caller will assume
        # that the message was not delivered and may send it again.
        #
        # Dependeing on the message being sent and the idempotency configuration
        # this may not be a problem.
        #
        # Must revisit this later.
        #
        nil

      {^correlation_id, callback} when is_function(callback) ->
        Task.start(fn -> callback.() end)


      {^correlation_id, waiting_pid} ->
        Process.send(waiting_pid, {:broker_response, reply}, [])
    end

    Connection.set_opts(conn, active: :once)
  end

  defp get_reconnect_delay(%__MODULE__{reconnect_attempts: attempts}) do
    max_idx = length(@reconnect_delays_seconds) - 1
    base_delay = Enum.at(@reconnect_delays_seconds, min(attempts, max_idx))
    jitter_delay = base_delay * (Enum.random(50..150) / 100)
    :timer.seconds(round(jitter_delay))
  end

  defp get_broker_id(:any, cluster_name), do: Controller.get_random_broker_id(cluster_name)
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
end
