defmodule Klife.RecordTest do
  use ExUnit.Case

  alias Klife.Record

  test "estimate size" do
    r1 = %Record{value: :rand.bytes(1000)}
    assert Record.estimate_size(r1) == 1080

    r2 = %Record{value: :rand.bytes(1000), key: :rand.bytes(1000)}
    assert Record.estimate_size(r2) == 2080

    r3 = %Record{
      value: :rand.bytes(1000),
      key: :rand.bytes(1000),
      headers: [
        %{key: :rand.bytes(1000), value: :rand.bytes(1000)}
      ]
    }

    assert Record.estimate_size(r3) == 4080

    r4 = %Record{
      value: :rand.bytes(1000),
      key: :rand.bytes(1000),
      headers: [
        %{key: :rand.bytes(1000), value: :rand.bytes(1000)},
        %{key: :rand.bytes(1000), value: :rand.bytes(1000)}
      ]
    }

    assert Record.estimate_size(r4) == 6080
  end
end
