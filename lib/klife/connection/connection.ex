defmodule Klife.Connection do
  alias KlifeProtocol.Socket

  defstruct [:socket, :host, :port, :connect_timeout, :read_timeout, :ssl]

  @default_opts %{
    connect_timeout: :timer.seconds(15),
    read_timeout: :timer.seconds(15),
    ssl: false,
    ssl_opts: %{}
  }
  def new(url, opts \\ []) do
    %{host: host, port: port} = parse_url(url)
    map_opts = Map.merge(@default_opts, Map.new(opts))

    socket_opts =
      Keyword.merge(
        [
          inet_backend: :socket,
          active: Keyword.get(opts, :active, false),
          backend: get_socket_backend(map_opts)
        ],
        Keyword.get(opts, :ssl_opts, [])
      )

    case Socket.connect(host, port, socket_opts) do
      {:ok, socket} ->
        filtered_opts = Map.take(map_opts, Map.keys(%__MODULE__{}))

        conn =
          %__MODULE__{socket: socket, host: host, port: port}
          |> Map.merge(filtered_opts)

        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_socket_backend(%{ssl: false}), do: :gen_tcp
  defp get_socket_backend(%{ssl: true}), do: :ssl

  def write(msg, %__MODULE__{ssl: false} = conn), do: :gen_tcp.send(conn.socket, msg)
  def write(msg, %__MODULE__{ssl: true} = conn), do: :ssl.send(conn.socket, msg)

  def read(%__MODULE__{ssl: false} = conn),
    do: :gen_tcp.recv(conn.socket, 0, conn.read_timeout)

  def read(%__MODULE__{ssl: true} = conn),
    do: :ssl.recv(conn.socket, 0, conn.read_timeout)

  def close(%__MODULE__{ssl: false} = conn), do: :gen_tcp.close(conn.socket)
  def close(%__MODULE__{ssl: true} = conn), do: :ssl.close(conn.socket)

  def set_opts(%__MODULE__{ssl: false, socket: socket}, opts), do: :inet.setopts(socket, opts)
  def set_opts(%__MODULE__{ssl: true, socket: socket}, opts), do: :ssl.setopts(socket, opts)

  defp parse_url(url) do
    [host, port] = String.split(url, ":")
    %{host: host, port: String.to_integer(port)}
  end
end
