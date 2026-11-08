defmodule Klife.Connection do
  @moduledoc false
  alias KlifeProtocol.SASL
  alias KlifeProtocol.Socket
  alias Klife.Connection.MessageVersions, as: MV
  alias KlifeProtocol.Messages, as: M

  alias Klife.Connection.Controller

  defstruct [:socket, :host, :port, :read_timeout, :ssl, :session_lifetime_ms]

  def new(url, ssl, connect_opts, socket_opts, sasl_opts) do
    %{host: host, port: port} = parse_url(url)

    connect_opts = Keyword.merge(connect_opts, backend: get_socket_backend(ssl))

    with {:ok, socket} <- Socket.connect(host, port, connect_opts),
         conn = %__MODULE__{
           socket: socket,
           host: host,
           port: port,
           ssl: ssl,
           # TODO: Should we expose this?
           read_timeout: :timer.seconds(60)
         },
         {:ok, conn} <- close_on_error(authenticate_sasl(conn, sasl_opts), conn),
         :ok <- close_on_error(socket_opts(conn, socket_opts), conn) do
      {:ok, conn}
    end
  end

  defp close_on_error({:error, _reason} = error, conn) do
    close(conn)
    error
  end

  defp close_on_error(result, _conn), do: result

  # `session_lifetime_ms` is how long the broker keeps the session, 0 when it never
  # ends (also without SASL). Returns the socket's error when it fails during the
  # exchange, so callers can try again, and raises if the broker refuses the credentials
  def authenticate_sasl(%__MODULE__{} = conn, []),
    do: {:ok, %__MODULE__{conn | session_lifetime_ms: 0}}

  def authenticate_sasl(%__MODULE__{} = conn, sasl_opts) do
    # Same exchange as KlifeProtocol.Socket.authenticate/3, whose send and receive
    # raise on socket errors
    send_recv = fn data ->
      with :ok <- write(data, conn),
           {:ok, reply} <- recv(conn, 5_000) do
        reply
      else
        {:error, reason} -> throw({:sasl_socket_error, reason})
      end
    end

    {:ok, %{session_lifetime_ms: lifetime}} =
      SASL.authenticate(
        Keyword.fetch!(sasl_opts, :mechanism),
        Keyword.fetch!(sasl_opts, :handshake_vsn),
        Keyword.fetch!(sasl_opts, :auth_vsn),
        Keyword.get(sasl_opts, :mechanism_opts, []),
        send_recv
      )

    {:ok, %__MODULE__{conn | session_lifetime_ms: lifetime}}
  catch
    {:sasl_socket_error, reason} -> {:error, reason}
  end

  # A replaced connection keeps receiving replies this long, so requests sent
  # before the swap can still finish
  def drain_ms(client_name),
    do: Controller.get_default_request_timeout_ms(client_name) + :timer.seconds(5)

  # When to replace `conn` by a newly authenticated one, nil if its session never ends.
  # Same window as Kafka's Java client, 85% of the session plus up to 10% of jitter so
  # connections opened together don't re-authenticate together, but always a whole
  # drain before the session ends: Kafka reads a connection's requests one at a time
  # and drops it on the first one read after its session ended, with any still queued.
  # Sessions of at least two drains also mean a connection drains completely before
  # its replacement is replaced
  def reauth_in_ms(%__MODULE__{session_lifetime_ms: 0}, _drain_ms), do: nil

  def reauth_in_ms(%__MODULE__{session_lifetime_ms: lifetime}, drain_ms)
      when lifetime >= 2 * drain_ms,
      do: min(round(lifetime * (0.85 + :rand.uniform() * 0.10)), lifetime - drain_ms)

  def reauth_in_ms(%__MODULE__{session_lifetime_ms: lifetime} = conn, drain_ms) do
    raise """
    SASL session on #{conn.host}:#{conn.port} lasts #{lifetime}ms, shorter than \
    2 * (default_request_timeout_ms + 5000) (#{2 * drain_ms}ms): connections would \
    expire before their requests could finish
    """
  end

  def build_sasl_opts([], _), do: []

  def build_sasl_opts(base_sasl_opts, client_name) do
    msg_vsn_opts = [
      auth_vsn: MV.get(client_name, M.SaslAuthenticate),
      handshake_vsn: MV.get(client_name, M.SaslHandshake)
    ]

    Keyword.merge(msg_vsn_opts, base_sasl_opts)
  end

  defp get_socket_backend(false), do: :gen_tcp
  defp get_socket_backend(true), do: :ssl

  def write(msg, %__MODULE__{ssl: false} = conn), do: :gen_tcp.send(conn.socket, msg)
  def write(msg, %__MODULE__{ssl: true} = conn), do: :ssl.send(conn.socket, msg)

  def read(%__MODULE__{} = conn), do: recv(conn, conn.read_timeout)

  defp recv(%__MODULE__{ssl: false} = conn, timeout), do: :gen_tcp.recv(conn.socket, 0, timeout)
  defp recv(%__MODULE__{ssl: true} = conn, timeout), do: :ssl.recv(conn.socket, 0, timeout)

  def close(%__MODULE__{ssl: false} = conn), do: :gen_tcp.close(conn.socket)
  def close(%__MODULE__{ssl: true} = conn), do: :ssl.close(conn.socket)

  def socket_opts(%__MODULE__{}, []), do: :ok
  def socket_opts(%__MODULE__{ssl: false, socket: socket}, opts), do: :inet.setopts(socket, opts)
  def socket_opts(%__MODULE__{ssl: true, socket: socket}, opts), do: :ssl.setopts(socket, opts)

  defp parse_url(url) do
    [host, port] = String.split(url, ":")
    %{host: host, port: String.to_integer(port)}
  end
end
