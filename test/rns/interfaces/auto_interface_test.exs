defmodule RNS.Interfaces.AutoInterfaceTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias RNS.Interfaces.AutoInterface
  alias RNS.Interfaces.AutoInterfacePeer

  # ── Constants ───────────────────────────────────────────────────

  describe "constants" do
    test "HW_MTU" do
      assert AutoInterface.hw_mtu() == 1196
    end

    test "default ports" do
      assert AutoInterface.default_discovery_port() == 29_716
      assert AutoInterface.default_data_port() == 42_671
    end

    test "default group ID" do
      assert AutoInterface.default_group_id() == "reticulum"
    end

    test "default IFAC size" do
      assert AutoInterface.default_ifac_size() == 16
    end

    test "scope constants" do
      assert AutoInterface.scope_link() == "2"
      assert AutoInterface.scope_admin() == "4"
      assert AutoInterface.scope_site() == "5"
      assert AutoInterface.scope_organisation() == "8"
      assert AutoInterface.scope_global() == "e"
    end

    test "multicast address type constants" do
      assert AutoInterface.multicast_permanent_address_type() == "0"
      assert AutoInterface.multicast_temporary_address_type() == "1"
    end

    test "timing constants" do
      assert AutoInterface.peering_timeout() == 22.0
      assert AutoInterface.announce_interval() == 1.6
      assert AutoInterface.peer_job_interval() == 4.0
      assert AutoInterface.mcast_echo_timeout() == 6.5
    end

    test "ignore interface lists" do
      assert AutoInterface.all_ignore_ifs() == ["lo0"]
      assert "awdl0" in AutoInterface.darwin_ignore_ifs()
      assert "llw0" in AutoInterface.darwin_ignore_ifs()
      assert "lo0" in AutoInterface.darwin_ignore_ifs()
      assert "en5" in AutoInterface.darwin_ignore_ifs()
      assert "dummy0" in AutoInterface.android_ignore_ifs()
      assert "lo" in AutoInterface.android_ignore_ifs()
      assert "tun0" in AutoInterface.android_ignore_ifs()
    end

    test "bitrate guess" do
      assert AutoInterface.bitrate_guess() == 10_000_000
    end

    test "multi-interface deque constants" do
      assert AutoInterface.multi_if_deque_len() == 48
      assert AutoInterface.multi_if_deque_ttl() == 0.75
    end
  end

  # ── Pure functions ──────────────────────────────────────────────

  describe "descope_linklocal/1" do
    test "removes macOS scope specifier (%ifname)" do
      assert AutoInterface.descope_linklocal("fe80::1%en0") == "fe80::1"
    end

    test "removes BSD embedded scope specifier" do
      assert AutoInterface.descope_linklocal("fe80:1::abc:def") == "fe80::abc:def"
    end

    test "passes through normal link-local address unchanged" do
      assert AutoInterface.descope_linklocal("fe80::1") == "fe80::1"
    end

    test "handles complex scope specifiers" do
      assert AutoInterface.descope_linklocal("fe80::abcd:1234%awdl0") == "fe80::abcd:1234"
    end
  end

  describe "compute_mcast_address/3" do
    test "produces valid IPv6 multicast address format" do
      addr = AutoInterface.compute_mcast_address("reticulum", "2", "1")
      assert String.starts_with?(addr, "ff12:")
    end

    test "uses correct scope and address type in prefix" do
      addr = AutoInterface.compute_mcast_address("reticulum", "5", "0")
      assert String.starts_with?(addr, "ff05:")
    end

    test "different group IDs produce different addresses" do
      addr1 = AutoInterface.compute_mcast_address("reticulum", "2", "1")
      addr2 = AutoInterface.compute_mcast_address("other_group", "2", "1")
      refute addr1 == addr2
    end

    test "first group segment is always 0" do
      addr = AutoInterface.compute_mcast_address("reticulum", "2", "1")
      # Format is ff12:0:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx
      parts = String.split(addr, ":")
      assert Enum.at(parts, 1) == "0"
    end

    test "produces 8 colon-separated groups" do
      addr = AutoInterface.compute_mcast_address("reticulum", "2", "1")
      parts = String.split(addr, ":")
      assert length(parts) == 8
    end

    test "matches Python computation for default group" do
      # Verify the address matches the Python computation exactly
      group_hash = RNS.Identity.full_hash("reticulum")
      bytes = :binary.bin_to_list(group_hash)

      # Python: gt = "0" + ":"+hex(g[3]+(g[2]<<8)) ...
      expected_parts =
        for {hi_idx, lo_idx} <- [{2, 3}, {4, 5}, {6, 7}, {8, 9}, {10, 11}, {12, 13}] do
          val = Enum.at(bytes, lo_idx) + (Enum.at(bytes, hi_idx) <<< 8)
          Integer.to_string(val, 16) |> String.downcase()
        end

      expected = "ff12:0:" <> Enum.join(expected_parts, ":")
      actual = AutoInterface.compute_mcast_address("reticulum", "2", "1")
      assert actual == expected
    end
  end

  describe "compute_discovery_token/2" do
    test "returns 32-byte SHA-256 hash" do
      token = AutoInterface.compute_discovery_token("reticulum", "fe80::1")
      assert byte_size(token) == 32
    end

    test "matches Identity.full_hash of group_id + addr" do
      token = AutoInterface.compute_discovery_token("reticulum", "fe80::1")
      expected = RNS.Identity.full_hash("reticulum" <> "fe80::1")
      assert token == expected
    end

    test "different addresses produce different tokens" do
      t1 = AutoInterface.compute_discovery_token("reticulum", "fe80::1")
      t2 = AutoInterface.compute_discovery_token("reticulum", "fe80::2")
      refute t1 == t2
    end

    test "different group IDs produce different tokens" do
      t1 = AutoInterface.compute_discovery_token("reticulum", "fe80::1")
      t2 = AutoInterface.compute_discovery_token("other", "fe80::1")
      refute t1 == t2
    end
  end

  describe "should_use_interface?/4" do
    test "allows explicitly allowed interface" do
      assert AutoInterface.should_use_interface?("en0", ["en0"], [], :darwin)
    end

    test "rejects interface in ignored list" do
      refute AutoInterface.should_use_interface?("en1", [], ["en1"], :darwin)
    end

    test "rejects Darwin AWDL interfaces unless explicitly allowed" do
      refute AutoInterface.should_use_interface?("awdl0", [], [], :darwin)
      assert AutoInterface.should_use_interface?("awdl0", ["awdl0"], [], :darwin)
    end

    test "rejects Darwin loopback" do
      refute AutoInterface.should_use_interface?("lo0", [], [], :darwin)
    end

    test "rejects Android system interfaces unless explicitly allowed" do
      refute AutoInterface.should_use_interface?("dummy0", [], [], :android)
      assert AutoInterface.should_use_interface?("dummy0", ["dummy0"], [], :android)
    end

    test "rejects interfaces in ALL_IGNORE_IFS" do
      refute AutoInterface.should_use_interface?("lo0", [], [], :linux)
    end

    test "rejects non-allowed interface when allowed list is non-empty" do
      refute AutoInterface.should_use_interface?("en1", ["en0"], [], :linux)
    end

    test "allows any interface when allowed list is empty and not ignored" do
      assert AutoInterface.should_use_interface?("eth0", [], [], :linux)
    end
  end

  describe "parse_discovery_scope/1" do
    test "parses link scope" do
      assert AutoInterface.parse_discovery_scope("link") == "2"
    end

    test "parses admin scope" do
      assert AutoInterface.parse_discovery_scope("admin") == "4"
    end

    test "parses site scope" do
      assert AutoInterface.parse_discovery_scope("site") == "5"
    end

    test "parses organisation scope" do
      assert AutoInterface.parse_discovery_scope("organisation") == "8"
    end

    test "parses global scope" do
      assert AutoInterface.parse_discovery_scope("global") == "e"
    end

    test "defaults to link scope for nil" do
      assert AutoInterface.parse_discovery_scope(nil) == "2"
    end

    test "is case insensitive" do
      assert AutoInterface.parse_discovery_scope("LINK") == "2"
      assert AutoInterface.parse_discovery_scope("Admin") == "4"
    end
  end

  describe "parse_multicast_address_type/1" do
    test "parses permanent" do
      assert AutoInterface.parse_multicast_address_type("permanent") == "0"
    end

    test "parses temporary" do
      assert AutoInterface.parse_multicast_address_type("temporary") == "1"
    end

    test "defaults to temporary for nil" do
      assert AutoInterface.parse_multicast_address_type(nil) == "1"
    end

    test "is case insensitive" do
      assert AutoInterface.parse_multicast_address_type("PERMANENT") == "0"
      assert AutoInterface.parse_multicast_address_type("Temporary") == "1"
    end
  end

  # ── Network helpers ─────────────────────────────────────────────

  describe "list_link_local_addresses/1" do
    test "returns list of link-local IPv6 addresses for loopback" do
      # On macOS lo0 has fe80::1
      addrs = AutoInterface.list_link_local_addresses("lo0")
      assert is_list(addrs)
      # May or may not have link-local on loopback depending on OS
    end

    test "returns empty list for nonexistent interface" do
      addrs = AutoInterface.list_link_local_addresses("nonexistent99")
      assert addrs == []
    end
  end

  describe "list_suitable_interfaces/3" do
    test "returns list of {ifname, link_local_addr} tuples" do
      result = AutoInterface.list_suitable_interfaces(["lo0"], [], :darwin)
      assert is_list(result)
    end

    test "filters based on allowed/ignored lists" do
      result = AutoInterface.list_suitable_interfaces([], ["lo0"], :darwin)
      # lo0 should not appear since it's ignored
      refute Enum.any?(result, fn {name, _addr} -> name == "lo0" end)
    end
  end

  # ── GenServer lifecycle ─────────────────────────────────────────

  describe "start_link/1" do
    test "starts with name" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "TestAuto",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      assert Process.alive?(pid)
      AutoInterface.stop(pid)
    end

    test "starts with custom group_id" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "TestAutoGroup",
          group_id: "my_custom_group",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      state = AutoInterface.get_state(pid)
      assert state.group_id == "my_custom_group"
      AutoInterface.stop(pid)
    end

    test "starts with custom ports" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "TestAutoPorts",
          discovery_port: 30_000,
          data_port: 40_000,
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      state = AutoInterface.get_state(pid)
      assert state.discovery_port == 30_000
      assert state.data_port == 40_000
      AutoInterface.stop(pid)
    end

    test "computes unicast_discovery_port as discovery_port + 1" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "TestAutoUnicast",
          discovery_port: 30_000,
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      state = AutoInterface.get_state(pid)
      assert state.unicast_discovery_port == 30_001
      AutoInterface.stop(pid)
    end

    test "starts with custom discovery scope" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "TestAutoScope",
          discovery_scope: "site",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      state = AutoInterface.get_state(pid)
      assert state.discovery_scope == "5"
      AutoInterface.stop(pid)
    end

    test "computes multicast discovery address" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "TestAutoMcast",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      state = AutoInterface.get_state(pid)
      assert is_binary(state.mcast_discovery_address)
      assert String.starts_with?(state.mcast_discovery_address, "ff12:")
      AutoInterface.stop(pid)
    end

    test "registers with server_name" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "TestAutoNamed",
          allowed_interfaces: ["lo0"],
          skip_network: true,
          server_name: :test_auto_named
        )

      assert Process.whereis(:test_auto_named) == pid
      AutoInterface.stop(pid)
    end
  end

  # ── Peer management ─────────────────────────────────────────────

  describe "peer management" do
    setup do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "PeerTestAuto",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      on_exit(fn -> catch_exit(AutoInterface.stop(pid)) end)
      %{pid: pid}
    end

    test "initially has no peers", %{pid: pid} do
      assert AutoInterface.peer_count(pid) == 0
    end

    test "add_peer adds a new peer", %{pid: pid} do
      AutoInterface.add_peer(pid, "fe80::dead:beef", "lo0")
      assert AutoInterface.peer_count(pid) == 1
    end

    test "add_peer for same address refreshes instead of adding", %{pid: pid} do
      AutoInterface.add_peer(pid, "fe80::dead:beef", "lo0")
      AutoInterface.add_peer(pid, "fe80::dead:beef", "lo0")
      assert AutoInterface.peer_count(pid) == 1
    end

    test "add_peer for different addresses adds multiple peers", %{pid: pid} do
      AutoInterface.add_peer(pid, "fe80::1111", "lo0")
      AutoInterface.add_peer(pid, "fe80::2222", "lo0")
      assert AutoInterface.peer_count(pid) == 2
    end

    test "remove_peer removes a peer", %{pid: pid} do
      AutoInterface.add_peer(pid, "fe80::dead:beef", "lo0")
      assert AutoInterface.peer_count(pid) == 1
      AutoInterface.remove_peer(pid, "fe80::dead:beef")
      assert AutoInterface.peer_count(pid) == 0
    end

    test "get_peers returns all peers", %{pid: pid} do
      AutoInterface.add_peer(pid, "fe80::1111", "lo0")
      AutoInterface.add_peer(pid, "fe80::2222", "lo0")
      peers = AutoInterface.get_peers(pid)
      assert map_size(peers) == 2
      assert Map.has_key?(peers, "fe80::1111")
      assert Map.has_key?(peers, "fe80::2222")
    end
  end

  # ── Multicast echo tracking ────────────────────────────────────

  describe "multicast echo tracking" do
    setup do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "EchoTestAuto",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      on_exit(fn -> catch_exit(AutoInterface.stop(pid)) end)
      %{pid: pid}
    end

    test "add_peer for own link-local address records echo", %{pid: pid} do
      _state = AutoInterface.get_state(pid)
      # Add our own link-local address as an adopted interface
      AutoInterface.set_adopted_interface(pid, "lo0", "fe80::1")
      AutoInterface.set_link_local_address(pid, "fe80::1")

      # Adding a peer with our own address should record an echo, not a peer
      AutoInterface.add_peer(pid, "fe80::1", "lo0")
      assert AutoInterface.peer_count(pid) == 0
    end
  end

  # ── AutoInterfacePeer ──────────────────────────────────────────

  describe "AutoInterfacePeer struct" do
    test "creates with required fields" do
      peer = %AutoInterfacePeer{
        addr: "fe80::dead:beef",
        ifname: "en0",
        hw_mtu: 1196,
        fixed_mtu: true
      }

      assert peer.addr == "fe80::dead:beef"
      assert peer.ifname == "en0"
      assert peer.hw_mtu == 1196
      assert peer.fixed_mtu == true
    end

    test "has Interface default fields" do
      peer = %AutoInterfacePeer{}
      assert peer.online == false
      assert peer.rxb == 0
      assert peer.txb == 0
    end

    test "String.Chars format matches Python" do
      peer = %AutoInterfacePeer{
        addr: "fe80::dead:beef",
        ifname: "en0"
      }

      assert to_string(peer) == "AutoInterfacePeer[en0/fe80::dead:beef]"
    end
  end

  # ── Multi-interface deduplication ──────────────────────────────

  describe "deduplication" do
    test "mif_deque_check returns false for new data" do
      deque = :queue.new()
      deque_times = :queue.new()

      {hit, _deque, _times} =
        AutoInterface.mif_deque_check(
          <<1, 2, 3>>,
          deque,
          deque_times,
          48,
          0.75
        )

      refute hit
    end

    test "mif_deque_check returns true for duplicate data within TTL" do
      data = <<1, 2, 3>>
      data_hash = RNS.Identity.full_hash(data)
      now = System.system_time(:millisecond) / 1000

      deque = :queue.in(data_hash, :queue.new())
      deque_times = :queue.in({data_hash, now}, :queue.new())

      {hit, _deque, _times} =
        AutoInterface.mif_deque_check(
          data,
          deque,
          deque_times,
          48,
          0.75
        )

      assert hit
    end

    test "mif_deque_check returns false for duplicate data past TTL" do
      data = <<1, 2, 3>>
      data_hash = RNS.Identity.full_hash(data)
      old_time = System.system_time(:millisecond) / 1000 - 2.0

      deque = :queue.in(data_hash, :queue.new())
      deque_times = :queue.in({data_hash, old_time}, :queue.new())

      {hit, _deque, _times} =
        AutoInterface.mif_deque_check(
          data,
          deque,
          deque_times,
          48,
          0.75
        )

      refute hit
    end

    test "mif_deque_check adds hash to deque when not a hit" do
      data = <<1, 2, 3>>
      deque = :queue.new()
      deque_times = :queue.new()

      {false, new_deque, new_times} =
        AutoInterface.mif_deque_check(
          data,
          deque,
          deque_times,
          48,
          0.75
        )

      assert :queue.len(new_deque) == 1
      assert :queue.len(new_times) == 1
    end

    test "mif_deque respects max length" do
      deque = Enum.reduce(1..48, :queue.new(), fn i, q -> :queue.in(<<i>>, q) end)

      deque_times =
        Enum.reduce(1..48, :queue.new(), fn i, q ->
          :queue.in({<<i>>, System.system_time(:millisecond) / 1000}, q)
        end)

      data = <<99>>

      {false, new_deque, new_times} =
        AutoInterface.mif_deque_check(
          data,
          deque,
          deque_times,
          48,
          0.75
        )

      assert :queue.len(new_deque) == 48
      assert :queue.len(new_times) == 48
    end
  end

  # ── process_outgoing ────────────────────────────────────────────

  describe "send_data/2" do
    test "is a no-op for AutoInterface parent" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "OutboundTestAuto",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      assert AutoInterface.send_data(pid, <<1, 2, 3>>) == :ok
      AutoInterface.stop(pid)
    end
  end

  # ── detach ──────────────────────────────────────────────────────

  describe "stop_interface/1" do
    test "sets interface offline" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "DetachTestAuto",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      AutoInterface.stop_interface(pid)
      state = AutoInterface.get_state(pid)
      refute state.online
      AutoInterface.stop(pid)
    end
  end

  # ── String.Chars ────────────────────────────────────────────────

  describe "String.Chars" do
    test "format matches Python AutoInterface[name]" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "MyAutoIf",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      state = AutoInterface.get_state(pid)
      assert to_string(state) == "AutoInterface[MyAutoIf]"
      AutoInterface.stop(pid)
    end
  end

  # ── Interface behaviour ─────────────────────────────────────────

  describe "Interface behaviour" do
    test "implements process_outgoing/2 callback" do
      assert function_exported?(AutoInterface, :process_outgoing, 2)
    end

    test "implements process_incoming/2 callback" do
      assert function_exported?(AutoInterface, :process_incoming, 2)
    end

    test "implements detach/1 callback" do
      assert function_exported?(AutoInterface, :detach, 1)
    end
  end

  # ── Reverse peering interval ───────────────────────────────────

  describe "reverse_peering_interval" do
    test "is announce_interval * 3.25" do
      {:ok, pid} =
        AutoInterface.start_link(
          name: "ReverseTestAuto",
          allowed_interfaces: ["lo0"],
          skip_network: true
        )

      state = AutoInterface.get_state(pid)
      expected = AutoInterface.announce_interval() * 3.25
      assert_in_delta state.reverse_peering_interval, expected, 0.001
      AutoInterface.stop(pid)
    end
  end
end
