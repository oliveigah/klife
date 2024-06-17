defmodule Example do
  def produce(client, rec, opts \\ []), do: client.produce(rec, opts)
  def produce_batch(client, recs, opts \\ []), do: client.produce_batch(recs, opts)
  def produce_batch_txn(client, recs, opts \\ []), do: client.produce_batch_txn(recs, opts)
  def transaction(client, fun, opts \\ []), do: client.transaction(fun, opts)
  def in_txn?(client), do: client.in_txn?()
end
