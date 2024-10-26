defmodule Klife.Behaviours.Partitioner do
  @moduledoc """
  Behaviour to define a partitioner

  Modules must implement this behaviour in order to be used as partitioners on
  the `Klife.Client` producer API.
  """
  @doc """
  Define the partition of a given record.

  Receives the record and the highest known partition for the record's topic.

  Must return an integer between 0 and `max_partition`. See `Klife.Producer.DefaultPartitioner` for
  an example.
  """
  @callback get_partition(record :: %Klife.Record{}, max_partition :: integer) :: integer
end
