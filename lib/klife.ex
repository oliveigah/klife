defmodule Klife do
  alias KlifeProtocol.Socket
  alias KlifeProtocol.Messages

  def test do
    {:ok, socket} = Socket.connect("localhost", 19092, backend: :gen_tcp, active: false)
    version = 0
    input = %{headers: %{correlation_id: 123}, content: %{}}
    serialized_msg = Messages.ApiVersions.serialize_request(input, version)
    :ok = :gen_tcp.send(socket, serialized_msg)
    {:ok, received_data} = :gen_tcp.recv(socket, 0, 5_000)
    Messages.ApiVersions.deserialize_response(received_data, version)
  end
end
