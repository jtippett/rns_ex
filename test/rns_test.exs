defmodule RNSTest do
  use ExUnit.Case

  test "version returns a string" do
    assert is_binary(RNS.version())
  end

  test "version matches mix project version" do
    assert RNS.version() == "0.1.0"
  end

  test "application starts successfully" do
    assert {:ok, _pid} = Application.ensure_all_started(:rns_ex)
  end
end
