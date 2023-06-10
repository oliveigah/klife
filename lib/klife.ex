defmodule Klife do
  alias KlifeProtocol.Messages
  alias Klife.Connection.Broker

  def test do
    version = 0
    cluster_name = :my_cluster_1

    {:ok, _} = Broker.send_message_sync(Messages.ApiVersions, version, cluster_name, :any)
  end
end
