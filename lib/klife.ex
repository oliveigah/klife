defmodule Klife do
  alias KlifeProtocol.Messages
  alias Klife.Connection.Broker

  def test do
    cluster_name = :my_test_cluster_1
    {:ok, _} = Broker.send_sync(Messages.ApiVersions, cluster_name, :any)
  end
end
