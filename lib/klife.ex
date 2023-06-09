defmodule Klife do
  alias KlifeProtocol.Messages
  alias Klife.Connection.Broker

  def test do
    version = 0
    cluster_name = :my_cluster_1

    Broker.send_message(Messages.ApiVersions, version, cluster_name, :any)
    :ok
  end
end
