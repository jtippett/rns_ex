defmodule RNS.JasonEncoderTest do
  use ExUnit.Case, async: true

  test "jason is available as a dependency" do
    assert Code.ensure_loaded?(Jason)
  end

  describe "Identity encoding" do
    test "encodes identity with keys to JSON" do
      id = RNS.Identity.new()
      {:ok, json} = Jason.encode(id)
      decoded = Jason.decode!(json)

      assert decoded["hash"] == id.hexhash
      assert decoded["public_key"] == RNS.Identity.public_hex(id)
      assert is_nil(decoded["private_key"])
    end

    test "encodes identity without keys to JSON" do
      id = RNS.Identity.new(create_keys: false)
      {:ok, json} = Jason.encode(id)
      decoded = Jason.decode!(json)

      assert is_nil(decoded["hash"])
      assert is_nil(decoded["public_key"])
    end

    test "encodes identity with app_data to JSON" do
      id = RNS.Identity.new()
      id = %{id | app_data: "hello"}
      {:ok, json} = Jason.encode(id)
      decoded = Jason.decode!(json)

      assert decoded["app_data"] == Base.encode16("hello", case: :lower)
    end

    test "identity round-trips through Jason.encode!/1" do
      id = RNS.Identity.new()
      assert is_binary(Jason.encode!(id))
    end
  end
end
