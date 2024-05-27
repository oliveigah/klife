defmodule Klife.Partitioner do
  @callback get_partition(record :: %Klife.Record{}, max_partition :: integer) :: integer
end
