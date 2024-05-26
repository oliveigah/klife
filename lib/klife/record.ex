defmodule Klife.Record do
  defstruct [
    :value,
    :key,
    :headers,
    :topic,
    :partition,
    :offset,
    :__batch_index,
    :__estimated_size
  ]

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
