defmodule Klife.HelpersTest do
  use ExUnit.Case, async: true

  alias Klife.Helpers

  test "with_timeout!/3 retries with the next input and returns the first final value" do
    test_pid = self()

    result =
      Helpers.with_timeout!(
        [:a, :b, :c],
        fn
          [first | rest] ->
            send(test_pid, {:attempt, [first | rest]})
            {:retry, rest, {:failed, first}}

          [] ->
            :done
        end,
        10_000
      )

    assert result == :done
    assert_received {:attempt, [:a, :b, :c]}
    assert_received {:attempt, [:b, :c]}
    assert_received {:attempt, [:c]}
  end

  test "with_timeout!/3 keeps the input on :retry and {:retry, error}" do
    counter = :counters.new(1, [])

    result =
      Helpers.with_timeout!(
        :same_input,
        fn :same_input ->
          :counters.add(counter, 1, 1)

          case :counters.get(counter, 1) do
            1 -> :retry
            2 -> {:retry, :some_error}
            3 -> {:ok, :same_input}
          end
        end,
        10_000
      )

    assert result == {:ok, :same_input}
  end

  test "with_timeout!/4 sleeps the given backoff between attempts" do
    started = System.monotonic_time(:millisecond)

    assert :done =
             Helpers.with_timeout!(
               5,
               fn
                 0 -> :done
                 n -> {:retry, n - 1, :not_yet}
               end,
               10_000,
               10
             )

    # Five 10 ms sleeps, far below a single default backoff of at least 500 ms
    assert System.monotonic_time(:millisecond) - started < 400
  end

  test "with_timeout!/3 raises with the last error once the deadline passes" do
    # The first attempt runs well inside the 100 ms, and the sleep after it outlasts them
    assert_raise RuntimeError, ~r/Last error is: \{:still_failing, \[:b\]\}/, fn ->
      Helpers.with_timeout!(
        [:a, :b],
        fn [_first | rest] -> {:retry, rest, {:still_failing, rest}} end,
        100
      )
    end
  end
end
