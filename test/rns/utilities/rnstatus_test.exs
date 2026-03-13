defmodule RNS.Utilities.RNStatusTest do
  @moduledoc """
  Tests for the rnstatus utility.

  Tests argument parsing, output formatting, interface stat conversion,
  filtering, and sorting.
  """

  use ExUnit.Case, async: true

  alias RNS.Utilities.RNStatus
  alias RNS.Interfaces.Interface

  # ── Argument Parsing ──────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNStatus.parse_args([])

      assert opts.configdir == nil
      assert opts.all == false
      assert opts.announce_stats == false
      assert opts.link_stats == false
      assert opts.totals == false
      assert opts.sort == nil
      assert opts.reverse == false
      assert opts.json == false
      assert opts.verbosity == 0
      assert opts.version == false
      assert opts.help == false
      assert opts.name_filter == nil
    end

    test "parses --config option" do
      assert {:ok, opts} = RNStatus.parse_args(["--config", "/tmp/test_reticulum"])
      assert opts.configdir == "/tmp/test_reticulum"
    end

    test "parses -a / --all flag" do
      assert {:ok, opts} = RNStatus.parse_args(["-a"])
      assert opts.all == true

      assert {:ok, opts} = RNStatus.parse_args(["--all"])
      assert opts.all == true
    end

    test "parses -A / --announce-stats flag" do
      assert {:ok, opts} = RNStatus.parse_args(["-A"])
      assert opts.announce_stats == true

      assert {:ok, opts} = RNStatus.parse_args(["--announce-stats"])
      assert opts.announce_stats == true
    end

    test "parses -l / --link-stats flag" do
      assert {:ok, opts} = RNStatus.parse_args(["-l"])
      assert opts.link_stats == true
    end

    test "parses -t / --totals flag" do
      assert {:ok, opts} = RNStatus.parse_args(["-t"])
      assert opts.totals == true
    end

    test "parses -s / --sort option" do
      assert {:ok, opts} = RNStatus.parse_args(["-s", "rate"])
      assert opts.sort == "rate"

      assert {:ok, opts} = RNStatus.parse_args(["--sort", "traffic"])
      assert opts.sort == "traffic"
    end

    test "parses -r / --reverse flag" do
      assert {:ok, opts} = RNStatus.parse_args(["-r"])
      assert opts.reverse == true
    end

    test "parses -j / --json flag" do
      assert {:ok, opts} = RNStatus.parse_args(["-j"])
      assert opts.json == true
    end

    test "parses -v / --verbose flag (repeatable)" do
      assert {:ok, opts} = RNStatus.parse_args(["-v"])
      assert opts.verbosity == 1

      assert {:ok, opts} = RNStatus.parse_args(["-v", "-v", "-v"])
      assert opts.verbosity == 3
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNStatus.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses name filter as positional arg" do
      assert {:ok, opts} = RNStatus.parse_args(["UDP"])
      assert opts.name_filter == "UDP"
    end

    test "parses combined options with filter" do
      args = ["--config", "/tmp/rns", "-a", "-A", "-l", "-s", "rx", "-v", "MyInterface"]
      assert {:ok, opts} = RNStatus.parse_args(args)
      assert opts.configdir == "/tmp/rns"
      assert opts.all == true
      assert opts.announce_stats == true
      assert opts.link_stats == true
      assert opts.sort == "rx"
      assert opts.verbosity == 1
      assert opts.name_filter == "MyInterface"
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNStatus.parse_args(["--unknown"])
      assert msg =~ "unknown option"
    end
  end

  # ── Version Output ────────────────────────────────────────────────

  describe "version output" do
    test "main with --version prints version" do
      output = capture_io(fn -> RNStatus.main(["--version"]) end)
      assert output =~ "rnstatus #{RNS.Version.version()}"
    end
  end

  # ── Help Output ────────────────────────────────────────────────────

  describe "help output" do
    test "main with --help prints usage" do
      output = capture_io(fn -> RNStatus.main(["--help"]) end)
      assert output =~ "Reticulum Network Stack Status"
      assert output =~ "--config"
      assert output =~ "--all"
      assert output =~ "--json"
    end
  end

  # ── Speed String ───────────────────────────────────────────────────

  describe "speed_str/1" do
    test "formats bits per second" do
      assert RNStatus.speed_str(0) =~ "0.00 bps"
    end

    test "formats kilobits per second" do
      result = RNStatus.speed_str(1000)
      assert result =~ "1.00 kbps"
    end

    test "formats megabits per second" do
      result = RNStatus.speed_str(1_000_000)
      assert result =~ "1.00 Mbps"
    end

    test "formats gigabits per second" do
      result = RNStatus.speed_str(1_000_000_000)
      assert result =~ "1.00 Gbps"
    end

    test "formats fractional values" do
      result = RNStatus.speed_str(62_500)
      assert result =~ "62.50 kbps"
    end
  end

  # ── Mode String ────────────────────────────────────────────────────

  describe "mode_string/1" do
    test "returns Full for default mode" do
      assert RNStatus.mode_string(Interface.mode_full()) == "Full"
    end

    test "returns Access Point" do
      assert RNStatus.mode_string(Interface.mode_access_point()) == "Access Point"
    end

    test "returns Point-to-Point" do
      assert RNStatus.mode_string(Interface.mode_point_to_point()) == "Point-to-Point"
    end

    test "returns Roaming" do
      assert RNStatus.mode_string(Interface.mode_roaming()) == "Roaming"
    end

    test "returns Boundary" do
      assert RNStatus.mode_string(Interface.mode_boundary()) == "Boundary"
    end

    test "returns Gateway" do
      assert RNStatus.mode_string(Interface.mode_gateway()) == "Gateway"
    end

    test "returns Full for unknown mode" do
      assert RNStatus.mode_string(0xFF) == "Full"
    end
  end

  # ── Should Display ─────────────────────────────────────────────────

  describe "should_display?/3" do
    test "shows normal interfaces by default" do
      assert RNStatus.should_display?("UDPInterface[test]", false, nil)
      assert RNStatus.should_display?("TCPServerInterface[test]", false, nil)
      assert RNStatus.should_display?("RNodeInterface[test]", false, nil)
    end

    test "hides LocalInterface by default" do
      refute RNStatus.should_display?("LocalInterface[test]", false, nil)
    end

    test "hides TCPInterface Client by default" do
      refute RNStatus.should_display?("TCPInterface[Client test]", false, nil)
    end

    test "hides BackboneInterface Client by default" do
      refute RNStatus.should_display?("BackboneInterface[Client on test]", false, nil)
    end

    test "hides AutoInterfacePeer by default" do
      refute RNStatus.should_display?("AutoInterfacePeer[test]", false, nil)
    end

    test "hides WeaveInterfacePeer by default" do
      refute RNStatus.should_display?("WeaveInterfacePeer[test]", false, nil)
    end

    test "hides I2PInterfacePeer Connected peer by default" do
      refute RNStatus.should_display?("I2PInterfacePeer[Connected peer test]", false, nil)
    end

    test "shows all interfaces with display_all=true" do
      assert RNStatus.should_display?("LocalInterface[test]", true, nil)
      assert RNStatus.should_display?("TCPInterface[Client test]", true, nil)
      assert RNStatus.should_display?("AutoInterfacePeer[test]", true, nil)
    end

    test "applies name filter (case-insensitive)" do
      assert RNStatus.should_display?("UDPInterface[test]", false, "udp")
      assert RNStatus.should_display?("UDPInterface[test]", false, "UDP")
      refute RNStatus.should_display?("UDPInterface[test]", false, "tcp")
    end

    test "filter applies to normally-hidden interfaces when show all" do
      assert RNStatus.should_display?("LocalInterface[test]", true, "local")
      refute RNStatus.should_display?("LocalInterface[test]", true, "udp")
    end
  end

  # ── Sort Interfaces ────────────────────────────────────────────────

  describe "sort_interfaces/3" do
    setup do
      interfaces = [
        %{
          "name" => "A",
          "bitrate" => 100,
          "rxb" => 500,
          "txb" => 200,
          "rxs" => 10,
          "txs" => 5,
          "incoming_announce_frequency" => 2,
          "outgoing_announce_frequency" => 3,
          "held_announces" => 1
        },
        %{
          "name" => "B",
          "bitrate" => 200,
          "rxb" => 100,
          "txb" => 800,
          "rxs" => 20,
          "txs" => 15,
          "incoming_announce_frequency" => 5,
          "outgoing_announce_frequency" => 1,
          "held_announces" => 3
        },
        %{
          "name" => "C",
          "bitrate" => 50,
          "rxb" => 300,
          "txb" => 300,
          "rxs" => 5,
          "txs" => 25,
          "incoming_announce_frequency" => 1,
          "outgoing_announce_frequency" => 8,
          "held_announces" => 0
        }
      ]

      %{interfaces: interfaces}
    end

    test "returns unsorted when sort is nil", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, nil, false)
      assert Enum.map(result, & &1["name"]) == ["A", "B", "C"]
    end

    test "sorts by rate ascending", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "rate", false)
      assert Enum.map(result, & &1["name"]) == ["C", "A", "B"]
    end

    test "sorts by rate descending (reversed)", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "rate", true)
      assert Enum.map(result, & &1["name"]) == ["B", "A", "C"]
    end

    test "sorts by rx", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "rx", false)
      assert Enum.map(result, & &1["name"]) == ["B", "C", "A"]
    end

    test "sorts by tx", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "tx", false)
      assert Enum.map(result, & &1["name"]) == ["A", "C", "B"]
    end

    test "sorts by traffic (rx + tx)", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "traffic", false)
      assert Enum.map(result, & &1["name"]) == ["C", "A", "B"]
    end

    test "sorts by announces (incoming + outgoing)", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "announces", false)
      assert Enum.map(result, & &1["name"]) == ["A", "B", "C"]
    end

    test "sorts by arx (incoming announce frequency)", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "arx", false)
      assert Enum.map(result, & &1["name"]) == ["C", "A", "B"]
    end

    test "sorts by atx (outgoing announce frequency)", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "atx", false)
      assert Enum.map(result, & &1["name"]) == ["B", "A", "C"]
    end

    test "sorts by held announces", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "held", false)
      assert Enum.map(result, & &1["name"]) == ["C", "A", "B"]
    end

    test "ignores unknown sort field", %{interfaces: interfaces} do
      result = RNStatus.sort_interfaces(interfaces, "unknown_field", false)
      assert Enum.map(result, & &1["name"]) == ["A", "B", "C"]
    end
  end

  # ── Interface to Stat Map ──────────────────────────────────────────

  describe "interface_to_stat_map/1" do
    test "converts interface map with all fields" do
      iface = %{
        name: "TestInterface[test]",
        online: true,
        mode: Interface.mode_full(),
        rxb: 1024,
        txb: 2048,
        bitrate: 62_500,
        peers: 3,
        ifac_identity: nil,
        ifac_size: 0,
        ifac_netname: nil,
        announce_queue: [],
        held_announces: %{},
        ia_freq_deque: [],
        oa_freq_deque: [],
        created: System.system_time(:second) - 3600,
        in: true,
        out: true,
        clients: nil
      }

      stat = RNStatus.interface_to_stat_map(iface)

      assert stat["name"] == "TestInterface[test]"
      assert stat["status"] == true
      assert stat["mode"] == Interface.mode_full()
      assert stat["rxb"] == 1024
      assert stat["txb"] == 2048
      assert stat["bitrate"] == 62_500
      assert stat["peers"] == 3
      assert stat["announce_queue"] == 0
      assert stat["held_announces"] == 0
    end

    test "handles missing optional fields gracefully" do
      iface = %{name: "Minimal"}

      stat = RNStatus.interface_to_stat_map(iface)

      assert stat["name"] == "Minimal"
      assert stat["status"] == false
      assert stat["rxb"] == 0
      assert stat["txb"] == 0
    end

    test "counts announce queue length" do
      iface = %{
        name: "Test",
        announce_queue: [:a, :b, :c]
      }

      stat = RNStatus.interface_to_stat_map(iface)
      assert stat["announce_queue"] == 3
    end

    test "counts held announces map size" do
      iface = %{
        name: "Test",
        held_announces: %{"a" => 1, "b" => 2}
      }

      stat = RNStatus.interface_to_stat_map(iface)
      assert stat["held_announces"] == 2
    end
  end

  # ── Pretty Date ────────────────────────────────────────────────────

  describe "pretty_date/1" do
    test "formats recent timestamps" do
      now = System.system_time(:second)
      assert RNStatus.pretty_date(now - 5) =~ "seconds"
    end

    test "formats minutes ago" do
      now = System.system_time(:second)
      assert RNStatus.pretty_date(now - 180) =~ "3 minutes"
    end

    test "formats hours ago" do
      now = System.system_time(:second)
      assert RNStatus.pretty_date(now - 7200) =~ "hour"
    end

    test "formats days ago" do
      now = System.system_time(:second)
      assert RNStatus.pretty_date(now - 3 * 86400) =~ "3 days"
    end

    test "formats one minute boundary" do
      now = System.system_time(:second)
      assert RNStatus.pretty_date(now - 90) == "1 minute"
    end
  end

  # ── Print Interface Stat ───────────────────────────────────────────

  describe "print_interface_stat/2" do
    test "prints basic interface info" do
      stat = %{
        "name" => "UDPInterface[test]",
        "status" => true,
        "mode" => Interface.mode_full(),
        "rxb" => 1024,
        "txb" => 2048,
        "bitrate" => 62_500,
        "peers" => nil,
        "clients" => nil,
        "ifac_signature" => nil,
        "ifac_size" => 0,
        "ifac_netname" => nil,
        "announce_queue" => 0,
        "held_announces" => 0,
        "incoming_announce_frequency" => nil,
        "outgoing_announce_frequency" => nil,
        "rxs" => 0,
        "txs" => 0
      }

      opts = %{announce_stats: false}

      output = capture_io(fn -> RNStatus.print_interface_stat(stat, opts) end)

      assert output =~ "UDPInterface[test]"
      assert output =~ "Status    : Up"
      assert output =~ "Mode      : Full"
      assert output =~ "Rate      :"
      assert output =~ "Traffic   :"
    end

    test "prints clients for shared instance" do
      stat = %{
        "name" => "Shared Instance[server]",
        "status" => true,
        "mode" => Interface.mode_full(),
        "rxb" => 0,
        "txb" => 0,
        "bitrate" => nil,
        "peers" => nil,
        "clients" => 5,
        "ifac_signature" => nil,
        "ifac_size" => 0,
        "ifac_netname" => nil,
        "announce_queue" => 0,
        "held_announces" => 0,
        "incoming_announce_frequency" => nil,
        "outgoing_announce_frequency" => nil,
        "rxs" => nil,
        "txs" => nil
      }

      opts = %{announce_stats: false}

      output = capture_io(fn -> RNStatus.print_interface_stat(stat, opts) end)

      assert output =~ "Serving   : 4 programs"
    end

    test "prints announce stats when enabled" do
      stat = %{
        "name" => "TestInterface[test]",
        "status" => true,
        "mode" => Interface.mode_full(),
        "rxb" => 0,
        "txb" => 0,
        "bitrate" => nil,
        "peers" => nil,
        "clients" => nil,
        "ifac_signature" => nil,
        "ifac_size" => 0,
        "ifac_netname" => nil,
        "announce_queue" => 3,
        "held_announces" => 2,
        "incoming_announce_frequency" => 5,
        "outgoing_announce_frequency" => 10,
        "rxs" => nil,
        "txs" => nil
      }

      opts = %{announce_stats: true}

      output = capture_io(fn -> RNStatus.print_interface_stat(stat, opts) end)

      assert output =~ "Queued    : 3 announces"
      assert output =~ "Held      : 2 announces"
      assert output =~ "Announces :"
    end

    test "prints peers when present" do
      stat = %{
        "name" => "AutoInterface[test]",
        "status" => true,
        "mode" => Interface.mode_full(),
        "rxb" => 0,
        "txb" => 0,
        "bitrate" => nil,
        "peers" => 5,
        "clients" => nil,
        "ifac_signature" => nil,
        "ifac_size" => 0,
        "ifac_netname" => nil,
        "announce_queue" => 0,
        "held_announces" => 0,
        "incoming_announce_frequency" => nil,
        "outgoing_announce_frequency" => nil,
        "rxs" => nil,
        "txs" => nil
      }

      opts = %{announce_stats: false}

      output = capture_io(fn -> RNStatus.print_interface_stat(stat, opts) end)

      assert output =~ "Peers     : 5 reachable"
    end

    test "prints network name when present" do
      stat = %{
        "name" => "TestInterface[test]",
        "status" => false,
        "mode" => Interface.mode_full(),
        "rxb" => 0,
        "txb" => 0,
        "bitrate" => nil,
        "peers" => nil,
        "clients" => nil,
        "ifac_signature" => nil,
        "ifac_size" => 0,
        "ifac_netname" => "TestNet",
        "announce_queue" => 0,
        "held_announces" => 0,
        "incoming_announce_frequency" => nil,
        "outgoing_announce_frequency" => nil,
        "rxs" => nil,
        "txs" => nil
      }

      opts = %{announce_stats: false}

      output = capture_io(fn -> RNStatus.print_interface_stat(stat, opts) end)

      assert output =~ "Network   : TestNet"
      assert output =~ "Status    : Down"
    end
  end

  # ── Print Stats (integration) ──────────────────────────────────────

  describe "print_stats/2" do
    test "prints empty interface list" do
      stats = %{
        "interfaces" => [],
        "transport_id" => nil,
        "transport_uptime" => nil,
        "link_count" => nil,
        "rxb" => 0,
        "txb" => 0,
        "rxs" => 0,
        "txs" => 0
      }

      opts = %{
        all: false,
        announce_stats: false,
        link_stats: false,
        totals: false,
        sort: nil,
        reverse: false,
        name_filter: nil
      }

      output = capture_io(fn -> RNStatus.print_stats(stats, opts) end)
      # Should at least produce a trailing newline
      assert output =~ "\n"
    end

    test "prints transport info when transport_id present" do
      stats = %{
        "interfaces" => [],
        "transport_id" => :crypto.strong_rand_bytes(16),
        "transport_uptime" => 3600,
        "link_count" => nil,
        "rxb" => 0,
        "txb" => 0,
        "rxs" => 0,
        "txs" => 0
      }

      opts = %{
        all: false,
        announce_stats: false,
        link_stats: false,
        totals: false,
        sort: nil,
        reverse: false,
        name_filter: nil
      }

      output = capture_io(fn -> RNStatus.print_stats(stats, opts) end)

      assert output =~ "Transport Instance"
      assert output =~ "running"
      assert output =~ "Uptime is"
    end

    test "prints traffic totals when enabled" do
      stats = %{
        "interfaces" => [],
        "transport_id" => nil,
        "transport_uptime" => nil,
        "link_count" => nil,
        "rxb" => 5000,
        "txb" => 3000,
        "rxs" => 100,
        "txs" => 50
      }

      opts = %{
        all: false,
        announce_stats: false,
        link_stats: false,
        totals: true,
        sort: nil,
        reverse: false,
        name_filter: nil
      }

      output = capture_io(fn -> RNStatus.print_stats(stats, opts) end)

      assert output =~ "Totals"
    end

    test "prints link stats when enabled" do
      stats = %{
        "interfaces" => [],
        "transport_id" => :crypto.strong_rand_bytes(16),
        "transport_uptime" => 3600,
        "link_count" => 5,
        "rxb" => 0,
        "txb" => 0,
        "rxs" => 0,
        "txs" => 0
      }

      opts = %{
        all: false,
        announce_stats: false,
        link_stats: true,
        totals: false,
        sort: nil,
        reverse: false,
        name_filter: nil
      }

      output = capture_io(fn -> RNStatus.print_stats(stats, opts) end)

      assert output =~ "5 entries in link table"
    end
  end

  # ── Helper ──────────────────────────────────────────────────────────

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
