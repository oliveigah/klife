defmodule Klife.Producer.DefaultPartitioner do
  @moduledoc """
  Default partitioner implementation compatible with Kafka's DefaultPartitioner.

  Uses the following logic:

  - if record key is `nil` than defines a random partition
  - if record key is not `nil` than define a partition using Kafka's Murmur2 hash

  This ensures that records with the same key are assigned to the same partition
  regardless of whether they are produced by klife or any other Kafka client
  (Java, Python, Go, etc.).
  """
  @behaviour Klife.Behaviours.Partitioner
  alias Klife.Record
  alias Klife.Producer.Murmur2

  @impl Klife.Behaviours.Partitioner
  def get_partition(%Record{key: nil}, max_partition),
    do: :rand.uniform(max_partition + 1) - 1

  def get_partition(%Record{key: key}, max_partition) do
    key
    |> Murmur2.hash()
    # Matches Kafka's: Utils.toPositive(Utils.murmur2(keyBytes)) % numPartitions
    # https://github.com/apache/kafka/blob/d920f8bc1f668b48c73abfd7214dabf14ca45a2b/clients/src/main/java/org/apache/kafka/common/utils/Utils.java#L1198-L1199
    |> Bitwise.band(0x7FFFFFFF)
    |> rem(max_partition + 1)
  end
end
