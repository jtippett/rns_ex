defmodule RNS.Discovery.StamperTest do
  use ExUnit.Case, async: true

  alias RNS.Discovery
  alias RNS.Discovery.InterfaceAnnounceHandler
  alias RNS.Discovery.InterfaceAnnouncer

  # ── Mock Stamper for testing ──────────────────────────────────────────

  defmodule MockStamper do
    @behaviour RNS.Discovery.Stamper

    @stamp_size 32

    @impl true
    def stamp_size, do: @stamp_size

    @impl true
    def generate_stamp(infohash, opts \\ []) do
      stamp_cost = Keyword.get(opts, :stamp_cost, 14)
      # Generate a deterministic stamp from the infohash
      stamp = :crypto.hash(:sha256, infohash)
      {:ok, stamp, stamp_cost}
    end

    @impl true
    def stamp_workblock(infohash, _opts \\ []) do
      :crypto.hash(:sha256, "workblock:" <> infohash)
    end

    @impl true
    def stamp_value(_workblock, _stamp) do
      20
    end

    @impl true
    def stamp_valid(_stamp, required_value, _workblock) do
      # Always valid if required_value <= 20
      required_value <= 20
    end
  end

  defmodule RejectingStamper do
    @behaviour RNS.Discovery.Stamper

    @impl true
    def stamp_size, do: 32

    @impl true
    def generate_stamp(_infohash, _opts \\ []) do
      {:error, :stamp_generation_failed}
    end

    @impl true
    def stamp_workblock(infohash, _opts \\ []) do
      :crypto.hash(:sha256, infohash)
    end

    @impl true
    def stamp_value(_workblock, _stamp), do: 0

    @impl true
    def stamp_valid(_stamp, _required_value, _workblock), do: false
  end

  # ── Stamper Behaviour Tests ───────────────────────────────────────────

  describe "Stamper behaviour" do
    test "MockStamper implements the behaviour" do
      assert MockStamper.stamp_size() == 32
      assert {:ok, stamp, _value} = MockStamper.generate_stamp("test")
      assert byte_size(stamp) == 32
      workblock = MockStamper.stamp_workblock("test")
      assert is_binary(workblock)
      assert is_integer(MockStamper.stamp_value(workblock, stamp))
      assert is_boolean(MockStamper.stamp_valid(stamp, 14, workblock))
    end
  end

  # ── InterfaceAnnounceHandler fail-closed tests ────────────────────────

  describe "InterfaceAnnounceHandler without stamper" do
    test "new/1 defaults to nil stamper" do
      handler = InterfaceAnnounceHandler.new()
      assert handler.stamper == nil
    end

    test "decode_announce_data returns {:error, :no_stamper} without stamper" do
      handler = InterfaceAnnounceHandler.new()
      # Valid-length data (> 33 bytes)
      app_data = :crypto.strong_rand_bytes(100)
      result = InterfaceAnnounceHandler.decode_announce_data(handler, app_data)
      assert result == {:error, :no_stamper}
    end

    test "decode_announce_data still returns nil for nil app_data (no stamper)" do
      handler = InterfaceAnnounceHandler.new()
      assert InterfaceAnnounceHandler.decode_announce_data(handler, nil) == nil
    end

    test "decode_announce_data still returns nil for too-short data (no stamper)" do
      handler = InterfaceAnnounceHandler.new()
      assert InterfaceAnnounceHandler.decode_announce_data(handler, <<1, 2, 3>>) == nil
    end
  end

  describe "InterfaceAnnounceHandler with stamper" do
    test "new/1 accepts :stamper option" do
      handler = InterfaceAnnounceHandler.new(stamper: MockStamper)
      assert handler.stamper == MockStamper
    end

    test "decode_announce_data decodes valid unencrypted payload" do
      handler = InterfaceAnnounceHandler.new(stamper: MockStamper, required_value: 14)

      # Build a valid payload: flags(1) + packed_info + stamp(32)
      info = %{
        Discovery.interface_type_field() => "BackboneInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => :crypto.strong_rand_bytes(16),
        Discovery.name_field() => "TestInterface",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "192.168.1.100",
        Discovery.port_field() => 4242
      }

      packed = Msgpax.pack!(info, iodata: false)
      infohash = RNS.Identity.full_hash(packed)
      {:ok, stamp, _value} = MockStamper.generate_stamp(infohash)
      flags = 0x00
      app_data = <<flags>> <> packed <> stamp

      result = InterfaceAnnounceHandler.decode_announce_data(handler, app_data)
      assert is_map(result)
      assert result["type"] == "BackboneInterface"
      assert result["name"] == "TestInterface"
      assert result["reachable_on"] == "192.168.1.100"
      assert result["port"] == 4242
    end

    test "decode_announce_data rejects invalid stamp" do
      handler = InterfaceAnnounceHandler.new(stamper: RejectingStamper, required_value: 14)

      info = %{
        Discovery.interface_type_field() => "BackboneInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => :crypto.strong_rand_bytes(16),
        Discovery.name_field() => "TestInterface",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "10.0.0.1",
        Discovery.port_field() => 5555
      }

      packed = Msgpax.pack!(info, iodata: false)
      stamp = :crypto.strong_rand_bytes(32)
      flags = 0x00
      app_data = <<flags>> <> packed <> stamp

      result = InterfaceAnnounceHandler.decode_announce_data(handler, app_data)
      assert result == nil
    end

    test "decode_announce_data rejects stamp below required value" do
      # MockStamper returns value 20, but we require 25
      handler = InterfaceAnnounceHandler.new(stamper: MockStamper, required_value: 25)

      info = %{
        Discovery.interface_type_field() => "BackboneInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => :crypto.strong_rand_bytes(16),
        Discovery.name_field() => "LowValue",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "10.0.0.1",
        Discovery.port_field() => 5555
      }

      packed = Msgpax.pack!(info, iodata: false)
      infohash = RNS.Identity.full_hash(packed)
      {:ok, stamp, _} = MockStamper.generate_stamp(infohash)
      flags = 0x00
      app_data = <<flags>> <> packed <> stamp

      result = InterfaceAnnounceHandler.decode_announce_data(handler, app_data)
      assert result == nil
    end
  end

  # ── InterfaceAnnouncer fail-closed tests ──────────────────────────────

  describe "InterfaceAnnouncer without stamper" do
    test "get_interface_announce_data returns {:error, :no_stamper}" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        type_name: "BackboneInterface",
        name: "TestBackbone",
        discovery_name: "TestBackbone",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_publish_ifac: false,
        reachable_on: "192.168.1.100",
        bind_port: 4242
      }

      ctx = %{
        transport_enabled: true,
        transport_identity_hash: transport_id,
        stamper: nil,
        stamp_cache: %{}
      }

      result = InterfaceAnnouncer.get_interface_announce_data(interface, ctx)
      assert result == {:error, :no_stamper}
    end
  end

  describe "InterfaceAnnouncer with stamper" do
    test "get_interface_announce_data returns payload with valid stamper" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        type_name: "BackboneInterface",
        name: "TestBackbone",
        discovery_name: "TestBackbone",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_publish_ifac: false,
        reachable_on: "192.168.1.100",
        bind_port: 4242
      }

      ctx = %{
        transport_enabled: true,
        transport_identity_hash: transport_id,
        stamper: MockStamper,
        stamp_cache: %{}
      }

      result = InterfaceAnnouncer.get_interface_announce_data(interface, ctx)
      assert {payload, updated_cache} = result
      assert is_binary(payload)
      assert is_map(updated_cache)
      # Payload should be: flags(1) + packed + stamp(32)
      assert byte_size(payload) > 33
      # First byte is flags
      <<flags, _rest::binary>> = payload
      assert flags == 0x00
    end

    test "get_interface_announce_data uses stamp cache" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        type_name: "BackboneInterface",
        name: "TestBackbone",
        discovery_name: "TestBackbone",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_publish_ifac: false,
        reachable_on: "192.168.1.100",
        bind_port: 4242
      }

      ctx = %{
        transport_enabled: true,
        transport_identity_hash: transport_id,
        stamper: MockStamper,
        stamp_cache: %{}
      }

      # First call populates cache
      {_payload1, cache} = InterfaceAnnouncer.get_interface_announce_data(interface, ctx)
      assert map_size(cache) == 1

      # Second call with same cache should use cached stamp
      ctx2 = %{ctx | stamp_cache: cache}
      {_payload2, cache2} = InterfaceAnnouncer.get_interface_announce_data(interface, ctx2)
      assert cache2 == cache
    end

    test "get_interface_announce_data returns error when stamp generation fails" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        type_name: "BackboneInterface",
        name: "TestBackbone",
        discovery_name: "TestBackbone",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_publish_ifac: false,
        reachable_on: "192.168.1.100",
        bind_port: 4242
      }

      ctx = %{
        transport_enabled: true,
        transport_identity_hash: transport_id,
        stamper: RejectingStamper,
        stamp_cache: %{}
      }

      result = InterfaceAnnouncer.get_interface_announce_data(interface, ctx)
      assert result == nil
    end

    test "get_interface_announce_data returns nil for non-discoverable type" do
      ctx = %{
        transport_enabled: true,
        transport_identity_hash: :crypto.strong_rand_bytes(16),
        stamper: MockStamper,
        stamp_cache: %{}
      }

      interface = %{
        type_name: "UDPInterface",
        name: "TestUDP",
        discovery_name: "TestUDP",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_publish_ifac: false
      }

      result = InterfaceAnnouncer.get_interface_announce_data(interface, ctx)
      assert result == nil
    end
  end
end
