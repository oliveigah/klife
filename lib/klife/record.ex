defmodule Klife.Record do
  defstruct [
    :value,
    :key,
    :headers,
    :topic,
    :partition,
    :offset,
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

  def verify_batch(produce_resps) do
    case Enum.group_by(produce_resps, &elem(&1, 0), &elem(&1, 1)) do
      %{error: error_list} ->
        {:error, error_list}

      %{ok: resp} ->
        {:ok, resp}
    end
  end

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
    do: v |> Map.to_list() |> Enum.reduce(0, fn {_k, v}, acc -> acc + get_size(v) end)

  defp get_size(v) when is_list(v), do: Enum.reduce(v, 0, fn i, acc -> acc + get_size(i) end)
end
