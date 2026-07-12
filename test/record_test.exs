defmodule Klife.RecordTest do
  use ExUnit.Case

  alias Klife.Record

  doctest Klife.Record

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

  test "parse_from_protocol uses each record offset delta" do
    record_batch = %{
      attributes: 0,
      base_offset: 100,
      base_timestamp: 1_000,
      records: [
        %{key: "a", value: "one", headers: [], offset_delta: 0, timestamp_delta: 0},
        %{key: "b", value: "two", headers: [], offset_delta: 3, timestamp_delta: 10},
        %{key: "c", value: "three", headers: [], offset_delta: 7, timestamp_delta: 20}
      ]
    }

    assert [
             %Record{offset: 100, timestamp: 1_000, is_aborted: false},
             %Record{offset: 103, timestamp: 1_010, is_aborted: true},
             %Record{offset: 107, timestamp: 1_020, is_aborted: true}
           ] =
             Record.parse_from_protocol("topic", 0, record_batch, first_aborted_offset: 103)
  end
end
