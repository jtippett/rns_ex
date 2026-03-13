defmodule RNS.Reticulum.ConfigTest do
  @moduledoc """
  Tests for RNS.Reticulum.Config — pure config parsing and application.

  These tests verify that config logic works WITHOUT starting any GenServers
  or the supervision tree. This is the key benefit of extracting pure logic.
  """
  use ExUnit.Case, async: true

  alias RNS.Reticulum.Config
  alias RNS.Interfaces.Interface
  alias RNS.Vendor.ConfigObj
  alias RNS.Vendor.ConfigObj.Section

  # ── Path Computation ───────────────────────────────────────────────────

  describe "compute_paths/1" do
    test "computes all expected paths from configdir" do
      paths = Config.compute_paths("/tmp/test_rns")

      assert paths.configdir == "/tmp/test_rns"
      assert paths.configpath == "/tmp/test_rns/config"
      assert paths.storagepath == "/tmp/test_rns/storage"
      assert paths.cachepath == "/tmp/test_rns/storage/cache"
      assert paths.resourcepath == "/tmp/test_rns/storage/resources"
      assert paths.identitypath == "/tmp/test_rns/storage/identities"
      assert paths.blackholepath == "/tmp/test_rns/storage/blackhole"
      assert paths.interfacepath == "/tmp/test_rns/interfaces"
    end
  end

  describe "determine_configdir/1" do
    test "returns custom path unchanged" do
      assert Config.determine_configdir("/custom/path") == "/custom/path"
    end

    test "returns a string for nil input" do
      result = Config.determine_configdir(nil)
      assert is_binary(result)
    end
  end

  # ── Config Key Mapping ─────────────────────────────────────────────────

  describe "config_key_to_atom/1" do
    test "maps known keys" do
      assert Config.config_key_to_atom("type") == :type
      assert Config.config_key_to_atom("port") == :port
      assert Config.config_key_to_atom("target_host") == :target_host
      assert Config.config_key_to_atom("listen_port") == :listen_port
      assert Config.config_key_to_atom("device") == :device
      assert Config.config_key_to_atom("speed") == :speed
    end

    test "maps aliases" do
      assert Config.config_key_to_atom("remote") == :target_host
      assert Config.config_key_to_atom("listen_on") == :listen_ip
    end

    test "returns nil for unknown keys" do
      assert Config.config_key_to_atom("unknown_key") == nil
      assert Config.config_key_to_atom("foo_bar") == nil
    end
  end

  # ── Config Value Coercion ──────────────────────────────────────────────

  describe "coerce_config_value/2" do
    test "coerces integer fields from strings" do
      assert Config.coerce_config_value(:port, "8080") == 8080
      assert Config.coerce_config_value(:speed, "115200") == 115_200
      assert Config.coerce_config_value(:listen_port, "37428") == 37_428
    end

    test "returns original for non-parseable integers" do
      assert Config.coerce_config_value(:port, "not_a_number") == "not_a_number"
    end

    test "coerces boolean fields from strings" do
      assert Config.coerce_config_value(:kiss_framing, "Yes") == true
      assert Config.coerce_config_value(:kiss_framing, "true") == true
      assert Config.coerce_config_value(:kiss_framing, "on") == true
      assert Config.coerce_config_value(:kiss_framing, "1") == true
      assert Config.coerce_config_value(:kiss_framing, "no") == false
      assert Config.coerce_config_value(:kiss_framing, "false") == false
    end

    test "passes through non-binary values" do
      assert Config.coerce_config_value(:port, 8080) == 8080
      assert Config.coerce_config_value(:kiss_framing, true) == true
    end

    test "passes through unknown string keys" do
      assert Config.coerce_config_value(:target_host, "192.168.1.1") == "192.168.1.1"
    end
  end

  # ── Interface Mode Parsing ─────────────────────────────────────────────

  describe "parse_interface_mode/1" do
    test "parses full mode" do
      section = build_section(%{"interface_mode" => "full"})
      assert Config.parse_interface_mode(section) == Interface.mode_full()
    end

    test "parses access point mode aliases" do
      for mode <- ["access_point", "accesspoint", "ap"] do
        section = build_section(%{"interface_mode" => mode})
        assert Config.parse_interface_mode(section) == Interface.mode_access_point()
      end
    end

    test "parses point-to-point mode aliases" do
      for mode <- ["pointtopoint", "ptp"] do
        section = build_section(%{"interface_mode" => mode})
        assert Config.parse_interface_mode(section) == Interface.mode_point_to_point()
      end
    end

    test "parses roaming mode" do
      section = build_section(%{"interface_mode" => "roaming"})
      assert Config.parse_interface_mode(section) == Interface.mode_roaming()
    end

    test "parses boundary mode" do
      section = build_section(%{"interface_mode" => "boundary"})
      assert Config.parse_interface_mode(section) == Interface.mode_boundary()
    end

    test "parses gateway mode aliases" do
      for mode <- ["gateway", "gw"] do
        section = build_section(%{"interface_mode" => mode})
        assert Config.parse_interface_mode(section) == Interface.mode_gateway()
      end
    end

    test "defaults to full for unknown mode" do
      section = build_section(%{"interface_mode" => "unknown"})
      assert Config.parse_interface_mode(section) == Interface.mode_full()
    end

    test "falls back to 'mode' key" do
      section = build_section(%{"mode" => "roaming"})
      assert Config.parse_interface_mode(section) == Interface.mode_roaming()
    end

    test "defaults to full when no mode key present" do
      section = build_section(%{})
      assert Config.parse_interface_mode(section) == Interface.mode_full()
    end
  end

  describe "has_interface_mode_config?/1" do
    test "true when interface_mode present" do
      section = build_section(%{"interface_mode" => "full"})
      assert Config.has_interface_mode_config?(section) == true
    end

    test "true when mode present" do
      section = build_section(%{"mode" => "roaming"})
      assert Config.has_interface_mode_config?(section) == true
    end

    test "false when neither present" do
      section = build_section(%{})
      assert Config.has_interface_mode_config?(section) == false
    end
  end

  # ── Interface Parameter Extraction ─────────────────────────────────────

  describe "extract_interface_params/3" do
    test "extracts default parameters from empty config" do
      section = build_section(%{})
      params = Config.extract_interface_params(section, Interface.mode_full(), "test")

      assert params.interface_mode == Interface.mode_full()
      assert params.ifac_size == nil
      assert params.ifac_netname == nil
      assert params.ifac_netkey == nil
      assert params.ingress_control == true
      assert params.configured_bitrate == nil
      assert params.announce_rate_target == nil
      assert params.bootstrap_only == false
      assert params.outgoing == true
      assert params.discoverable == false
    end

    test "overrides mode from config" do
      section = build_section(%{"interface_mode" => "roaming"})
      params = Config.extract_interface_params(section, Interface.mode_full(), "test")

      assert params.interface_mode == Interface.mode_roaming()
    end

    test "extracts IFAC parameters" do
      section =
        build_section(%{
          "ifac_size" => "16",
          "networkname" => "mynet",
          "passphrase" => "secret"
        })

      params = Config.extract_interface_params(section, 0x00, "test")

      assert params.ifac_size == 2
      assert params.ifac_netname == "mynet"
      assert params.ifac_netkey == "secret"
    end

    test "extracts announce rate limiting" do
      section =
        build_section(%{
          "announce_rate_target" => "10",
          "announce_rate_grace" => "5",
          "announce_rate_penalty" => "3"
        })

      params = Config.extract_interface_params(section, 0x00, "test")

      assert params.announce_rate_target == 10
      assert params.announce_rate_grace == 5
      assert params.announce_rate_penalty == 3
    end

    test "defaults grace and penalty when target is set but they are not" do
      section = build_section(%{"announce_rate_target" => "10"})
      params = Config.extract_interface_params(section, 0x00, "test")

      assert params.announce_rate_target == 10
      assert params.announce_rate_grace == 0
      assert params.announce_rate_penalty == 0
    end

    test "extracts ingress control parameters" do
      section =
        build_section(%{
          "ingress_control" => "true",
          "ic_max_held_announces" => "100",
          "ic_burst_hold" => "1.5"
        })

      params = Config.extract_interface_params(section, 0x00, "test")

      assert params.ingress_control == true
      assert params.ic_max_held_announces == 100
      assert params.ic_burst_hold == 1.5
    end
  end

  # ── Config Section to Opts ─────────────────────────────────────────────

  describe "config_section_to_opts/3" do
    test "builds keyword list from config section" do
      section = build_section(%{"type" => "AutoInterface", "port" => "5555"})
      params = %{configured_bitrate: nil}
      opts = Config.config_section_to_opts(section, "My Interface", params)

      assert Keyword.get(opts, :name) == "My Interface"
      assert Keyword.get(opts, :type) == "AutoInterface"
      assert Keyword.get(opts, :port) == 5555
    end

    test "includes configured_bitrate when set" do
      section = build_section(%{"type" => "UDPInterface"})
      params = %{configured_bitrate: 1000}
      opts = Config.config_section_to_opts(section, "test", params)

      assert Keyword.get(opts, :configured_bitrate) == 1000
    end

    test "skips unknown keys" do
      section = build_section(%{"type" => "AutoInterface", "custom_field" => "value"})
      params = %{configured_bitrate: nil}
      opts = Config.config_section_to_opts(section, "test", params)

      assert Keyword.get(opts, :type) == "AutoInterface"
      refute Keyword.has_key?(opts, :custom_field)
    end
  end

  # ── Apply Config ───────────────────────────────────────────────────────

  describe "apply_config/2" do
    test "returns default state from empty config" do
      {:ok, config} = ConfigObj.parse("[reticulum]\n[logging]\nloglevel = 4\n")
      state = Config.apply_config(config)

      assert state.transport_enabled == false
      assert state.share_instance == true
      assert state.local_interface_port == 37_428
      assert state.local_control_port == 37_429
      assert state.loglevel == 4
      assert state.network_identity == nil
    end

    test "applies transport_enabled" do
      {:ok, config} =
        ConfigObj.parse("[reticulum]\nenable_transport = Yes\n[logging]\nloglevel = 4\n")

      state = Config.apply_config(config)

      assert state.transport_enabled == true
    end

    test "applies loglevel from config" do
      {:ok, config} = ConfigObj.parse("[reticulum]\n[logging]\nloglevel = 6\n")
      state = Config.apply_config(config)

      assert state.loglevel == 6
    end

    test "respects verbosity offset" do
      {:ok, config} = ConfigObj.parse("[reticulum]\n[logging]\nloglevel = 4\n")
      state = Config.apply_config(config, verbosity: 2)

      assert state.loglevel == 6
    end

    test "clamps loglevel to 0..7" do
      {:ok, config} = ConfigObj.parse("[reticulum]\n[logging]\nloglevel = 4\n")
      state = Config.apply_config(config, verbosity: 10)

      assert state.loglevel == 7
    end

    test "applies shared_instance_port" do
      {:ok, config} =
        ConfigObj.parse("[reticulum]\nshared_instance_port = 12345\n[logging]\nloglevel = 4\n")

      state = Config.apply_config(config)

      assert state.local_interface_port == 12_345
    end
  end

  # ── Logging Config ─────────────────────────────────────────────────────

  describe "apply_logging_config/4" do
    test "applies loglevel from config section" do
      {:ok, config} = ConfigObj.parse("[logging]\nloglevel = 5\n")
      state = Config.apply_logging_config(config, %{loglevel: 4}, nil, nil)

      assert state.loglevel == 5
    end

    test "skips when requested_loglevel overrides" do
      {:ok, config} = ConfigObj.parse("[logging]\nloglevel = 5\n")
      state = Config.apply_logging_config(config, %{loglevel: 4}, 3, nil)

      # Requested loglevel means don't apply from config
      assert state.loglevel == 4
    end

    test "adds verbosity to config loglevel" do
      {:ok, config} = ConfigObj.parse("[logging]\nloglevel = 4\n")
      state = Config.apply_logging_config(config, %{loglevel: 4}, nil, 2)

      assert state.loglevel == 6
    end

    test "returns state unchanged when no logging section" do
      {:ok, config} = ConfigObj.parse("[reticulum]\n")
      state = Config.apply_logging_config(config, %{loglevel: 4}, nil, nil)

      assert state.loglevel == 4
    end
  end

  # ── Build Post-Init Updates ────────────────────────────────────────────

  describe "build_post_init_updates/2" do
    test "builds default updates from minimal params" do
      params = %{
        outgoing: true,
        interface_mode: Interface.mode_full(),
        announce_cap: 0.02,
        bootstrap_only: false,
        ingress_control: true,
        discoverable: false
      }

      updates = Config.build_post_init_updates(params, %{})

      assert updates.out == true
      assert updates.mode == Interface.mode_full()
      assert updates.announce_cap == 0.02
      assert updates.bootstrap_only == false
      assert updates.ingress_control == true
      assert updates.discoverable == false
    end

    test "includes bitrate when configured" do
      params = %{
        outgoing: true,
        interface_mode: 0x00,
        announce_cap: 0.02,
        bootstrap_only: false,
        configured_bitrate: 9600,
        ingress_control: true,
        discoverable: false
      }

      updates = Config.build_post_init_updates(params, %{})

      assert updates.bitrate == 9600
    end

    test "includes IFAC settings when present" do
      params = %{
        outgoing: true,
        interface_mode: 0x00,
        announce_cap: 0.02,
        bootstrap_only: false,
        ifac_size: 8,
        ifac_netname: "testnet",
        ifac_netkey: "testkey",
        ingress_control: true,
        discoverable: false
      }

      updates = Config.build_post_init_updates(params, %{})

      assert updates.ifac_size == 8
      assert updates.ifac_netname == "testnet"
      assert updates.ifac_netkey == "testkey"
      assert is_binary(updates.ifac_key)
      assert updates.ifac_identity != nil
      assert is_binary(updates.ifac_signature)
    end
  end

  # ── Config Extraction Helpers ──────────────────────────────────────────

  describe "maybe_put/3" do
    test "skips nil values" do
      assert Config.maybe_put(%{a: 1}, :b, nil) == %{a: 1}
    end

    test "adds non-nil values" do
      assert Config.maybe_put(%{a: 1}, :b, 2) == %{a: 1, b: 2}
    end
  end

  describe "get_optional_bool/3" do
    test "returns value when key exists" do
      section = build_section(%{"enabled" => "true"})
      assert Config.get_optional_bool(section, "enabled", false) == true
    end

    test "returns default when key missing" do
      section = build_section(%{})
      assert Config.get_optional_bool(section, "enabled", true) == true
    end
  end

  describe "get_optional_int/3" do
    test "returns validated value when key exists" do
      section = build_section(%{"port" => "8080"})
      assert Config.get_optional_int(section, "port", fn v -> v end) == 8080
    end

    test "returns nil when key missing" do
      section = build_section(%{})
      assert Config.get_optional_int(section, "port", fn v -> v end) == nil
    end
  end

  describe "get_nonempty_string/2" do
    test "returns value for non-empty string" do
      section = build_section(%{"name" => "test"})
      assert Config.get_nonempty_string(section, "name") == "test"
    end

    test "returns nil for empty string" do
      section = build_section(%{"name" => ""})
      assert Config.get_nonempty_string(section, "name") == nil
    end

    test "returns nil when key missing" do
      section = build_section(%{})
      assert Config.get_nonempty_string(section, "name") == nil
    end
  end

  # ── Helper ─────────────────────────────────────────────────────────────

  defp build_section(kv_map) do
    lines = Enum.map(kv_map, fn {k, v} -> "#{k} = #{v}" end)
    config_text = "[test]\n" <> Enum.join(lines, "\n") <> "\n"
    {:ok, config} = ConfigObj.parse(config_text)
    Section.get(config, "test")
  end
end
