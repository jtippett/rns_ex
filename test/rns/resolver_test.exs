defmodule RNS.ResolverTest do
  use ExUnit.Case, async: true

  alias RNS.Resolver

  describe "resolve_identity/1" do
    test "returns nil for any name" do
      assert Resolver.resolve_identity("test.name") == nil
    end

    test "returns nil for empty string" do
      assert Resolver.resolve_identity("") == nil
    end

    test "returns nil for complex name" do
      assert Resolver.resolve_identity("some.application.instance") == nil
    end
  end
end
