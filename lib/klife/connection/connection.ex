defmodule Klife.Connection do
  @moduledoc false
  alias KlifeProtocol.Socket

  defstruct [:socket, :host, :port, :read_timeout, :ssl]

  def new(url, ssl, connect_opts, socket_opts) do
    %{host: host, port: port} = parse_url(url)

    connect_opts = Keyword.merge(connect_opts, backend: get_socket_backend(ssl))

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
