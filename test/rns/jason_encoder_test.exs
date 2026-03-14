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

  describe "Destination encoding" do
    test "encodes destination to JSON" do
      id = RNS.Identity.new()
      dest = RNS.Destination.build(id, 0x11, 0x00, "testapp", ["echo"])
      {:ok, json} = Jason.encode(dest)
      decoded = Jason.decode!(json)

      assert decoded["hash"] == dest.hexhash
      assert decoded["name"] == dest.name
      assert decoded["type"] == dest.type
      assert decoded["direction"] == dest.direction
    end

    test "encodes plain destination to JSON" do
      dest = RNS.Destination.build(nil, 0x11, 0x02, "testapp", ["plain"])
      {:ok, json} = Jason.encode(dest)
      decoded = Jason.decode!(json)

      assert decoded["hash"] == dest.hexhash
      assert decoded["name"] == dest.name
      assert is_nil(decoded["identity"])
    end

    test "destination round-trips through Jason.encode!/1" do
      id = RNS.Identity.new()
      dest = RNS.Destination.build(id, 0x11, 0x00, "testapp", ["echo"])
      assert is_binary(Jason.encode!(dest))
    end
  end
end
