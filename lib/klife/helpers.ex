defmodule Klife.Helpers do
  def with_timeout!(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_with_timeout!(deadline, fun)
  end

  defp do_with_timeout!(deadline, fun) do
    if System.monotonic_time(:millisecond) < deadline do
      case fun.() do
        :retry ->
          Process.sleep(Enum.random(500..1000))
          do_with_timeout!(deadline, fun)

        val ->
          val
      end
    else
      raise "Timeout while waiting for broker response"
    end
  end

  def keyword_list_to_map(data) do
    if Keyword.keyword?(data), do: do_parse_kw_to_map(data), else: data
  end

  defp do_parse_kw_to_map(kw) do
    kw
    |> Enum.map(fn {k, v} ->
      str_key = Atom.to_string(k)
      # Some opts must kept as kw lists, such as conn_opts or sasl_opts, because they are
      # forwarded to other functions that expects a kw list
      is_opts? = String.ends_with?(str_key, "_opts")
      is_kw? = Keyword.keyword?(v)
      is_list? = is_list(v)

      cond do
        is_opts? -> {k, v}
        is_kw? -> {k, keyword_list_to_map(v)}
        is_list? -> {k, Enum.map(v, fn lv -> keyword_list_to_map(lv) end)}
        true -> {k, v}
      end
    end)
    |> Map.new()
  end
end
