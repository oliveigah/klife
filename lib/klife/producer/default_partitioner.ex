defmodule Klife.Producer.DefaultPartitioner do
  @moduledoc """
  Default partitioner implementation.

  Uses the following logic:

  - if record key is `nil` than defines a random partition
  - if record key is not `nil` than define a partition using phash2 function

  Source code is something like this:

  ```elixir
  defmodule Klife.Producer.DefaultPartitioner do
    @behaviour Klife.Behaviours.Partitioner
    alias Klife.Record

    @impl Klife.Behaviours.Partitioner
    def get_partition(%Record{key: nil}, max_partition),
      do: :rand.uniform(max_partition + 1) - 1

    def get_partition(%Record{key: key}, max_partition),
      do: :erlang.phash2(key, max_partition + 1)
  end
  ```
  """
  @behaviour Klife.Behaviours.Partitioner
  alias Klife.Record

  @impl Klife.Behaviours.Partitioner
  def get_partition(%Record{key: nil}, max_partition),
    do: :rand.uniform(max_partition + 1) - 1

  def get_partition(%Record{key: key}, max_partition),
    do: :erlang.phash2(key, max_partition + 1)
end
