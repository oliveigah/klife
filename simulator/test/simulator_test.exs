defmodule SimulatorTest do
  use ExUnit.Case
  doctest Simulator

  test "greets the world" do
    assert Simulator.hello() == :world
  end
end
