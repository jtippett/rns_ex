defmodule RNS.DiscoveryTest do
  use ExUnit.Case, async: true

  alias RNS.Discovery

  # ── Constants ──────────────────────────────────────────────────────────

  describe "constants" do
    test "field identifier constants" do
      assert Discovery.name_field() == 0xFF
      assert Discovery.transport_id_field() == 0xFE
      assert Discovery.interface_type_field() == 0x00
      assert Discovery.transport_field() == 0x01
      assert Discovery.reachable_on_field() == 0x02
      assert Discovery.latitude_field() == 0x03
      assert Discovery.longitude_field() == 0x04
      assert Discovery.height_field() == 0x05
      assert Discovery.port_field() == 0x06
      assert Discovery.ifac_netname_field() == 0x07
      assert Discovery.ifac_netkey_field() == 0x08
      assert Discovery.frequency_field() == 0x09
      assert Discovery.bandwidth_field() == 0x0A
      assert Discovery.spreading_factor_field() == 0x0B
      assert Discovery.coding_rate_field() == 0x0C
      assert Discovery.modulation_field() == 0x0D
      assert Discovery.channel_field() == 0x0E
    end

    test "APP_NAME constant" do
      assert Discovery.app_name() == "rnstransport"
    end
  end

  # ── Helper Functions ───────────────────────────────────────────────────

  describe "is_ip_address/1" do
    test "returns true for valid IPv4 addresses" do
      assert Discovery.is_ip_address("192.168.1.1") == true
      assert Discovery.is_ip_address("10.0.0.1") == true
      assert Discovery.is_ip_address("255.255.255.255") == true
      assert Discovery.is_ip_address("0.0.0.0") == true
      assert Discovery.is_ip_address("127.0.0.1") == true
    end

    test "returns true for valid IPv6 addresses" do
      assert Discovery.is_ip_address("::1") == true
      assert Discovery.is_ip_address("fe80::1") == true
      assert Discovery.is_ip_address("2001:db8::1") == true
      assert Discovery.is_ip_address("::ffff:192.168.1.1") == true
    end

    test "returns false for invalid addresses" do
      assert Discovery.is_ip_address("not-an-ip") == false
      assert Discovery.is_ip_address("999.999.999.999") == false
      assert Discovery.is_ip_address("") == false
      assert Discovery.is_ip_address("hello.world") == false
    end
  end

  describe "is_hostname/1" do
    test "returns true for valid hostnames" do
      assert Discovery.is_hostname("example.com") == true
      assert Discovery.is_hostname("sub.example.com") == true
      assert Discovery.is_hostname("my-server.example.org") == true
      assert Discovery.is_hostname("a.b.c.d.e") == true
    end

    test "returns true for hostnames with trailing dot" do
      assert Discovery.is_hostname("example.com.") == true
    end

    test "returns false for names ending in all digits" do
      assert Discovery.is_hostname("192.168.1.1") == false
    end

    test "returns false for names exceeding 253 characters" do
      long_name = String.duplicate("a", 254) <> ".com"
      assert Discovery.is_hostname(long_name) == false
    end

    test "returns false for labels exceeding 63 characters" do
      long_label = String.duplicate("a", 64) <> ".com"
      assert Discovery.is_hostname(long_label) == false
    end

    test "returns false for labels starting with hyphen" do
      assert Discovery.is_hostname("-invalid.com") == false
    end

    test "returns false for labels ending with hyphen" do
      assert Discovery.is_hostname("invalid-.com") == false
    end

    test "returns false for empty string" do
      assert Discovery.is_hostname("") == false
    end
  end

  describe "sanitize/1" do
    test "removes newlines and carriage returns" do
      assert Discovery.sanitize("hello\nworld") == "helloworld"
      assert Discovery.sanitize("hello\rworld") == "helloworld"
      assert Discovery.sanitize("hello\r\nworld") == "helloworld"
    end

    test "strips leading and trailing whitespace" do
      assert Discovery.sanitize("  hello  ") == "hello"
    end

    test "handles clean strings" do
      assert Discovery.sanitize("hello") == "hello"
    end

    test "handles empty string" do
      assert Discovery.sanitize("") == ""
    end
  end
