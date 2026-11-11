defmodule Klife.Helpers do
  @moduledoc false

  def with_timeout!(fun, timeout) when is_function(fun, 0),
    do: with_timeout!(nil, fn nil -> fun.() end, timeout)

  # Calls fun with input until it returns something other than a retry, sleeping
  # backoff_ms (an integer or a range to pick from) between attempts. `:retry` and
  # `{:retry, error}` call it again with the same input, while
  # `{:retry, next_input, error}` replaces the input, so each attempt may carry only
  # what is still pending plus anything the caller refreshed.
  def with_timeout!(input, fun, timeout, backoff_ms \\ 500..1000) when is_function(fun, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_with_timeout!(deadline, fun, input, backoff_ms, nil)
  end

  defp do_with_timeout!(deadline, fun, input, backoff_ms, last_error) do
    if System.monotonic_time(:millisecond) < deadline do
      case fun.(input) do
        :retry ->
          backoff(backoff_ms)
          do_with_timeout!(deadline, fun, input, backoff_ms, last_error)

        {:retry, error} ->
          backoff(backoff_ms)
          do_with_timeout!(deadline, fun, input, backoff_ms, error)

        {:retry, next_input, error} ->
          backoff(backoff_ms)
          do_with_timeout!(deadline, fun, next_input, backoff_ms, error)

        val ->
          val
      end
    else
      raise "Timeout while waiting for broker response! Last error is: #{inspect(last_error)}"
    end
  end

  defp backoff(ms) when is_integer(ms), do: Process.sleep(ms)
  defp backoff(%Range{} = range), do: Process.sleep(Enum.random(range))

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
