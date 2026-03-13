defmodule RNS.Interfaces.WeaveInterfaceTest do
  use ExUnit.Case, async: true

  alias RNS.Interfaces.WeaveInterface
  alias RNS.Interfaces.WeaveInterface.{WDCL, Cmd, Evt, LogFrame, WeaveEndpoint, WeaveDevice, WeaveInterfacePeer}

  # ── WeaveInterface constants ───────────────────────────────────

  describe "WeaveInterface constants" do
    test "interface constants" do
      c = WeaveInterface.constants()
      assert c.hw_mtu == 1024
      assert c.fixed_mtu == true
      assert c.default_ifac_size == 16
      assert c.peering_timeout == 20.0
      assert c.bitrate_guess == 250_000
    end

    test "deduplication constants" do
      c = WeaveInterface.constants()
      assert c.multi_if_deque_len == 48
      assert c.multi_if_deque_ttl == 0.75
    end
  end

  # ── WeaveInterface struct ──────────────────────────────────────

  describe "WeaveInterface struct" do
    test "default struct fields" do
      s = %WeaveInterface{}
      assert s.name == nil
      assert s.port == nil
      assert s.peers == %{}
      assert s.spawned_interfaces == nil
      assert s._online == false
      assert s.final_init_done == false
      assert s.receives == true
    end
  end

  # ── WDCL constants ─────────────────────────────────────────────

  describe "WDCL constants" do
    test "packet types" do
      c = WDCL.constants()
      assert c.wdcl_t_discover == 0x00
      assert c.wdcl_t_connect == 0x01
      assert c.wdcl_t_cmd == 0x02
      assert c.wdcl_t_log == 0x03
      assert c.wdcl_t_disp == 0x04
      assert c.wdcl_t_endpoint_pkt == 0x05
      assert c.wdcl_t_encap_proto == 0x06
    end

    test "broadcast address" do
      c = WDCL.constants()
      assert c.wdcl_broadcast == <<0xFF, 0xFF, 0xFF, 0xFF>>
    end

    test "timing constants" do
      c = WDCL.constants()
      assert c.wdcl_handshake_timeout == 2
      assert c.header_minsize == 5
      assert c.max_chunk == 32_768
      assert c.default_speed == 3_000_000
    end
  end

  # ── WDCL struct ────────────────────────────────────────────────

  describe "WDCL struct" do
    test "default struct fields" do
      conn = %WDCL{}
      assert conn.speed == 3_000_000
      assert conn.databits == 8
      assert conn.parity == :none
      assert conn.stopbits == 1
      assert conn.online == false
      assert conn.wdcl_connected == false
      assert conn.rxb == 0
      assert conn.txb == 0
    end
  end

  # ── WDCL protocol ──────────────────────────────────────────────

  describe "WDCL.new/1" do
    test "creates connection with owner" do
      owner = %{switch_id: <<1, 2, 3, 4>>, switch_pub_bytes: <<5, 6, 7, 8>>}
      conn = WDCL.new(owner: owner)
      assert conn.switch_id == <<1, 2, 3, 4>>
      assert conn.switch_pub_bytes == <<5, 6, 7, 8>>
    end
  end

  describe "WDCL.process_outgoing/2" do
    test "HDLC-frames data" do
      conn = %WDCL{}
      {framed, conn} = WDCL.process_outgoing(conn, <<0x01, 0x02, 0x03>>)
      assert <<0x7E, _::binary>> = framed
      assert :binary.last(framed) == 0x7E
      assert conn.txb > 0
    end
  end

  describe "WDCL.build_discover/1" do
    test "builds discover broadcast" do
      discover = WDCL.build_discover(<<1, 2, 3, 4>>)
      assert <<0xFF, 0xFF, 0xFF, 0xFF, 0x00, 1, 2, 3, 4>> = discover
    end
  end

  describe "WDCL.build_send/3" do
    test "builds send packet" do
      packet = WDCL.build_send(<<1, 2, 3, 4>>, 0x05, <<0xAA, 0xBB>>)
      assert <<1, 2, 3, 4, 0x05, 0xAA, 0xBB>> = packet
    end
  end

  describe "WDCL.build_command/2" do
    test "builds command with 2-byte big-endian command" do
      cmd = WDCL.build_command(0x0001, <<0xAA>>)
      assert <<0x00, 0x01, 0xAA>> = cmd
    end
  end

  describe "WDCL.build_connect/3" do
    test "builds connect handshake" do
      conn = WDCL.build_connect(<<1, 2, 3, 4>>, <<5::256>>, <<6::512>>)
      assert <<1, 2, 3, 4, 0x01, _rest::binary>> = conn
    end
  end

  describe "WDCL.parse_discovery_response/1" do
    test "parses valid discovery response" do
      switch_id = <<1, 2, 3, 4>>
      pub_key = :crypto.strong_rand_bytes(32)
      signature = :crypto.strong_rand_bytes(64)
      data = switch_id <> <<0x00>> <> pub_key <> signature

      assert {:ok, result} = WDCL.parse_discovery_response(data)
      assert result.signed_id == switch_id
      assert result.pub_key == pub_key
      assert result.switch_id == binary_part(pub_key, 28, 4)
      assert result.signature == signature
    end

    test "returns error for invalid length" do
      assert :error = WDCL.parse_discovery_response(<<1, 2, 3>>)
    end
  end

  describe "WDCL.packet_type/1" do
    test "extracts packet type" do
      data = <<1, 2, 3, 4, 0x05, 0xAA>>
      assert WDCL.packet_type(data) == 0x05
    end

    test "returns nil for short data" do
      assert WDCL.packet_type(<<1, 2, 3>>) == nil
    end
  end

  # ── Cmd constants ──────────────────────────────────────────────

  describe "Cmd constants" do
    test "command codes" do
      c = Cmd.constants()
      assert c.wdcl_cmd_endpoint_pkt == 0x0001
      assert c.wdcl_cmd_endpoints_list == 0x0100
      assert c.wdcl_cmd_remote_display == 0x0A00
      assert c.wdcl_cmd_remote_input == 0x0A01
    end

    test "accessor functions" do
      assert Cmd.endpoint_pkt() == 0x0001
      assert Cmd.endpoints_list() == 0x0100
      assert Cmd.remote_display() == 0x0A00
      assert Cmd.remote_input() == 0x0A01
    end
  end

  # ── Evt constants ──────────────────────────────────────────────

  describe "Evt constants" do
    test "event descriptions exist" do
      descs = Evt.event_descriptions()
      assert Map.has_key?(descs, 0x0001)
      assert descs[0x0001] == "System boot"
      assert Map.has_key?(descs, 0x3002)
      assert descs[0x3002] == "WDCL host connection"
    end

    test "interface types" do
      types = Evt.interface_types()
      assert types[0x01] == "usb"
      assert types[0x05] == "lora"
      assert types[0x07] == "wifi"
    end

    test "channel descriptions" do
      channels = Evt.channel_descriptions()
      assert channels[1] == "Channel 1 (2412 MHz)"
      assert channels[14] == "Channel 14 (2484 MHz)"
    end

    test "log levels" do
      levels = Evt.levels()
      assert levels[0] == "Forced"
      assert levels[1] == "Critical"
      assert levels[7] == "Debug"
      assert levels[9] == "System"
    end

    test "level/1 function" do
      assert Evt.level(0) == "Forced"
      assert Evt.level(7) == "Debug"
      assert Evt.level(99) == "Unknown"
    end

    test "event_description/1" do
      assert Evt.event_description(0x0001) == "System boot"
      assert Evt.event_description(0xFFFF) == nil
    end

    test "interface_type/1" do
      assert Evt.interface_type(0x01) == "usb"
      assert Evt.interface_type(0xFF) == "phy"
    end

    test "channel_description/1" do
      assert Evt.channel_description(6) == "Channel 6 (2437 MHz)"
      assert Evt.channel_description(99) == nil
    end

    test "task_description/1" do
      assert Evt.task_description("protocol_wdcl") == "Protocol: WDCL"
      assert Evt.task_description("unknown") == "unknown"
    end

    test "task descriptions" do
      descs = Evt.task_descriptions()
      assert descs["core"] == "System: Core"
      assert descs["wifi"] == "System: WiFi Hardware"
    end
  end

  # ── LogFrame ───────────────────────────────────────────────────

  describe "LogFrame" do
    test "new/1 creates frame with defaults" do
      frame = LogFrame.new()
      assert frame.timestamp == nil
      assert frame.level == nil
      assert frame.event == nil
      assert frame.data == <<>>
    end

    test "new/1 with options" do
      frame = LogFrame.new(timestamp: 1.5, level: 4, event: 0x0001, data: <<0xFF>>)
      assert frame.timestamp == 1.5
      assert frame.level == 4
      assert frame.event == 0x0001
      assert frame.data == <<0xFF>>
    end
  end

  # ── WeaveEndpoint ──────────────────────────────────────────────

  describe "WeaveEndpoint" do
    test "queue_len constant" do
      assert WeaveEndpoint.queue_len() == 1024
    end

    test "new/1 creates endpoint" do
      ep = WeaveEndpoint.new(<<1, 2, 3, 4, 5, 6, 7, 8>>)
      assert ep.endpoint_addr == <<1, 2, 3, 4, 5, 6, 7, 8>>
      assert ep.alive != nil
      assert ep.via == nil
    end

    test "receive_data/2 records packet" do
      ep = WeaveEndpoint.new(<<1::64>>)
      ep = WeaveEndpoint.receive_data(ep, "packet1")
      ep = WeaveEndpoint.receive_data(ep, "packet2")
      assert :queue.len(ep.received) == 2
    end
  end

  # ── WeaveDevice ────────────────────────────────────────────────

  describe "WeaveDevice constants" do
    test "size constants" do
      c = WeaveDevice.constants()
      assert c.weave_switch_id_len == 4
      assert c.weave_endpoint_id_len == 8
      assert c.weave_flowseq_len == 2
      assert c.weave_hmac_len == 8
      assert c.weave_auth_len == 16
      assert c.weave_pubkey_size == 32
      assert c.weave_prvkey_size == 64
      assert c.weave_signature_len == 64
    end

    test "stats constants" do
      c = WeaveDevice.constants()
      assert c.statlen_max == 120
      assert c.stat_update_throttle == 0.5
    end
  end

  describe "WeaveDevice.new/1" do
    test "creates device with defaults" do
      device = WeaveDevice.new()
      assert device.endpoints == %{}
      assert device.cpu_load == 0
      assert device.memory_total == 0
      assert device.as_interface == false
    end

    test "creates device as interface" do
      device = WeaveDevice.new(as_interface: true)
      assert device.as_interface == true
    end
  end

  describe "WeaveDevice.endpoint_alive/2" do
    test "creates new endpoint" do
      device = WeaveDevice.new()
      ep_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      device = WeaveDevice.endpoint_alive(device, ep_id)
      assert Map.has_key?(device.endpoints, ep_id)
    end

    test "updates existing endpoint" do
      device = WeaveDevice.new()
      ep_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      device = WeaveDevice.endpoint_alive(device, ep_id)
      t1 = device.endpoints[ep_id].alive
      Process.sleep(10)
      device = WeaveDevice.endpoint_alive(device, ep_id)
      t2 = device.endpoints[ep_id].alive
      assert t2 >= t1
    end
  end

  describe "WeaveDevice.endpoint_via/3" do
    test "sets endpoint routing" do
      device = WeaveDevice.new()
      ep_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      via = <<0xAA, 0xBB, 0xCC, 0xDD>>
      device = WeaveDevice.endpoint_alive(device, ep_id)
      device = WeaveDevice.endpoint_via(device, ep_id, via)
      assert device.endpoints[ep_id].via == via
    end

    test "no-op for unknown endpoint" do
      device = WeaveDevice.new()
      device = WeaveDevice.endpoint_via(device, <<1::64>>, <<2::32>>)
      assert device.endpoints == %{}
    end
  end

  describe "WeaveDevice.build_deliver_packet/2" do
    test "builds deliver packet command" do
      ep_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      data = <<0xAA, 0xBB>>
      cmd = WeaveDevice.build_deliver_packet(ep_id, data)
      assert <<0x00, 0x01, 1, 2, 3, 4, 5, 6, 7, 8, 0xAA, 0xBB>> = cmd
    end
  end

  describe "WeaveDevice.log_handle/2" do
    test "handles WDCL connection event" do
      device = WeaveDevice.new()
      frame = LogFrame.new(event: Evt.et_proto_wdcl_connection(), level: 5, data: <<>>)
      result = WeaveDevice.log_handle(device, frame)
      assert result == device
    end

    test "handles host endpoint event" do
      device = WeaveDevice.new()
      ep_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      frame = LogFrame.new(event: Evt.et_proto_wdcl_host_endpoint(), data: ep_id)
      device = WeaveDevice.log_handle(device, frame)
      assert device.endpoint_id == ep_id
    end

    test "handles endpoint alive event" do
      device = WeaveDevice.new()
      ep_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      frame = LogFrame.new(event: Evt.et_proto_weave_ep_alive(), data: ep_id)
      device = WeaveDevice.log_handle(device, frame)
      assert Map.has_key?(device.endpoints, ep_id)
    end

    test "handles endpoint via event" do
      device = WeaveDevice.new()
      ep_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
      via_id = <<0xAA, 0xBB, 0xCC, 0xDD>>
      device = WeaveDevice.endpoint_alive(device, ep_id)
      frame = LogFrame.new(event: Evt.et_proto_weave_ep_via(), data: ep_id <> via_id)
      device = WeaveDevice.log_handle(device, frame)
      assert device.endpoints[ep_id].via == via_id
    end

    test "handles CPU stat event" do
      device = WeaveDevice.new()
      frame = LogFrame.new(event: Evt.et_stat_cpu(), data: <<75>>)
      device = WeaveDevice.log_handle(device, frame)
      assert device.cpu_load == 75
      assert :queue.len(device.cpu_stats) == 1
    end

    test "handles memory stat event" do
      device = WeaveDevice.new()
      frame = LogFrame.new(event: Evt.et_stat_memory(), data: <<0, 1, 0, 0, 0, 2, 0, 0>>)
      device = WeaveDevice.log_handle(device, frame)
      assert device.memory_free == 65536
      assert device.memory_total == 131072
      assert device.memory_used == 65536
      assert :queue.len(device.memory_stats) == 1
    end

    test "handles task CPU event" do
      device = WeaveDevice.new()
      frame = LogFrame.new(event: Evt.et_stat_task_cpu(), data: <<50>> <> "core")
      device = WeaveDevice.log_handle(device, frame)
      assert Map.has_key?(device.active_tasks, "core")
      assert device.active_tasks["core"].cpu_load == 50
    end
  end

  describe "WeaveDevice.get_cpu_stats/1" do
    test "returns stats structure" do
      device = WeaveDevice.new()
      frame = LogFrame.new(event: Evt.et_stat_cpu(), data: <<75>>)
      device = WeaveDevice.log_handle(device, frame)
      stats = WeaveDevice.get_cpu_stats(device)
      assert stats.max == 100
      assert stats.unit == "%"
      assert length(stats.values) == 1
      assert hd(stats.values) == 75
    end
  end

  describe "WeaveDevice.get_memory_stats/1" do
    test "returns stats structure" do
      device = WeaveDevice.new()
      frame = LogFrame.new(event: Evt.et_stat_memory(), data: <<0, 1, 0, 0, 0, 2, 0, 0>>)
      device = WeaveDevice.log_handle(device, frame)
      stats = WeaveDevice.get_memory_stats(device)
      assert stats.unit == "B"
      assert stats.max == 131072
      assert length(stats.values) == 1
    end
  end

  describe "WeaveDevice.get_active_tasks/1" do
    test "filters to active tasks" do
      device = WeaveDevice.new()
      now = System.system_time(:millisecond) / 1000
      device = %{device | active_tasks: %{
        "core" => %{cpu_load: 10, timestamp: now},
        "IDLE0" => %{cpu_load: 90, timestamp: now},
        "old_task" => %{cpu_load: 5, timestamp: now - 10}
      }}
      tasks = WeaveDevice.get_active_tasks(device)
      # Should exclude IDLE and old tasks
      assert map_size(tasks) == 1
      assert Map.has_key?(tasks, "System: Core")
    end
  end

  # ── WeaveInterfacePeer ─────────────────────────────────────────

  describe "WeaveInterfacePeer" do
    test "new/1 creates peer" do
      ep_addr = <<1, 2, 3, 4, 5, 6, 7, 8>>
      peer = WeaveInterfacePeer.new(endpoint_addr: ep_addr, hw_mtu: 1024)
      assert peer.endpoint_addr == ep_addr
      assert peer.hw_mtu == 1024
      assert peer._online == false
    end

    test "detach/1" do
      peer = WeaveInterfacePeer.new(endpoint_addr: <<1::64>>)
      peer = %{peer | _online: true}
      peer = WeaveInterfacePeer.detach(peer)
      assert peer._online == false
      assert peer.detached == true
    end

    test "teardown/1" do
      peer = WeaveInterfacePeer.new(endpoint_addr: <<1::64>>)
      peer = %{peer | _online: true, out: true, in: true}
      peer = WeaveInterfacePeer.teardown(peer)
      assert peer._online == false
      assert peer.out == false
      assert peer.in == false
    end

    test "process_outgoing/2 when online" do
      peer = WeaveInterfacePeer.new(endpoint_addr: <<1::64>>)
      peer = %{peer | _online: true}
      peer = WeaveInterfacePeer.process_outgoing(peer, "test data")
      assert peer.txb == 9
    end

    test "process_outgoing/2 when offline" do
      peer = WeaveInterfacePeer.new(endpoint_addr: <<1::64>>)
      peer = WeaveInterfacePeer.process_outgoing(peer, "test data")
      assert peer.txb == 0
    end

    test "online?/1" do
      peer = WeaveInterfacePeer.new(endpoint_addr: <<1::64>>)
      assert WeaveInterfacePeer.online?(peer) == false

      peer = %{peer | _online: true, owner: %{}}
      assert WeaveInterfacePeer.online?(peer) == true
    end
  end

  # ── WeaveInterfacePeer String.Chars ────────────────────────────

  describe "WeaveInterfacePeer String.Chars" do
    test "formats with endpoint address" do
      ep_addr = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22>>
      peer = WeaveInterfacePeer.new(endpoint_addr: ep_addr)
      str = to_string(peer)
      assert String.starts_with?(str, "WeaveInterfacePeer[")
      assert String.ends_with?(str, "]")
    end
  end

  # ── WeaveInterface peer management ─────────────────────────────

  describe "WeaveInterface peer management" do
    test "add_peer creates new peer" do
      state = %WeaveInterface{
        peers: %{},
        spawned_interfaces: %{},
        ifac_size: 16,
        bitrate: 250_000,
        hw_mtu: 1024,
        mode: 0x01,
      }
      ep_addr = <<1, 2, 3, 4, 5, 6, 7, 8>>
      state = WeaveInterface.add_peer(state, ep_addr)
      assert Map.has_key?(state.peers, ep_addr)
      assert Map.has_key?(state.spawned_interfaces, ep_addr)
    end

    test "add_peer refreshes existing peer" do
      state = %WeaveInterface{
        peers: %{},
        spawned_interfaces: %{},
        ifac_size: 16,
        bitrate: 250_000,
        hw_mtu: 1024,
        mode: 0x01,
      }
      ep_addr = <<1, 2, 3, 4, 5, 6, 7, 8>>
      state = WeaveInterface.add_peer(state, ep_addr)
      t1 = state.peers[ep_addr].last_heard
      Process.sleep(10)
      state = WeaveInterface.add_peer(state, ep_addr)
      t2 = state.peers[ep_addr].last_heard
      assert t2 >= t1
    end

    test "peer_count" do
      state = %WeaveInterface{
        peers: %{},
        spawned_interfaces: %{},
        ifac_size: 16,
        bitrate: 250_000,
        hw_mtu: 1024,
        mode: 0x01,
      }
      assert WeaveInterface.peer_count(state) == 0
      state = WeaveInterface.add_peer(state, <<1::64>>)
      assert WeaveInterface.peer_count(state) == 1
      state = WeaveInterface.add_peer(state, <<2::64>>)
      assert WeaveInterface.peer_count(state) == 2
    end

    test "endpoint_via updates peer routing" do
      state = %WeaveInterface{
        peers: %{},
        spawned_interfaces: %{},
        ifac_size: 16,
        bitrate: 250_000,
        hw_mtu: 1024,
        mode: 0x01,
      }
      ep_addr = <<1::64>>
      via = <<0xAA, 0xBB, 0xCC, 0xDD>>
      state = WeaveInterface.add_peer(state, ep_addr)
      state = WeaveInterface.endpoint_via(state, ep_addr, via)
      assert state.spawned_interfaces[ep_addr].via_switch_id == via
    end
  end

  # ── WeaveInterface deduplication ───────────────────────────────

  describe "WeaveInterface mif_deque_check" do
    test "first packet not a hit" do
      state = %WeaveInterface{
        mif_deque: :queue.new(),
        mif_deque_times: :queue.new(),
      }
      {hit, _state} = WeaveInterface.mif_deque_check(state, "test data")
      assert hit == false
    end

    test "duplicate packet is a hit" do
      state = %WeaveInterface{
        mif_deque: :queue.new(),
        mif_deque_times: :queue.new(),
      }
      {false, state} = WeaveInterface.mif_deque_check(state, "test data")
      {hit, _state} = WeaveInterface.mif_deque_check(state, "test data")
      assert hit == true
    end

    test "different packets are not hits" do
      state = %WeaveInterface{
        mif_deque: :queue.new(),
        mif_deque_times: :queue.new(),
      }
      {false, state} = WeaveInterface.mif_deque_check(state, "data1")
      {hit, _state} = WeaveInterface.mif_deque_check(state, "data2")
      assert hit == false
    end
  end

  # ── WeaveInterface GenServer ───────────────────────────────────

  describe "WeaveInterface GenServer" do
    test "starts with skip_wdcl" do
      {:ok, pid} = WeaveInterface.start_link(name: "TestWeave", skip_wdcl: true)
      state = GenServer.call(pid, :get_state)
      assert state.name == "TestWeave"
      assert state.skip_wdcl == true
      GenServer.stop(pid)
    end

    test "computes hash" do
      {:ok, pid} = WeaveInterface.start_link(name: "TestWeave", skip_wdcl: true)
      state = GenServer.call(pid, :get_state)
      assert state.hash != nil
      assert is_binary(state.hash)
      GenServer.stop(pid)
    end

    test "server_name registration" do
      {:ok, pid} = WeaveInterface.start_link(name: "TestWeave", skip_wdcl: true, server_name: :test_weave)
      assert Process.whereis(:test_weave) == pid
      GenServer.stop(pid)
    end

    test "configured_bitrate" do
      {:ok, pid} = WeaveInterface.start_link(name: "TestWeave", skip_wdcl: true, configured_bitrate: 500_000)
      state = GenServer.call(pid, :get_state)
      assert state.bitrate == 500_000
      GenServer.stop(pid)
    end
  end

  # ── WeaveInterface should_ingress_limit ────────────────────────

  describe "WeaveInterface should_ingress_limit" do
    test "always returns false" do
      state = %WeaveInterface{}
      assert {false, ^state} = WeaveInterface.should_ingress_limit(state)
    end
  end

  # ── WeaveInterface String.Chars ────────────────────────────────

  describe "WeaveInterface String.Chars" do
    test "formats correctly" do
      iface = %WeaveInterface{name: "MyWeave"}
      assert to_string(iface) == "WeaveInterface[MyWeave]"
    end
  end

  # ── WeaveInterface process_outgoing ────────────────────────────

  describe "WeaveInterface process_outgoing" do
    test "no-op on parent" do
      state = %WeaveInterface{txb: 0}
      result = WeaveInterface.process_outgoing(state, "test")
      assert result.txb == 0
    end
  end

  # ── WeaveInterface detach ──────────────────────────────────────

  describe "WeaveInterface detach" do
    test "sets offline" do
      state = %WeaveInterface{_online: true}
      state = WeaveInterface.detach(state)
      assert state._online == false
    end
  end
end
