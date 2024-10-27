defmodule Klife.Connection do
  @moduledoc false
  alias KlifeProtocol.Socket
  alias Klife.Connection.MessageVersions, as: MV
  alias KlifeProtocol.Messages, as: M

  defstruct [:socket, :host, :port, :read_timeout, :ssl]

  def new(url, ssl, connect_opts, socket_opts, sasl_opts) do
    %{host: host, port: port} = parse_url(url)

    connect_opts =
      Keyword.merge(connect_opts, backend: get_socket_backend(ssl), sasl_opts: sasl_opts)

    case Socket.connect(host, port, connect_opts) do
      {:ok, socket} ->
        conn =
          %__MODULE__{
            socket: socket,
            host: host,
            port: port,
            ssl: ssl,
            # TODO: Should we expose this?
            read_timeout: :timer.seconds(15)
          }

        :ok = socket_opts(conn, socket_opts)

        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def authenticate_sasl(%__MODULE__{socket: socket} = conn, sasl_opts) do
    Socket.authenticate(socket, get_socket_backend(conn.ssl), sasl_opts)
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

  def read(%__MODULE__{ssl: false} = conn),
    do: :gen_tcp.recv(conn.socket, 0, conn.read_timeout)

  def read(%__MODULE__{ssl: true} = conn),
    do: :ssl.recv(conn.socket, 0, conn.read_timeout)

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
