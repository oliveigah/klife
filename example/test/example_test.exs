defmodule ExampleTest do
  use ExUnit.Case
  alias Klife.Record
  alias Klife.Test, as: KlifeTest

  test "simplest client" do
    client = Example.MySimplestClient

    rec = %Record{value: :rand.bytes(10), topic: "my_topic_1"}
    assert {:ok, %Record{partition: _partition, offset: _offset}} = Example.produce(client, rec)

    # KlifeTest.assert_offset(client, rec, offset, partition: partition)
  end
end
