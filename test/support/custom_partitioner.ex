defmodule Klife.TestCustomPartitioner do
  @behaviour Klife.Partitioner

  alias Klife.Record

  @impl true
  def get_partition(%Record{} = record, _max_partition) do
    String.to_integer(record.key)
  end
end