end

defmodule RNS.Discovery.InterfaceAnnounceHandlerTest do
  use ExUnit.Case, async: true

  alias RNS.Discovery
  alias RNS.Discovery.InterfaceAnnounceHandler

  describe "struct and constants" do
    test "FLAG_SIGNED constant" do
      assert InterfaceAnnounceHandler.flag_signed() == 0b00000001
    end

    test "FLAG_ENCRYPTED constant" do
      assert InterfaceAnnounceHandler.flag_encrypted() == 0b00000010
    end

    test "creates handler with default required_value" do
      handler = InterfaceAnnounceHandler.new()
      assert handler.required_value == 14
      assert handler.aspect_filter == "rnstransport.discovery.interface"
      assert handler.callback == nil
    end

    test "creates handler with custom required_value and callback" do
      cb = fn _info -> :ok end
      handler = InterfaceAnnounceHandler.new(required_value: 20, callback: cb)
      assert handler.required_value == 20
      assert handler.callback == cb
    end
  end

  describe "decode_announce_data/2" do
    test "returns nil for nil app_data" do
      handler = InterfaceAnnounceHandler.new()
      assert InterfaceAnnounceHandler.decode_announce_data(handler, nil) == nil
    end

    test "returns nil for too-short app_data" do
      handler = InterfaceAnnounceHandler.new()
      # Data must be > STAMP_SIZE + 1 bytes (stamp is 32 bytes typically, so > 33)
      assert InterfaceAnnounceHandler.decode_announce_data(handler, <<0, 1, 2, 3>>) == nil
    end

    test "decode_announce_data returns {:error, :no_stamper} without stamper" do
      # Build a valid-length announce payload
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
      stamp = :crypto.strong_rand_bytes(32)
      flags = 0x00
      app_data = <<flags>> <> packed <> stamp

      handler = InterfaceAnnounceHandler.new(required_value: 0)
      # Without a stamper configured, fail closed with {:error, :no_stamper}
      result = InterfaceAnnounceHandler.decode_announce_data(handler, app_data)
      assert result == {:error, :no_stamper}
    end
  end

  describe "parse_interface_info/1" do
    test "parses BackboneInterface info with config entry" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "BackboneInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "TestBackbone",
        Discovery.latitude_field() => 37.7749,
        Discovery.longitude_field() => -122.4194,
        Discovery.height_field() => 100,
        Discovery.reachable_on_field() => "192.168.1.100",
        Discovery.port_field() => 4242
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "abc123",
          3,
          System.system_time(:second)
        )

      assert result["type"] == "BackboneInterface"
      assert result["transport"] == true
      assert result["name"] == "TestBackbone"
      assert result["reachable_on"] == "192.168.1.100"
      assert result["port"] == 4242
      assert result["latitude"] == 37.7749
      assert result["longitude"] == -122.4194
      assert result["height"] == 100
      assert result["hops"] == 3
      assert is_binary(result["transport_id"])
      assert is_binary(result["network_id"])
      assert is_binary(result["config_entry"])
      assert result["config_entry"] =~ "type = BackboneInterface"
      assert result["config_entry"] =~ "target_port = 4242"
      assert is_binary(result["discovery_hash"])
    end

    test "parses TCPServerInterface info with config entry" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "TCPServerInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "TestTCP",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "10.0.0.1",
        Discovery.port_field() => 5555
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "def456",
          1,
          System.system_time(:second)
        )

      assert result["type"] == "TCPServerInterface"
      assert result["config_entry"] =~ "target_port = 5555"
    end

    test "parses I2PInterface info with config entry" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "I2PInterface",
        Discovery.transport_field() => false,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "TestI2P",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "abc123.b32.i2p"
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "abc789",
          2,
          System.system_time(:second)
        )

      assert result["type"] == "I2PInterface"
      assert result["config_entry"] =~ "type = I2PInterface"
      assert result["config_entry"] =~ "peers = abc123.b32.i2p"
    end

    test "parses RNodeInterface info with radio params" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "RNodeInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "TestRNode",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.frequency_field() => 868_000_000,
        Discovery.bandwidth_field() => 125_000,
        Discovery.spreading_factor_field() => 7,
        Discovery.coding_rate_field() => 5
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "rno123",
          1,
          System.system_time(:second)
        )

      assert result["type"] == "RNodeInterface"
      assert result["frequency"] == 868_000_000
      assert result["bandwidth"] == 125_000
      assert result["sf"] == 7
      assert result["cr"] == 5
      assert result["config_entry"] =~ "type = RNodeInterface"
      assert result["config_entry"] =~ "frequency = 868000000"
    end

    test "parses WeaveInterface info" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "WeaveInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "TestWeave",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.frequency_field() => 915_000_000,
        Discovery.bandwidth_field() => 250_000,
        Discovery.channel_field() => 1,
        Discovery.modulation_field() => "LoRa"
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "wv123",
          1,
          System.system_time(:second)
        )

      assert result["type"] == "WeaveInterface"
      assert result["frequency"] == 915_000_000
      assert result["channel"] == 1
      assert result["config_entry"] =~ "type = WeaveInterface"
    end

    test "parses KISSInterface info" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "KISSInterface",
        Discovery.transport_field() => false,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "TestKISS",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.frequency_field() => 433_000_000,
        Discovery.bandwidth_field() => 62_500,
        Discovery.modulation_field() => "FSK"
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "kiss123",
          1,
          System.system_time(:second)
        )

      assert result["type"] == "KISSInterface"
      assert result["frequency"] == 433_000_000
      assert result["config_entry"] =~ "type = KISSInterface"
      assert result["config_entry"] =~ "Frequency: 433000000"
    end

    test "includes IFAC netname and netkey when present" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "BackboneInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "TestWithIFAC",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "10.0.0.1",
        Discovery.port_field() => 4242,
        Discovery.ifac_netname_field() => "mynetwork",
        Discovery.ifac_netkey_field() => "secretkey"
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "ifac123",
          1,
          System.system_time(:second)
        )

      assert result["ifac_netname"] == "mynetwork"
      assert result["ifac_netkey"] == "secretkey"
      assert result["config_entry"] =~ "network_name = mynetwork"
      assert result["config_entry"] =~ "passphrase = secretkey"
    end

    test "returns nil when interface type is not present" do
      unpacked = %{
        Discovery.transport_field() => true,
        Discovery.name_field() => "NoType"
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "abc",
          1,
          System.system_time(:second)
        )

      assert result == nil
    end

    test "generates discovery_hash from transport_id and name" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "BackboneInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "HashTest",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "1.2.3.4",
        Discovery.port_field() => 1234
      }

      result =
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "hash123",
          1,
          System.system_time(:second)
        )

      transport_id_hex = RNS.hexrep(transport_id, false)
      expected_hash = RNS.Identity.full_hash(transport_id_hex <> "HashTest")
      assert result["discovery_hash"] == expected_hash
    end

    test "rejects reachable_on with invalid address" do
      transport_id = :crypto.strong_rand_bytes(16)

      unpacked = %{
        Discovery.interface_type_field() => "BackboneInterface",
        Discovery.transport_field() => true,
        Discovery.transport_id_field() => transport_id,
        Discovery.name_field() => "BadAddr",
        Discovery.latitude_field() => nil,
        Discovery.longitude_field() => nil,
        Discovery.height_field() => nil,
        Discovery.reachable_on_field() => "not-valid!@#",
        Discovery.port_field() => 1234
      }

      assert_raise RuntimeError, fn ->
        InterfaceAnnounceHandler.parse_interface_info(
          unpacked,
          "bad123",
          1,
          System.system_time(:second)
        )
      end
    end
  end
