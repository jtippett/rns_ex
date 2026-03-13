defmodule RNS.Interfaces.I2PInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.I2PController
  alias RNS.Interfaces.I2PInterface
  alias RNS.Interfaces.I2PInterfacePeer
  alias RNS.Interfaces.Interface
  alias RNS.Interfaces.Interface.HDLC
  alias RNS.Interfaces.Interface.KISS

  # ── I2PInterface constants ──────────────────────────────────────

  describe "I2PInterface constants" do
    test "BITRATE_GUESS is 256 kbps" do
      assert I2PInterface.bitrate_guess() == 256_000
    end

    test "DEFAULT_IFAC_SIZE is 16" do
      assert I2PInterface.default_ifac_size() == 16
    end

    test "HW_MTU is 1064" do
      assert I2PInterface.hw_mtu() == 1064
    end
  end

  # ── I2PInterface struct ─────────────────────────────────────────

  describe "I2PInterface struct" do
    test "has default interface fields" do
      iface = %I2PInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.mode == Interface.mode_full()
    end

    test "has I2P server-specific fields" do
      iface = %I2PInterface{}
      assert iface.bind_ip == "127.0.0.1"
      assert iface.bind_port == nil
      assert iface.listen_socket == nil
      assert iface.spawned_interfaces == []
      assert iface.connectable == false
      assert iface.b32 == nil
      assert iface.i2p_tunneled == true
      assert iface.receives == true
      assert iface.owner == nil
      assert iface.i2p_controller == nil
      assert iface.storagepath == nil
      assert iface.ifac_netname == nil
      assert iface.ifac_netkey == nil
    end
  end

  # ── I2PInterfacePeer constants ──────────────────────────────────

  describe "I2PInterfacePeer constants" do
    test "HW_MTU is 1064" do
      assert I2PInterfacePeer.hw_mtu() == 1064
    end

    test "BITRATE_GUESS is 256 kbps" do
      assert I2PInterfacePeer.bitrate_guess() == 256_000
    end

    test "DEFAULT_IFAC_SIZE is 16" do
      assert I2PInterfacePeer.default_ifac_size() == 16
    end

    test "RECONNECT_WAIT is 15 seconds" do
      assert I2PInterfacePeer.reconnect_wait() == 15
    end

    test "I2P TCP socket options match Python" do
      assert I2PInterfacePeer.i2p_user_timeout() == 45
      assert I2PInterfacePeer.i2p_probe_after() == 10
      assert I2PInterfacePeer.i2p_probe_interval() == 9
      assert I2PInterfacePeer.i2p_probes() == 5
      # I2P_READ_TIMEOUT = (I2P_PROBE_INTERVAL * I2P_PROBES + I2P_PROBE_AFTER) * 2
      # = (9 * 5 + 10) * 2 = 110
      assert I2PInterfacePeer.i2p_read_timeout() == 110
    end

    test "tunnel state constants" do
      assert I2PInterfacePeer.tunnel_state_init() == 0x00
      assert I2PInterfacePeer.tunnel_state_active() == 0x01
      assert I2PInterfacePeer.tunnel_state_stale() == 0x02
    end
  end

  # ── I2PInterfacePeer struct ─────────────────────────────────────

  describe "I2PInterfacePeer struct" do
    test "has default interface fields" do
      iface = %I2PInterfacePeer{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.mode == Interface.mode_full()
    end

    test "has I2P peer-specific fields" do
      iface = %I2PInterfacePeer{}
      assert iface.socket == nil
      assert iface.target_ip == nil
      assert iface.target_port == nil
      assert iface.initiator == false
      assert iface.reconnecting == false
      assert iface.never_connected == true
      assert iface.kiss_framing == false
      assert iface.frame_buffer == <<>>
      assert iface.i2p_tunneled == true
      assert iface.i2p_dest == nil
      assert iface.i2p_tunnel_ready == false
      assert iface.i2p_tunnel_state == 0x00
      assert iface.awaiting_i2p_tunnel == false
      assert iface.wants_tunnel == false
      assert iface.max_reconnect_tries == nil
      assert iface.parent_interface == nil
      assert iface.parent_count == true
      assert iface.receives == true
      assert iface.owner == nil
    end
  end

  # ── I2PController constants ────────────────────────────────────

  describe "I2PController constants" do
    test "SAM default address" do
      assert I2PController.sam_default_host() == "127.0.0.1"
      assert I2PController.sam_default_port() == 7656
    end

    test "SAM HELLO command" do
      assert I2PController.sam_hello() == "HELLO VERSION MIN=3.1 MAX=3.1\n"
    end

    test "tunnel state atoms" do
      assert I2PController.tunnel_state_init() == :init
      assert I2PController.tunnel_state_setting_up() == :setting_up
      assert I2PController.tunnel_state_active() == :active
      assert I2PController.tunnel_state_failed() == :failed
    end
  end

  # ── I2PController SAM protocol formatting ───────────────────────

  describe "I2PController SAM protocol formatting" do
    test "format_session_create with STREAM style" do
      result = I2PController.format_session_create("STREAM", "test_session", "TRANSIENT")
      assert result == "SESSION CREATE STYLE=STREAM ID=test_session DESTINATION=TRANSIENT\n"
    end

    test "format_session_create with options" do
      result =
        I2PController.format_session_create("STREAM", "sess1", "TRANSIENT",
          inbound_length: 3,
          outbound_length: 3
        )

      assert result ==
               "SESSION CREATE STYLE=STREAM ID=sess1 DESTINATION=TRANSIENT inbound_length=3 outbound_length=3\n"
    end

    test "format_session_create with DATAGRAM style" do
      result = I2PController.format_session_create("DATAGRAM", "dg_session", "TRANSIENT")
      assert result == "SESSION CREATE STYLE=DATAGRAM ID=dg_session DESTINATION=TRANSIENT\n"
    end

    test "format_session_create with private key destination" do
      dest = "abcdef1234567890"
      result = I2PController.format_session_create("STREAM", "s1", dest)
      assert result == "SESSION CREATE STYLE=STREAM ID=s1 DESTINATION=#{dest}\n"
    end

    test "format_stream_connect" do
      result = I2PController.format_stream_connect("sess1", "destination_b32.b32.i2p")

      assert result ==
               "STREAM CONNECT ID=sess1 DESTINATION=destination_b32.b32.i2p SILENT=false\n"
    end

    test "format_stream_accept" do
      result = I2PController.format_stream_accept("sess1")
      assert result == "STREAM ACCEPT ID=sess1 SILENT=false\n"
    end

    test "format_naming_lookup" do
      assert I2PController.format_naming_lookup("ME") == "NAMING LOOKUP NAME=ME\n"
    end

    test "format_naming_lookup with b32 address" do
      addr = "abcdef.b32.i2p"
      assert I2PController.format_naming_lookup(addr) == "NAMING LOOKUP NAME=#{addr}\n"
    end

    test "format_dest_generate" do
      assert I2PController.format_dest_generate() == "DEST GENERATE\n"
    end
  end

  # ── I2PController SAM response parsing ──────────────────────────

  describe "I2PController SAM response parsing" do
    test "parse HELLO REPLY OK" do
      result = I2PController.parse_sam_response("HELLO REPLY RESULT=OK VERSION=3.1\n")
      assert result[:command] == "HELLO REPLY"
      assert result["RESULT"] == "OK"
      assert result["VERSION"] == "3.1"
    end

    test "parse SESSION STATUS with error" do
      result = I2PController.parse_sam_response("SESSION STATUS RESULT=DUPLICATED_ID\n")
      assert result[:command] == "SESSION STATUS"
      assert result["RESULT"] == "DUPLICATED_ID"
    end

    test "parse STREAM STATUS OK" do
      result = I2PController.parse_sam_response("STREAM STATUS RESULT=OK\n")
      assert result[:command] == "STREAM STATUS"
      assert result["RESULT"] == "OK"
    end

    test "parse STREAM STATUS with error" do
      result =
        I2PController.parse_sam_response(
          "STREAM STATUS RESULT=CANT_REACH_PEER MESSAGE=Connection refused\n"
        )

      assert result[:command] == "STREAM STATUS"
      assert result["RESULT"] == "CANT_REACH_PEER"
      assert result["MESSAGE"] == "Connection refused"
    end

    test "parse NAMING REPLY" do
      result =
        I2PController.parse_sam_response("NAMING REPLY RESULT=OK NAME=ME VALUE=base64dest\n")

      assert result[:command] == "NAMING REPLY"
      assert result["RESULT"] == "OK"
      assert result["NAME"] == "ME"
      assert result["VALUE"] == "base64dest"
    end

    test "parse DEST REPLY" do
      result =
        I2PController.parse_sam_response("DEST REPLY PUB=pubkey PRIV=privkey\n")

      assert result[:command] == "DEST REPLY"
      assert result["PUB"] == "pubkey"
      assert result["PRIV"] == "privkey"
    end

    test "parse empty response" do
      result = I2PController.parse_sam_response("")
      assert result[:command] == ""
    end

    test "parse response with no key=value pairs" do
      result = I2PController.parse_sam_response("HELLO REPLY\n")
      assert result[:command] == "HELLO REPLY"
      assert map_size(result) == 1
    end
  end

  # ── I2PController start_link and state ──────────────────────────

  describe "I2PController start_link" do
    setup do
      storagepath = System.tmp_dir!() |> Path.join("rns_test_i2p_#{:rand.uniform(100_000)}")
      File.mkdir_p!(storagepath)
      on_exit(fn -> File.rm_rf!(storagepath) end)
      %{storagepath: storagepath}
    end

    test "starts successfully", %{storagepath: storagepath} do
      {:ok, pid} = I2PController.start_link(storagepath: storagepath)
      assert Process.alive?(pid)

      state = I2PController.get_state(pid)
      assert state.storagepath == storagepath
      assert state.sam_host == "127.0.0.1"
      assert state.sam_port == 7656
      assert state.ready == true

      GenServer.stop(pid)
    end

    test "creates i2p storage directory", %{storagepath: storagepath} do
      {:ok, pid} = I2PController.start_link(storagepath: storagepath)

      assert File.dir?(Path.join(storagepath, "i2p"))

      GenServer.stop(pid)
    end

    test "custom SAM address", %{storagepath: storagepath} do
      {:ok, pid} =
        I2PController.start_link(
          storagepath: storagepath,
          sam_host: "10.0.0.1",
          sam_port: 7700
        )

      assert I2PController.get_sam_address(pid) == {"10.0.0.1", 7700}

      GenServer.stop(pid)
    end

    test "ready? returns true after init", %{storagepath: storagepath} do
      {:ok, pid} = I2PController.start_link(storagepath: storagepath)
      assert I2PController.ready?(pid) == true
      GenServer.stop(pid)
    end

    test "get_free_port returns a valid port" do
      port = I2PController.get_free_port()
      assert is_integer(port)
      assert port > 0
      assert port < 65_536
    end

    test "server_name registration", %{storagepath: storagepath} do
      {:ok, pid} =
        I2PController.start_link(
          storagepath: storagepath,
          server_name: :test_i2p_controller
        )

      assert Process.whereis(:test_i2p_controller) == pid
      GenServer.stop(pid)
    end
  end

  # ── I2PController tunnel registration ───────────────────────────

  describe "I2PController tunnel registration" do
    setup do
      storagepath = System.tmp_dir!() |> Path.join("rns_test_i2p_#{:rand.uniform(100_000)}")
      File.mkdir_p!(storagepath)

      {:ok, pid} = I2PController.start_link(storagepath: storagepath)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(storagepath)
      end)

      %{controller: pid, storagepath: storagepath}
    end

    test "register client tunnel", %{controller: pid} do
      dest = "abcdef1234.b32.i2p"
      assert :ok == I2PController.register_client_tunnel(pid, dest)

      state = I2PController.get_state(pid)
      assert Map.has_key?(state.client_tunnels, dest)
      assert state.client_tunnels[dest] == false
    end

    test "register server tunnel", %{controller: pid} do
      b32 = "xyz789.b32.i2p"
      assert :ok == I2PController.register_server_tunnel(pid, b32)

      state = I2PController.get_state(pid)
      assert Map.has_key?(state.server_tunnels, b32)
      assert state.server_tunnels[b32] == false
    end

    test "get tunnel status for registered tunnel", %{controller: pid} do
      dest = "testdest.b32.i2p"
      I2PController.register_client_tunnel(pid, dest)

      status = I2PController.get_tunnel_status(pid, dest)
      assert status != nil
      assert status.state == :init
      assert status.destination == dest
    end

    test "get tunnel status for unregistered tunnel", %{controller: pid} do
      assert I2PController.get_tunnel_status(pid, "nonexistent") == nil
    end

    test "stop_controller stops the process", %{controller: pid} do
      assert Process.alive?(pid)
      I2PController.stop_controller(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  # ── I2PController keyfile path computation ──────────────────────

  describe "I2PController keyfile path computation" do
    test "compute_i2p_keyfile_path old format (no identity hash)" do
      path = I2PController.compute_i2p_keyfile_path("/tmp/rns", "TestInterface")

      assert String.starts_with?(path, "/tmp/rns/i2p/")
      assert String.ends_with?(path, ".i2p")

      # The hex part should be 64 chars (SHA-256 = 32 bytes = 64 hex chars)
      filename = Path.basename(path, ".i2p")
      assert byte_size(filename) == 64
    end

    test "compute_i2p_keyfile_path new format (with identity hash)" do
      identity_hash = :crypto.strong_rand_bytes(32)
      path = I2PController.compute_i2p_keyfile_path("/tmp/rns", "TestInterface", identity_hash)

      assert String.starts_with?(path, "/tmp/rns/i2p/")
      assert String.ends_with?(path, ".i2p")
    end

    test "different names produce different paths" do
      path1 = I2PController.compute_i2p_keyfile_path("/tmp/rns", "Interface1")
      path2 = I2PController.compute_i2p_keyfile_path("/tmp/rns", "Interface2")

      assert path1 != path2
    end

    test "same name with different identity hashes produce different paths" do
      hash1 = :crypto.strong_rand_bytes(32)
      hash2 = :crypto.strong_rand_bytes(32)

      path1 = I2PController.compute_i2p_keyfile_path("/tmp/rns", "Test", hash1)
      path2 = I2PController.compute_i2p_keyfile_path("/tmp/rns", "Test", hash2)

      assert path1 != path2
    end
  end

  # ── I2PInterface start_link ─────────────────────────────────────

  describe "I2PInterface start_link" do
    test "starts with skip_i2p for testing" do
      {:ok, pid} =
        I2PInterface.start_link(
          name: "TestI2P",
          skip_i2p: true,
          bind_port: 0
        )

      state = I2PInterface.get_state(pid)
      assert state.name == "TestI2P"
      assert state.online == true
      assert state.i2p_tunneled == true
      assert state.in == true
      assert state.receives == true
      assert state.bitrate == 256_000
      assert state.hw_mtu == 1064
      assert state.i2p_controller == nil

      I2PInterface.stop(pid)
    end

    test "hash is computed" do
      {:ok, pid} =
        I2PInterface.start_link(
          name: "TestI2PHash",
          skip_i2p: true,
          bind_port: 0
        )

      state = I2PInterface.get_state(pid)
      assert state.hash != nil
      assert is_binary(state.hash)
      assert byte_size(state.hash) == 32

      I2PInterface.stop(pid)
    end

    test "server_name registration" do
      {:ok, pid} =
        I2PInterface.start_link(
          name: "RegI2P",
          skip_i2p: true,
          bind_port: 0,
          server_name: :test_i2p_server_iface
        )

      assert Process.whereis(:test_i2p_server_iface) == pid
      I2PInterface.stop(pid)
    end

    test "client_count starts at 0" do
      {:ok, pid} =
        I2PInterface.start_link(
          name: "CountI2P",
          skip_i2p: true,
          bind_port: 0
        )

      assert I2PInterface.client_count(pid) == 0
      I2PInterface.stop(pid)
    end

    test "IFAC config is stored" do
      {:ok, pid} =
        I2PInterface.start_link(
          name: "IfacI2P",
          skip_i2p: true,
          bind_port: 0,
          ifac_netname: "testnet",
          ifac_netkey: "testkey"
        )

      state = I2PInterface.get_state(pid)
      assert state.ifac_netname == "testnet"
      assert state.ifac_netkey == "testkey"

      I2PInterface.stop(pid)
    end
  end

  # ── I2PInterface detach ─────────────────────────────────────────

  describe "I2PInterface detach" do
    test "stop closes interface" do
      {:ok, pid} =
        I2PInterface.start_link(
          name: "DetachI2P",
          skip_i2p: true,
          bind_port: 0
        )

      assert :ok == I2PInterface.stop(pid)
      state = I2PInterface.get_state(pid)
      assert state.online == false
      assert state.detached == true
      assert state.listen_socket == nil
    end
  end

  # ── I2PInterface announce tracking ──────────────────────────────

  describe "I2PInterface announce tracking" do
    test "received_announce from spawned" do
      state = %I2PInterface{ia_freq_deque: []}
      updated = I2PInterface.received_announce(state, true)
      assert length(updated.ia_freq_deque) == 1
    end

    test "received_announce not from spawned" do
      state = %I2PInterface{ia_freq_deque: []}
      updated = I2PInterface.received_announce(state, false)
      assert updated.ia_freq_deque == []
    end

    test "sent_announce from spawned" do
      state = %I2PInterface{oa_freq_deque: []}
      updated = I2PInterface.sent_announce(state, true)
      assert length(updated.oa_freq_deque) == 1
    end

    test "sent_announce not from spawned" do
      state = %I2PInterface{oa_freq_deque: []}
      updated = I2PInterface.sent_announce(state, false)
      assert updated.oa_freq_deque == []
    end
  end

  # ── I2PInterfacePeer client/server connection ───────────────────

  describe "I2PInterfacePeer client/server over localhost" do
    setup do
      # Start a simple TCP server
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      %{listen_socket: listen, port: port}
    end

    test "connect and exchange data", %{listen_socket: listen, port: port} do
      test_pid = self()

      # Start peer in initiator mode pointing at our test server
      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "TestPeer",
          owner: test_pid,
          target_i2p_dest: nil,
          connected_socket: nil
        )

      # The peer won't connect without a target - test pre-connected socket mode instead
      I2PInterfacePeer.stop(peer)

      # Accept a TCP connection
      Task.async(fn ->
        {:ok, client_socket} = :gen_tcp.accept(listen, 2000)

        :gen_tcp.send(
          client_socket,
          HDLC.frame(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20>>)
        )

        Process.sleep(100)
        :gen_tcp.close(client_socket)
      end)

      # Connect and wrap
      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "PeerConn",
          owner: test_pid,
          connected_socket: client_socket
        )

      # Should receive data
      assert_receive {:i2p_interface_data, data, _iface}, 2000
      assert byte_size(data) == 20

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end

    test "send data through peer", %{listen_socket: listen, port: port} do
      test_pid = self()

      acceptor =
        Task.async(fn ->
          {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
          :inet.setopts(server_socket, [:binary, active: false])
          {:ok, data} = :gen_tcp.recv(server_socket, 0, 2000)
          :gen_tcp.close(server_socket)
          data
        end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "PeerSend",
          owner: test_pid,
          connected_socket: client_socket
        )

      # Wait for socket activation
      Process.sleep(50)

      payload = :crypto.strong_rand_bytes(50)
      assert :ok == I2PInterfacePeer.send_data(peer, payload)

      # Server should receive HDLC-framed data
      raw = Task.await(acceptor, 2000)
      {frames, _} = HDLC.deframe(raw)
      assert frames != []
      assert hd(frames) == payload

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer pre-connected socket ───────────────────────

  describe "I2PInterfacePeer pre-connected socket" do
    test "wraps connected socket in responder mode" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      Task.async(fn ->
        {:ok, _server_socket} = :gen_tcp.accept(listen, 2000)
        Process.sleep(200)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "Responder",
          owner: self(),
          connected_socket: client_socket
        )

      state = I2PInterfacePeer.get_state(peer)
      assert state.online == true
      assert state.never_connected == false
      assert state.initiator == false
      assert state.i2p_tunneled == true
      assert state.i2p_tunnel_state == I2PInterfacePeer.tunnel_state_active()

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer detach ─────────────────────────────────────

  describe "I2PInterfacePeer detach" do
    test "closes socket and marks offline" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      Task.async(fn ->
        {:ok, _} = :gen_tcp.accept(listen, 2000)
        Process.sleep(200)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "DetachPeer",
          owner: self(),
          connected_socket: client_socket
        )

      assert :ok == I2PInterfacePeer.stop(peer)
      state = I2PInterfacePeer.get_state(peer)
      assert state.online == false
      assert state.detached == true
      assert state.socket == nil

      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer HDLC framing ──────────────────────────────

  describe "I2PInterfacePeer HDLC framing" do
    setup do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      %{listen_socket: listen, port: port}
    end

    test "frames with HDLC special bytes", %{listen_socket: listen, port: port} do
      test_pid = self()

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        # Send data with HDLC special bytes
        data = <<0x7E, 0x7D, 0xFF, 0x00>> <> :binary.copy(<<0xAA>>, 16)
        :gen_tcp.send(server_socket, HDLC.frame(data))
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "HdlcPeer",
          owner: test_pid,
          connected_socket: client_socket
        )

      assert_receive {:i2p_interface_data, data, _}, 2000
      assert data == <<0x7E, 0x7D, 0xFF, 0x00>> <> :binary.copy(<<0xAA>>, 16)

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end

    test "filters frames below HEADER_MINSIZE", %{listen_socket: listen, port: port} do
      test_pid = self()

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        # Send a frame that's too small (< 19 bytes)
        :gen_tcp.send(server_socket, HDLC.frame(<<1, 2, 3>>))
        # Then send a valid-sized frame
        big_data = :binary.copy(<<0xAB>>, 20)
        :gen_tcp.send(server_socket, HDLC.frame(big_data))
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "FilterPeer",
          owner: test_pid,
          connected_socket: client_socket
        )

      # Should only receive the valid-sized frame
      assert_receive {:i2p_interface_data, data, _}, 2000
      assert data == :binary.copy(<<0xAB>>, 20)

      # Should NOT receive the small frame
      refute_receive {:i2p_interface_data, _, _}, 200

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end

    test "handles fragmented delivery", %{listen_socket: listen, port: port} do
      test_pid = self()

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        framed = HDLC.frame(:binary.copy(<<0xCC>>, 20))
        # Split frame into fragments
        <<part1::binary-size(5), part2::binary>> = framed
        :gen_tcp.send(server_socket, part1)
        Process.sleep(50)
        :gen_tcp.send(server_socket, part2)
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "FragPeer",
          owner: test_pid,
          connected_socket: client_socket
        )

      assert_receive {:i2p_interface_data, data, _}, 2000
      assert data == :binary.copy(<<0xCC>>, 20)

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end

    test "handles multiple frames in one delivery", %{listen_socket: listen, port: port} do
      test_pid = self()

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        data1 = :binary.copy(<<0x11>>, 20)
        data2 = :binary.copy(<<0x22>>, 20)
        :gen_tcp.send(server_socket, HDLC.frame(data1) <> HDLC.frame(data2))
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "MultiPeer",
          owner: test_pid,
          connected_socket: client_socket
        )

      assert_receive {:i2p_interface_data, data1, _}, 2000
      assert_receive {:i2p_interface_data, data2, _}, 2000
      assert data1 == :binary.copy(<<0x11>>, 20)
      assert data2 == :binary.copy(<<0x22>>, 20)

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer KISS framing ───────────────────────────────

  describe "I2PInterfacePeer KISS framing" do
    test "uses KISS framing when configured" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      test_pid = self()

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        data = :binary.copy(<<0xDD>>, 20)
        :gen_tcp.send(server_socket, KISS.frame(data))
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "KissPeer",
          owner: test_pid,
          connected_socket: client_socket,
          kiss_framing: true
        )

      assert_receive {:i2p_interface_data, data, _}, 2000
      assert data == :binary.copy(<<0xDD>>, 20)

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer socket closure detection ───────────────────

  describe "I2PInterfacePeer socket closure" do
    test "non-initiator tears down on socket close" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "ClosePeer",
          owner: self(),
          connected_socket: client_socket
        )

      Process.sleep(200)
      state = I2PInterfacePeer.get_state(peer)
      assert state.online == false

      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer owner callback ─────────────────────────────

  describe "I2PInterfacePeer owner callback" do
    test "function callback receives data" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      test_pid = self()

      owner_fn = fn data, _iface ->
        send(test_pid, {:fn_callback, data})
      end

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        payload = :binary.copy(<<0xEE>>, 20)
        :gen_tcp.send(server_socket, HDLC.frame(payload))
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "FnPeer",
          owner: owner_fn,
          connected_socket: client_socket
        )

      assert_receive {:fn_callback, data}, 2000
      assert data == :binary.copy(<<0xEE>>, 20)

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer byte counters ──────────────────────────────

  describe "I2PInterfacePeer byte counters" do
    test "tracks rxb and txb" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      test_pid = self()

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        :inet.setopts(server_socket, [:binary, active: false])
        # Send data to peer
        payload = :binary.copy(<<0xBB>>, 20)
        :gen_tcp.send(server_socket, HDLC.frame(payload))
        # Receive data from peer
        {:ok, _} = :gen_tcp.recv(server_socket, 0, 2000)
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "CountPeer",
          owner: test_pid,
          connected_socket: client_socket
        )

      # Wait for incoming data
      assert_receive {:i2p_interface_data, _, _}, 2000

      # Send some data
      I2PInterfacePeer.send_data(peer, :binary.copy(<<0xCC>>, 20))

      Process.sleep(100)
      state = I2PInterfacePeer.get_state(peer)
      assert state.rxb > 0
      assert state.txb > 0

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end
  end

  # ── I2PInterfacePeer parent rxb tracking ────────────────────────

  describe "I2PInterfacePeer parent rxb tracking" do
    test "sends rxb update to parent interface" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      test_pid = self()

      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listen, 2000)
        payload = :binary.copy(<<0xAA>>, 20)
        :gen_tcp.send(server_socket, HDLC.frame(payload))
        Process.sleep(100)
        :gen_tcp.close(server_socket)
      end)

      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

      {:ok, peer} =
        I2PInterfacePeer.start_link(
          name: "ParentTrack",
          owner: test_pid,
          connected_socket: client_socket,
          parent_interface: test_pid
        )

      # Should receive parent rxb update message
      assert_receive {:update_rxb, bytes}, 2000
      assert bytes == 20

      I2PInterfacePeer.stop(peer)
      :gen_tcp.close(listen)
    end
  end

  # ── String.Chars protocol ───────────────────────────────────────

  describe "String.Chars protocol" do
    test "I2PInterface formats as I2PInterface[name]" do
      iface = %I2PInterface{name: "TestI2P"}
      assert to_string(iface) == "I2PInterface[TestI2P]"
    end

    test "I2PInterfacePeer formats as I2PInterfacePeer[name]" do
      iface = %I2PInterfacePeer{name: "PeerTest"}
      assert to_string(iface) == "I2PInterfacePeer[PeerTest]"
    end
  end

  # ── Interface behaviour ─────────────────────────────────────────

  describe "Interface behaviour" do
    test "I2PInterface implements Interface behaviour" do
      behaviours =
        I2PInterface.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "I2PInterfacePeer implements Interface behaviour" do
      behaviours =
        I2PInterfacePeer.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "I2PInterface process_outgoing is no-op" do
      state = %I2PInterface{}
      assert {:ok, ^state} = I2PInterface.process_outgoing(state, <<1, 2, 3>>)
    end
  end

  # ── Watchdog ────────────────────────────────────────────────────

  describe "I2PInterfacePeer watchdog" do
    test "detects stale tunnel" do
      now = System.system_time(:second)

      state = %I2PInterfacePeer{
        online: true,
        last_read: now - 25,
        last_write: now,
        i2p_tunnel_state: I2PInterfacePeer.tunnel_state_active()
      }

      updated = I2PInterfacePeer.run_watchdog(state)
      # 25 > I2P_PROBE_AFTER * 2 = 20
      assert updated.i2p_tunnel_state == I2PInterfacePeer.tunnel_state_stale()
    end

    test "tunnel stays active with recent reads" do
      now = System.system_time(:second)

      state = %I2PInterfacePeer{
        online: true,
        last_read: now - 5,
        last_write: now,
        i2p_tunnel_state: I2PInterfacePeer.tunnel_state_init()
      }

      updated = I2PInterfacePeer.run_watchdog(state)
      assert updated.i2p_tunnel_state == I2PInterfacePeer.tunnel_state_active()
    end

    test "triggers read timeout on unresponsive socket" do
      now = System.system_time(:second)

      state = %I2PInterfacePeer{
        online: true,
        last_read: now - 120,
        last_write: now,
        socket: nil,
        initiator: false,
        detached: false
      }

      updated = I2PInterfacePeer.run_watchdog(state)
      # 120 > I2P_READ_TIMEOUT = 110
      assert updated.online == false
    end
  end
end
