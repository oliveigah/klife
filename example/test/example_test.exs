defmodule ExampleTest do
  use ExUnit.Case
  alias Klife.Record
  alias Klife.Testing

  test "simplest client" do
    client = Example.MySimplestClient
    topic = "my_topic_1"
    val = :rand.bytes(100)

    rec = %Record{value: val, topic: topic}

    assert {:ok, %Record{partition: _partition, offset: _offset} = resp} =
             Example.MySimplestClient.produce(rec)

    [rec1] = Testing.all_produced(client, topic, value: val)

    assert rec1.value == resp.value
    assert rec1.offset == resp.offset
    # KlifeTest.assert_offset(client, rec, offset, partition: partition)
  end
end
