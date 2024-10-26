defmodule Klife.ClientTest do
  use ExUnit.Case, async: false
  @tag capture_log: true
  doctest Klife.Client
end
