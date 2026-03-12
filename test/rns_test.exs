defmodule RNSTest do
  use ExUnit.Case
  doctest RNS

  test "greets the world" do
    assert RNS.hello() == :world
  end
end