end

defmodule RNS.Discovery.InterfaceAnnouncerTest do
  use ExUnit.Case, async: true

  alias RNS.Discovery
  alias RNS.Discovery.InterfaceAnnouncer

  describe "constants" do
    test "JOB_INTERVAL" do
      assert InterfaceAnnouncer.job_interval() == 60
    end

    test "DEFAULT_STAMP_VALUE" do
      assert InterfaceAnnouncer.default_stamp_value() == 14
    end

    test "WORKBLOCK_EXPAND_ROUNDS" do
      assert InterfaceAnnouncer.workblock_expand_rounds() == 20
    end

    test "DISCOVERABLE_INTERFACE_TYPES" do
      types = InterfaceAnnouncer.discoverable_interface_types()
      assert "BackboneInterface" in types
      assert "TCPServerInterface" in types
      assert "TCPClientInterface" in types
      assert "RNodeInterface" in types
      assert "WeaveInterface" in types
      assert "I2PInterface" in types
      assert "KISSInterface" in types
      assert length(types) == 7
    end
  end

  describe "get_interface_announce_data/2" do
    test "returns nil for non-discoverable interface type" do
      interface = %{
        __struct__: :test_struct,
        type_name: "UDPInterface",
        name: "TestUDP",
        discovery_stamp_value: nil,
        discovery_name: "TestUDP",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_encrypt: false,
        discovery_publish_ifac: false
      }

      result =
        InterfaceAnnouncer.get_interface_announce_data(interface, %{
          transport_enabled: false,
          transport_identity_hash: :crypto.strong_rand_bytes(16),
          stamper: nil,
          stamp_cache: %{}
        })

      assert result == nil
    end

    test "returns {:error, :no_stamper} for discoverable type without stamper" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        __struct__: :test_struct,
        type_name: "BackboneInterface",
        name: "TestBackbone",
        discovery_stamp_value: nil,
        discovery_name: "TestBackbone",
        discovery_latitude: 37.7749,
        discovery_longitude: -122.4194,
        discovery_height: 100,
        discovery_encrypt: false,
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
      # Without a stamper, fail closed with {:error, :no_stamper}
      assert result == {:error, :no_stamper}
    end

    test "builds info map for RNodeInterface with radio params" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        __struct__: :test_struct,
        type_name: "RNodeInterface",
        name: "TestRNode",
        discovery_stamp_value: nil,
        discovery_name: "TestRNode",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_encrypt: false,
        discovery_publish_ifac: false,
        frequency: 868_000_000,
        bandwidth: 125_000,
        sf: 7,
        cr: 5
      }

      info =
        InterfaceAnnouncer.build_interface_info(interface, %{
          transport_enabled: true,
          transport_identity_hash: transport_id
        })

      assert info[Discovery.interface_type_field()] == "RNodeInterface"
      assert info[Discovery.frequency_field()] == 868_000_000
      assert info[Discovery.bandwidth_field()] == 125_000
      assert info[Discovery.spreading_factor_field()] == 7
      assert info[Discovery.coding_rate_field()] == 5
    end

    test "builds info map for WeaveInterface with discovery params" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        __struct__: :test_struct,
        type_name: "WeaveInterface",
        name: "TestWeave",
        discovery_stamp_value: nil,
        discovery_name: "TestWeave",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_encrypt: false,
        discovery_publish_ifac: false,
        discovery_frequency: 915_000_000,
        discovery_bandwidth: 250_000,
        discovery_channel: 1,
        discovery_modulation: "LoRa"
      }

      info =
        InterfaceAnnouncer.build_interface_info(interface, %{
          transport_enabled: true,
          transport_identity_hash: transport_id
        })

      assert info[Discovery.interface_type_field()] == "WeaveInterface"
      assert info[Discovery.frequency_field()] == 915_000_000
      assert info[Discovery.channel_field()] == 1
      assert info[Discovery.modulation_field()] == "LoRa"
    end

    test "builds info for KISSInterface" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        __struct__: :test_struct,
        type_name: "KISSInterface",
        name: "TestKISS",
        discovery_stamp_value: nil,
        discovery_name: "TestKISS",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_encrypt: false,
        discovery_publish_ifac: false,
        discovery_frequency: 433_000_000,
        discovery_bandwidth: 62_500,
        discovery_modulation: "FSK"
      }

      info =
        InterfaceAnnouncer.build_interface_info(interface, %{
          transport_enabled: false,
          transport_identity_hash: transport_id
        })

      # KISS interfaces are normalized to "KISSInterface" type
      assert info[Discovery.interface_type_field()] == "KISSInterface"
      assert info[Discovery.frequency_field()] == 433_000_000
    end

    test "builds info for TCPClientInterface with kiss_framing as KISSInterface" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        __struct__: :test_struct,
        type_name: "TCPClientInterface",
        name: "TestTCPKISS",
        discovery_stamp_value: nil,
        discovery_name: "TestTCPKISS",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_encrypt: false,
        discovery_publish_ifac: false,
        kiss_framing: true,
        discovery_frequency: 433_000_000,
        discovery_bandwidth: 62_500,
        discovery_modulation: "FSK"
      }

      info =
        InterfaceAnnouncer.build_interface_info(interface, %{
          transport_enabled: false,
          transport_identity_hash: transport_id
        })

      # TCPClientInterface with kiss_framing should report as KISSInterface
      assert info[Discovery.interface_type_field()] == "KISSInterface"
    end

    test "includes IFAC info when publish_ifac is true" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        __struct__: :test_struct,
        type_name: "BackboneInterface",
        name: "TestIFAC",
        discovery_stamp_value: nil,
        discovery_name: "TestIFAC",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_encrypt: false,
        discovery_publish_ifac: true,
        ifac_netname: "mynet",
        ifac_netkey: "mykey",
        reachable_on: "10.0.0.1",
        bind_port: 4242
      }

      info =
        InterfaceAnnouncer.build_interface_info(interface, %{
          transport_enabled: true,
          transport_identity_hash: transport_id
        })

      assert info[Discovery.ifac_netname_field()] == "mynet"
      assert info[Discovery.ifac_netkey_field()] == "mykey"
    end

    test "validates reachable_on for BackboneInterface" do
      transport_id = :crypto.strong_rand_bytes(16)

      interface = %{
        __struct__: :test_struct,
        type_name: "BackboneInterface",
        name: "BadAddr",
        discovery_stamp_value: nil,
        discovery_name: "BadAddr",
        discovery_latitude: nil,
        discovery_longitude: nil,
        discovery_height: nil,
        discovery_encrypt: false,
        discovery_publish_ifac: false,
        reachable_on: "not!valid",
        bind_port: 4242
      }

      info =
        InterfaceAnnouncer.build_interface_info(interface, %{
          transport_enabled: true,
          transport_identity_hash: transport_id
        })

      # Should return nil for invalid reachable_on
      assert info == nil
    end
  end
