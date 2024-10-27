defmodule Klife.Record do
  @moduledoc """
  Kafka record representation.

  Represents a Kafka record struct that will be used in the `Klife.Client` APIs.

  In general terms it can be used to represent input or output data.

  As an input the `Klife.Record` may have the following attributes:
  - `:value` (required)
  - `:topic` (required)
  - `:key` (optional)
  - `:headers` (optional)
  - `:partition` (optional)

  As an output the input record will be added with one or more the following attributes:
  - `:offset` (if it was succesfully written)
  - `:partition` (if it was not present in the input)
  - `:error_code` (if something goes wrong on produce. See [kafka protocol error code](https://kafka.apache.org/11/protocol.html#protocol_error_codes) for context)
  """
  defstruct [
    :key,
    :topic,
    :partition,
    :offset,
    :value,
    :headers,
    :error_code,
    :__batch_index,
    :__estimated_size
  ]

  @type t :: %__MODULE__{
          value: binary(),
          key: binary(),
          headers: list(%{key: binary(), value: binary()}),
          topic: String.t(),
          partition: non_neg_integer(),
          offset: non_neg_integer(),
          error_code: integer()
        }

  def t, do: t()

  @doc """
  Utility function to verify if all records in a `produce_batch/3` were successfully written.

  ## Examples
      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: "my_val_2", topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> {:ok, [_r1, _r2, _r3]} = MyClient.produce_batch(input) |> Klife.Record.verify_batch()

  Partial error example. Notice that records 1 and 3 were successfully produced but only record 2
  returns from this function.

      iex> rec1 = %Klife.Record{value: "my_val_1", topic: "my_topic_1"}
      iex> rec2 = %Klife.Record{value: :rand.bytes(2_000_000), topic: "my_topic_2"}
      iex> rec3 = %Klife.Record{value: "my_val_3", topic: "my_topic_3"}
      iex> input = [rec1, rec2, rec3]
      iex> {:error, %{2 => %Klife.Record{error_code: 10}}} = MyClient.produce_batch(input) |> Klife.Record.verify_batch()
  """
  def verify_batch(produce_resps) do
    case Enum.group_by(produce_resps, &elem(&1, 0), &elem(&1, 1)) do
      %{error: error_list} ->
        {:error, Map.new(error_list, &{&1.__batch_index - 1, &1})}

      %{ok: resp} ->
        {:ok, resp}
    end
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
      {:error, errors} -> raise "Error on batch verification. #{inspect(errors)}"
    end
  end

  @doc false
  def estimate_size(%__MODULE__{} = record) do
    # add 80 extra bytes to account for other fields
    80 + get_size(record.value) + get_size(record.key) + get_size(record.headers)
  end

  defp get_size(nil), do: 0
  defp get_size([]), do: 0
  defp get_size(v) when is_binary(v), do: byte_size(v)

  defp get_size(v) when is_map(v),
    do: Enum.reduce(v, 0, fn {_k, v}, acc -> acc + get_size(v) end)

  defp get_size(v) when is_list(v), do: Enum.reduce(v, 0, fn i, acc -> acc + get_size(i) end)
end
