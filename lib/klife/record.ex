defmodule Klife.Record do
  @moduledoc """
  Kafka record representation.

  Represents a Kafka record struct used across all `Klife.Client` APIs for
  both producer and consumer.

  ## Producer API

  When used as input to a produce call, the following fields are relevant:
  - `:value` (required)
  - `:topic` (required)
  - `:key` (optional)
  - `:headers` (optional, defaults to `[]`)
  - `:partition` (optional, if omitted, the configured partitioner will assign one)

  On success, the returned record is enriched with:
  - `:offset`: the offset assigned by the broker
  - `:partition`: the partition the record was written to (if not provided as input)
  - `:error_code`: set on failure (see [Kafka protocol error codes](https://kafka.apache.org/11/protocol.html#protocol_error_codes))

  ## Consumer API

  Records returned by the fetch functions or delivered to a consumer group
  callback are fully populated structs. In addition to the fields listed above,
  the following are also set:
  - `:timestamp`: the record timestamp in milliseconds since the Unix epoch
  - `:batch_attributes`: metadata about the record batch (see [Kafka protocol record batch](https://kafka.apache.org/documentation/#recordbatch))
  - `:is_aborted`: `true` if the record belongs to an aborted transaction
  - `:consumer_attempts`: number of times this record has been delivered to a
    consumer callback (starts at `0`, incremented on each retry by the consumer group).
    This is a best-effort, in-memory counter. It may be reset to `0` after rebalances
    or unexpected crashes
  """
  defstruct [
    :key,
    :topic,
    :partition,
    :offset,
    :timestamp,
    :error_code,
    :value,
    :batch_attributes,
    :is_aborted,
    {:consumer_attempts, 0},
    {:headers, []},
    :__batch_index,
    :__estimated_size,
    :__callback
  ]

  @type t :: %__MODULE__{
          value: binary(),
          key: binary(),
          headers: list(%{key: binary(), value: binary()}),
          topic: String.t(),
          partition: non_neg_integer(),
          offset: non_neg_integer(),
          timestamp: nil | integer(),
          consumer_attempts: nil | non_neg_integer(),
          error_code: integer()
        }

  def t, do: t()

  @doc """
  Utility function to verify if all records in a `produce_batch/3` were successfully produced.

  ## Examples
      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> {:ok, [%Klife.Record{value: "my_val_1"}, _r2, _r3]} = MyClient.produce_batch(input) |> Klife.Record.verify_batch()

  Partial error example. Notice that records 1 and 3 were successfully produced and only record 2
  has errors, so the function will return `{:error, [rec1, rec2, rec3]}`

      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: :rand.bytes(2_000_000), topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> {:error, [_rec1, %Klife.Record{error_code: 10}, _rec3]} = MyClient.produce_batch(input) |> Klife.Record.verify_batch()
  """
  def verify_batch(produce_resps) do
    if Enum.any?(produce_resps, &match?({:error, %__MODULE__{}}, &1)),
      do: {:error, Enum.map(produce_resps, fn {_ok_error, rec} -> rec end)},
      else: {:ok, Enum.map(produce_resps, fn {_ok_error, rec} -> rec end)}
  end

  @doc """
    Same as `verify_batch/1` but raises if any record fails and does not return ok/error tuple.

  ## Examples
      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> [_r1, _r2, _r3] = MyClient.produce_batch(input) |> Klife.Record.verify_batch!()
  """
  def verify_batch!(produce_resps) do
    case verify_batch(produce_resps) do
      {:ok, resp} -> resp
      {:error, errors} -> raise "Batch verification failed: #{inspect(errors)}"
    end
  end

  @doc false
  def estimate_size(%__MODULE__{} = record) do
    # add 80 extra bytes to account for other fields
    80 + get_size(record.value) + get_size(record.key) + get_size(record.headers)
  end

  @doc false
  def parse_from_protocol(t, p, record_batch, opts \\ []) do
    base_offset = record_batch[:base_offset]
    base_timestamp = record_batch[:base_timestamp]
    record_list = Enum.with_index(record_batch[:records])
    batch_attributes = KlifeProtocol.RecordBatch.decode_attributes(record_batch[:attributes])
    first_aborted_offset = opts[:first_aborted_offset] || :infinity

    Enum.map(record_list, fn {rec, idx} ->
      %__MODULE__{
        key: rec[:key],
        headers: rec[:headers],
        value: rec[:value],
        topic: t,
        partition: p,
        offset: base_offset + idx,
        timestamp: record_timestamp(base_timestamp, rec[:timestamp_delta]),
        batch_attributes: batch_attributes,
        is_aborted: base_offset + idx >= first_aborted_offset
      }
    end)
  end

  defp record_timestamp(nil, _delta), do: nil
  defp record_timestamp(_base, nil), do: nil
  defp record_timestamp(base, delta), do: base + delta

  @doc """
  Filters a list of `Klife.Record` structs returned by the fetch API.

  Useful when working with the standalone fetch functions
  to remove records that are not relevant to your application logic.

  ## Options

  - `:base_offset` - Drop all records with an offset strictly less than this value.
    Defaults to `-1` (no records dropped).
  - `:exclude_control` - When `true`, removes internal Kafka control records
    (e.g. transaction markers). Defaults to `false`.
  - `:exclude_aborted` - When `true`, removes records that belong to aborted
    transactions. Defaults to `false`.
  """
  def filter_records(rec_list, opts \\ []) do
    base_offset = opts[:base_offset] || -1
    exclude_control = opts[:exclude_control] || false
    exclude_aborted = opts[:exclude_aborted] || false

    base_filtered =
      Enum.drop_while(rec_list, fn %__MODULE__{} = rec -> rec.offset < base_offset end)

    if Enum.any?([exclude_control, exclude_aborted]) do
      Enum.reject(base_filtered, fn %__MODULE__{} = r ->
        cond do
          exclude_control and r.batch_attributes.is_control_batch ->
            true

          exclude_aborted and r.is_aborted and r.batch_attributes.is_transactional ->
            true

          true ->
            false
        end
      end)
    else
      base_filtered
    end
  end

  defp get_size(nil), do: 0
  defp get_size([]), do: 0
  defp get_size(v) when is_binary(v), do: byte_size(v)

  defp get_size(val) when is_map(val),
    do: Enum.reduce(val, 0, fn {_k, v}, acc -> acc + get_size(v) end)

  defp get_size(v) when is_list(v), do: Enum.reduce(v, 0, fn i, acc -> acc + get_size(i) end)
end