end

defmodule RNS.Discovery.InterfaceDiscoveryTest do
  use ExUnit.Case, async: false

  alias RNS.Discovery.InterfaceDiscovery

  describe "constants" do
    test "time thresholds" do
      assert InterfaceDiscovery.threshold_unknown() == 24 * 60 * 60
      assert InterfaceDiscovery.threshold_stale() == 3 * 24 * 60 * 60
      assert InterfaceDiscovery.threshold_remove() == 7 * 24 * 60 * 60
    end

    test "monitor constants" do
      assert InterfaceDiscovery.monitor_interval() == 5
      assert InterfaceDiscovery.detach_threshold() == 12
    end

    test "status constants" do
      assert InterfaceDiscovery.status_stale() == 0
      assert InterfaceDiscovery.status_unknown() == 100
      assert InterfaceDiscovery.status_available() == 1000
    end

    test "status code map" do
      map = InterfaceDiscovery.status_code_map()
      assert map["available"] == 1000
      assert map["unknown"] == 100
      assert map["stale"] == 0
    end

    test "autoconnect types" do
      types = InterfaceDiscovery.autoconnect_types()
      assert "BackboneInterface" in types
      assert "TCPServerInterface" in types
    end
  end

  describe "interface_discovered/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "rns_discovery_test_#{:rand.uniform(999_999)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{storage_path: dir}
    end

    test "stores new interface discovery", %{storage_path: dir} do
      info = %{
        "name" => "TestInterface",
        "type" => "BackboneInterface",
        "value" => 14,
        "hops" => 1,
        "received" => System.system_time(:second),
        "discovery_hash" => :crypto.hash(:sha256, "test_hash"),
        "transport_id" => "abcd1234",
        "network_id" => "def56789"
      }

      result = InterfaceDiscovery.interface_discovered(info, dir)
      assert result == :ok

      # Verify file was written
      filename = RNS.hexrep(info["discovery_hash"], false)
      filepath = Path.join(dir, filename)
      assert File.regular?(filepath)

      # Read back and verify
      stored = filepath |> File.read!() |> Msgpax.unpack!()
      assert stored["name"] == "TestInterface"
      assert stored["discovered"] == info["received"]
      assert stored["last_heard"] == info["received"]
      assert stored["heard_count"] == 0
    end

    test "updates existing interface discovery", %{storage_path: dir} do
      now = System.system_time(:second)
      discovery_hash = :crypto.hash(:sha256, "update_test")

      info1 = %{
        "name" => "TestInterface",
        "type" => "BackboneInterface",
        "value" => 14,
        "hops" => 1,
        "received" => now - 100,
        "discovery_hash" => discovery_hash,
        "transport_id" => "abcd1234",
        "network_id" => "def56789"
      }

      InterfaceDiscovery.interface_discovered(info1, dir)

      info2 = %{
        "name" => "TestInterface",
        "type" => "BackboneInterface",
        "value" => 14,
        "hops" => 1,
        "received" => now,
        "discovery_hash" => discovery_hash,
        "transport_id" => "abcd1234",
        "network_id" => "def56789"
      }

      InterfaceDiscovery.interface_discovered(info2, dir)

      # Read back and verify heard_count incremented
      filename = RNS.hexrep(discovery_hash, false)
      filepath = Path.join(dir, filename)
      stored = filepath |> File.read!() |> Msgpax.unpack!()
      assert stored["heard_count"] == 1
      assert stored["discovered"] == now - 100
      assert stored["last_heard"] == now
    end
  end

  describe "list_discovered_interfaces/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "rns_discovery_list_#{:rand.uniform(999_999)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{storage_path: dir}
    end

    test "returns empty list for empty directory", %{storage_path: dir} do
      result = InterfaceDiscovery.list_discovered_interfaces(dir)
      assert result == []
    end

    test "returns discovered interfaces sorted by status", %{storage_path: dir} do
      now = System.system_time(:second)

      # Create an "available" interface (heard recently)
      store_interface(dir, "avail", %{
        "name" => "Available",
        "type" => "BackboneInterface",
        "value" => 14,
        "transport" => true,
        "last_heard" => now - 100,
        "discovered" => now - 1000,
        "heard_count" => 5,
        "transport_id" => "aaa",
        "network_id" => "bbb",
        "reachable_on" => "10.0.0.1"
      })

      # Create an "unknown" interface (heard > 24h ago but < 3 days)
      store_interface(dir, "unknown", %{
        "name" => "Unknown",
        "type" => "TCPServerInterface",
        "value" => 10,
        "transport" => true,
        "last_heard" => now - 2 * 24 * 60 * 60,
        "discovered" => now - 5 * 24 * 60 * 60,
        "heard_count" => 2,
        "transport_id" => "ccc",
        "network_id" => "ddd",
        "reachable_on" => "10.0.0.2"
      })

      result = InterfaceDiscovery.list_discovered_interfaces(dir)
      assert length(result) == 2
      # Available should come first (higher status_code)
      [first, second] = result
      assert first["status"] == "available"
      assert second["status"] == "unknown"
    end

    test "removes interfaces older than threshold_remove", %{storage_path: dir} do
      now = System.system_time(:second)

      store_interface(dir, "old", %{
        "name" => "OldInterface",
        "type" => "BackboneInterface",
        "value" => 14,
        "transport" => true,
        "last_heard" => now - 8 * 24 * 60 * 60,
        "discovered" => now - 10 * 24 * 60 * 60,
        "heard_count" => 1,
        "transport_id" => "eee",
        "network_id" => "fff",
        "reachable_on" => "10.0.0.3"
      })

      result = InterfaceDiscovery.list_discovered_interfaces(dir)
      assert result == []

      # File should have been deleted
      files = File.ls!(dir)
      assert files == []
    end

    test "filters by only_available", %{storage_path: dir} do
      now = System.system_time(:second)

      store_interface(dir, "avail2", %{
        "name" => "Available2",
        "type" => "BackboneInterface",
        "value" => 14,
        "transport" => true,
        "last_heard" => now - 100,
        "discovered" => now - 1000,
        "heard_count" => 5,
        "transport_id" => "ggg",
        "network_id" => "hhh",
        "reachable_on" => "10.0.0.4"
      })

      store_interface(dir, "unknown2", %{
        "name" => "Unknown2",
        "type" => "TCPServerInterface",
        "value" => 10,
        "transport" => true,
        "last_heard" => now - 2 * 24 * 60 * 60,
        "discovered" => now - 5 * 24 * 60 * 60,
        "heard_count" => 2,
        "transport_id" => "iii",
        "network_id" => "jjj",
        "reachable_on" => "10.0.0.5"
      })

      result = InterfaceDiscovery.list_discovered_interfaces(dir, only_available: true)
      assert length(result) == 1
      assert hd(result)["name"] == "Available2"
    end

    test "filters by only_transport", %{storage_path: dir} do
      now = System.system_time(:second)

      store_interface(dir, "transport", %{
        "name" => "WithTransport",
        "type" => "BackboneInterface",
        "value" => 14,
        "transport" => true,
        "last_heard" => now - 100,
        "discovered" => now - 1000,
        "heard_count" => 5,
        "transport_id" => "kkk",
        "network_id" => "lll",
        "reachable_on" => "10.0.0.6"
      })

      store_interface(dir, "notransport", %{
        "name" => "NoTransport",
        "type" => "BackboneInterface",
        "value" => 14,
        "transport" => false,
        "last_heard" => now - 100,
        "discovered" => now - 1000,
        "heard_count" => 5,
        "transport_id" => "mmm",
        "network_id" => "nnn",
        "reachable_on" => "10.0.0.7"
      })

      result = InterfaceDiscovery.list_discovered_interfaces(dir, only_transport: true)
      assert length(result) == 1
      assert hd(result)["name"] == "WithTransport"
    end

    test "removes entries with invalid reachable_on", %{storage_path: dir} do
      now = System.system_time(:second)

      store_interface(dir, "badaddr", %{
        "name" => "BadAddr",
        "type" => "BackboneInterface",
        "value" => 14,
        "transport" => true,
        "last_heard" => now - 100,
        "discovered" => now - 1000,
        "heard_count" => 5,
        "transport_id" => "ooo",
        "network_id" => "ppp",
        "reachable_on" => "not!valid@address"
      })

      result = InterfaceDiscovery.list_discovered_interfaces(dir)
      assert result == []
    end
  end

  describe "endpoint_hash/1" do
    test "computes hash from reachable_on and port" do
      info = %{"reachable_on" => "192.168.1.1", "port" => 4242}
      hash = InterfaceDiscovery.endpoint_hash(info)
      expected = RNS.Identity.full_hash("192.168.1.1:4242")
      assert hash == expected
    end

    test "computes hash from reachable_on only" do
      info = %{"reachable_on" => "abc.b32.i2p"}
      hash = InterfaceDiscovery.endpoint_hash(info)
      expected = RNS.Identity.full_hash("abc.b32.i2p")
      assert hash == expected
    end

    test "computes hash for empty info" do
      info = %{}
      hash = InterfaceDiscovery.endpoint_hash(info)
      expected = RNS.Identity.full_hash("")
      assert hash == expected
    end
  end

  # Helper to write an interface info to storage
  defp store_interface(dir, id, info) do
    hash = :crypto.hash(:sha256, id)
    filename = RNS.hexrep(hash, false)
    filepath = Path.join(dir, filename)
    File.write!(filepath, Msgpax.pack!(info, iodata: false))
  end
end

defmodule RNS.Discovery.BlackholeUpdaterTest do
  use ExUnit.Case, async: true

  alias RNS.Discovery.BlackholeUpdater

  describe "constants" do
    test "timing constants" do
      assert BlackholeUpdater.initial_wait() == 20
      assert BlackholeUpdater.job_interval() == 60
      assert BlackholeUpdater.update_interval() == 3600
      assert BlackholeUpdater.source_timeout() == 25
    end
  end

  describe "struct" do
    test "creates with default values" do
      updater = BlackholeUpdater.new()
      assert updater.last_updates == %{}
      assert updater.should_run == false
      assert updater.job_interval == 60
    end
  end
end
