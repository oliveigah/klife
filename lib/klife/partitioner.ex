defmodule Klife.Partitioner do
  alias Klife.Record

  @callback get_partition(record :: %Record{}, max_partition :: integer) :: integer

  @behaviour __MODULE__

  @impl __MODULE__
  def get_partition(%Record{key: nil}, max_partition),
    do: Enum.random(0..max_partition)

  def get_partition(%Record{key: key}, max_partition), do: :erlang.phash2(key, max_partition + 1)
end
