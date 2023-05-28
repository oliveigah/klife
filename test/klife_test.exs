defmodule KlifeTest do
  use ExUnit.Case
  doctest Klife

  test "greets the world" do
    assert Klife.hello() == :world
  end
end
