defmodule Klife.TestCustomPartitioner do
  @moduledoc false
  @behaviour Klife.Behaviours.Partitioner

  alias Klife.Record

  @impl true
  def get_partition(%Record{} = record, _max_partition) do
    String.to_integer(record.key)
  end
end
