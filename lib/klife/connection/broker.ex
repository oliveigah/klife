defmodule Klife.Connection.Broker do
  use GenServer

  import Klife.ProcessRegistry

  require Logger

  alias Klife.Connection
  alias Klife.Connection.Controller

  defstruct [:broker_id, :cluster_name, :conn, :socket_opts, :url]

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
      url: url
    }

    send(self(), :connect)
    {:ok, state}
  end

  def handle_info(:connect, %__MODULE__{} = state) do
    case Connection.new(state.url, state.socket_opts) do
      {:ok, conn} ->
        :persistent_term.put({__MODULE__, state.cluster_name, state.broker_id}, conn)
        new_state = Map.put(state, :conn, conn)

        {:noreply, new_state}

      {:error, _reason} = res ->
        :persistent_term.erase({__MODULE__, state.cluster_name, state.broker_id})

        Logger.error("""
        Error while connecting to broker #{state.broker_id} on host #{state.url}. Reason: #{inspect(res)}
        """)

        Process.send_after(self(), :connect, :timer.seconds(10))
        {:noreply, state}
    end
  end

  def handle_info({:tcp, _port, msg}, %__MODULE__{} = state) do
    reply_message(msg, state.cluster_name)
    {:noreply, state}
  end

  def handle_info({:ssl, {:sslsocket, _socket_details, _pids}, msg}, %__MODULE__{} = state) do
    reply_message(msg, state.cluster_name)
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
        version,
        cluster_name,
        broker_id,
        content \\ %{},
        headers \\ %{}
      ) do
    correlation_id = Controller.get_next_correlation_id(cluster_name)

    input = %{
      headers: Map.merge(headers, %{correlation_id: correlation_id}),
      content: content
    }

    broker_id =
      if broker_id == :any, do: Controller.get_random_broker_id(cluster_name), else: broker_id

    serialized_msg = apply(message_mod, :serialize_request, [input, version])
    true = Controller.insert_in_flight(cluster_name, correlation_id)
    conn = :persistent_term.get({__MODULE__, cluster_name, broker_id})

    case Connection.write(serialized_msg, conn) do
      :ok ->
        receive do
          {:broker_response, response} ->
            apply(message_mod, :deserialize_response, [response, version])
        after
          5_000 ->
            Controller.take_from_in_flight(cluster_name, correlation_id)
        end
    end
  end

  def reply_message(<<correlation_id::32-signed, _rest::binary>> = reply, cluster_name) do
    case Controller.take_from_in_flight(cluster_name, correlation_id) do
      nil ->
        # TODO: HOW TO HANDLE THIS?
        nil

      {^correlation_id, waiting_pid} ->
        Process.send(waiting_pid, {:broker_response, reply}, [])
    end
  end
end
