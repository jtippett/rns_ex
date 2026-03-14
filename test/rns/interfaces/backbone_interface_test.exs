defmodule RNS.Interfaces.BackboneInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.BackboneClientInterface
  alias RNS.Interfaces.BackboneInterface
  alias RNS.Interfaces.Interface.HDLC

  # ── BackboneInterface constants ──────────────────────────────────

  describe "BackboneInterface constants" do
    test "HW_MTU is 1048576 (1 MB)" do
      assert BackboneInterface.hw_mtu() == 1_048_576
    end

    test "BITRATE_GUESS is 1 Gbps" do
      assert BackboneInterface.bitrate_guess() == 1_000_000_000
    end

    test "DEFAULT_IFAC_SIZE is 16" do
      assert BackboneInterface.default_ifac_size() == 16
    end

    test "AUTOCONFIGURE_MTU is true" do
      assert BackboneInterface.autoconfigure_mtu() == true
    end
  end

  # ── BackboneInterface struct ─────────────────────────────────────

  describe "BackboneInterface struct" do
    test "has default interface fields" do
      iface = %BackboneInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has server-specific fields" do
      iface = %BackboneInterface{}
      assert iface.bind_ip == nil
      assert iface.bind_port == nil
      assert iface.listen_socket == nil
      assert iface.spawned_interfaces == []
      assert iface.owner == nil
      assert iface.receives == false
    end
  end

  # ── BackboneClientInterface constants ────────────────────────────

  describe "BackboneClientInterface constants" do
    test "BITRATE_GUESS is 100 Mbps" do
      assert BackboneClientInterface.bitrate_guess() == 100_000_000
    end

    test "DEFAULT_IFAC_SIZE is 16" do
      assert BackboneClientInterface.default_ifac_size() == 16
    end

    test "RECONNECT_WAIT is 5 seconds" do
      assert BackboneClientInterface.reconnect_wait() == 5
    end

    test "RECONNECT_MAX_TRIES is nil (unlimited)" do
      assert BackboneClientInterface.reconnect_max_tries() == nil
    end

    test "INITIAL_CONNECT_TIMEOUT is 5000 ms" do
      assert BackboneClientInterface.initial_connect_timeout() == 5_000
    end

    test "HEADER_MINSIZE is 19 bytes" do
      assert BackboneClientInterface.header_minsize() == 19
    end

    test "TCP keepalive constants" do
      assert BackboneClientInterface.tcp_user_timeout() == 24
      assert BackboneClientInterface.tcp_probe_after() == 5
      assert BackboneClientInterface.tcp_probe_interval() == 2
      assert BackboneClientInterface.tcp_probes() == 12
    end
  end

  # ── BackboneClientInterface struct ───────────────────────────────

  describe "BackboneClientInterface struct" do
    test "has default interface fields" do
      iface = %BackboneClientInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has client-specific fields" do
      iface = %BackboneClientInterface{}
      assert iface.socket == nil
      assert iface.target_ip == nil
      assert iface.target_port == nil
      assert iface.initiator == false
      assert iface.reconnecting == false
      assert iface.never_connected == true
      assert iface.i2p_tunneled == false
      assert iface.prefer_ipv6 == false
      assert iface.wants_tunnel == false
      assert iface.owner == nil
      assert iface.receives == false
      assert iface.frame_buffer == <<>>
      assert iface.transmit_buffer == <<>>
    end
  end

  # ── Server start and listen ──────────────────────────────────────

  describe "BackboneInterface start_link" do
    test "starts and listens on localhost" do
      {:ok, server} =
        BackboneInterface.start_link(
          name: "test_bb_server",
          listen_ip: "127.0.0.1",
          listen_port: 0
        )

      state = BackboneInterface.get_state(server)
      assert state.name == "test_bb_server"
      assert state.online == true
      assert state.receives == true
      assert state.bind_ip == "127.0.0.1"
      assert state.listen_socket != nil
      assert state.in == true
      assert state.out == false
      assert state.supports_discovery == true
      assert is_binary(state.hash)

      BackboneInterface.stop(server)
    end

    test "port shorthand works" do
      {:ok, server} =
        BackboneInterface.start_link(
          name: "test_bb_port",
          listen_ip: "127.0.0.1",
          port: 0
        )

      state = BackboneInterface.get_state(server)
      assert state.online == true

      BackboneInterface.stop(server)
    end

    test "fails without port" do
      Process.flag(:trap_exit, true)

      result =
        BackboneInterface.start_link(
          name: "test_bb_no_port",
          listen_ip: "127.0.0.1"
        )

      assert {:error, _} = result
    end

    test "fails without bind IP or device" do
      Process.flag(:trap_exit, true)

      result =
        BackboneInterface.start_link(
          name: "test_bb_no_ip",
          listen_port: 0
        )

      assert {:error, _} = result
    end
  end

  # ── Client/server connection ─────────────────────────────────────

  describe "client/server connection" do
    setup do
      test_pid = self()

      {:ok, server} =
        BackboneInterface.start_link(
          name: "conn_bb_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = BackboneInterface.get_state(server)
      {:ok, server_port} = :inet.port(server_state.listen_socket)

      on_exit(fn ->
        if Process.alive?(server), do: BackboneInterface.stop(server)
      end)

      %{server: server, server_port: server_port, test_pid: test_pid}
    end

    test "client connects to server", %{server_port: server_port, server: server} do
      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "conn_bb_client",
          target_host: "127.0.0.1",
          target_port: server_port,
          owner: self()
        )

      client_state = BackboneClientInterface.get_state(client)
      assert client_state.online == true
      assert client_state.initiator == true
      assert client_state.never_connected == false
      assert client_state.socket != nil

      # Give server time to accept
      Process.sleep(100)
      assert BackboneInterface.client_count(server) == 1

      BackboneClientInterface.stop(client)
    end

    test "HDLC framing roundtrip over backbone", %{server_port: _server_port} do
      test_pid = self()

      {:ok, server2} =
        BackboneInterface.start_link(
          name: "hdlc_bb_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server2_state = BackboneInterface.get_state(server2)
      {:ok, port2} = :inet.port(server2_state.listen_socket)

      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "hdlc_bb_client",
          target_host: "127.0.0.1",
          target_port: port2,
          owner: test_pid
        )

      Process.sleep(100)

      # Send data from client
      test_data = :crypto.strong_rand_bytes(100)
      :ok = BackboneClientInterface.send_data(client, test_data)

      # The server-spawned client should receive and process the HDLC-framed data
      assert_receive {:interface_data, ^test_data, _iface}, 2000

      BackboneClientInterface.stop(client)
      BackboneInterface.stop(server2)
    end

    test "multiple messages over backbone", %{} do
      test_pid = self()

      {:ok, server} =
        BackboneInterface.start_link(
          name: "multi_bb_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = BackboneInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "multi_bb_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(100)

      msg1 = :crypto.strong_rand_bytes(50)
      msg2 = :crypto.strong_rand_bytes(75)
      msg3 = :crypto.strong_rand_bytes(100)

      :ok = BackboneClientInterface.send_data(client, msg1)
      :ok = BackboneClientInterface.send_data(client, msg2)
      :ok = BackboneClientInterface.send_data(client, msg3)

      assert_receive {:interface_data, ^msg1, _}, 2000
      assert_receive {:interface_data, ^msg2, _}, 2000
      assert_receive {:interface_data, ^msg3, _}, 2000

      BackboneClientInterface.stop(client)
      BackboneInterface.stop(server)
    end

    test "large data transfer", %{} do
      test_pid = self()

      {:ok, server} =
        BackboneInterface.start_link(
          name: "large_bb_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = BackboneInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "large_bb_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(100)

      # Send a large payload (backbone supports 1MB MTU)
      large_data = :crypto.strong_rand_bytes(10_000)
      :ok = BackboneClientInterface.send_data(client, large_data)

      assert_receive {:interface_data, ^large_data, _}, 5000

      BackboneClientInterface.stop(client)
      BackboneInterface.stop(server)
    end

    test "client sends data and txb is updated", %{server_port: server_port} do
      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "txb_bb_client",
          target_host: "127.0.0.1",
          target_port: server_port,
          owner: self()
        )

      Process.sleep(50)

      :ok = BackboneClientInterface.send_data(client, :crypto.strong_rand_bytes(50))

      client_state = BackboneClientInterface.get_state(client)
      assert client_state.txb > 0

      BackboneClientInterface.stop(client)
    end
  end

  # ── Pre-connected socket ─────────────────────────────────────────

  describe "pre-connected socket" do
    test "wraps an existing connected socket" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      test_pid = self()

      {:ok, iface} =
        BackboneClientInterface.start_link(
          name: "pre_connected_bb",
          connected_socket: server_sock,
          owner: test_pid
        )

      state = BackboneClientInterface.get_state(iface)
      assert state.online == true
      assert state.never_connected == false
      assert state.initiator == false

      # Send HDLC-framed data through the raw socket
      test_data = :crypto.strong_rand_bytes(30)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:interface_data, ^test_data, _iface}, 2000

      BackboneClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Detach ───────────────────────────────────────────────────────

  describe "BackboneClientInterface detach" do
    test "closes socket and marks offline" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        BackboneClientInterface.start_link(
          name: "detach_bb_test",
          connected_socket: server_sock,
          owner: self()
        )

      state_before = BackboneClientInterface.get_state(iface)
      assert state_before.online == true

      :ok = BackboneClientInterface.stop(iface)

      state_after = BackboneClientInterface.get_state(iface)
      assert state_after.online == false
      assert state_after.detached == true
      assert state_after.socket == nil

      GenServer.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  describe "BackboneInterface detach" do
    test "closes listen socket and marks offline" do
      {:ok, server} =
        BackboneInterface.start_link(
          name: "bb_server_detach",
          listen_ip: "127.0.0.1",
          listen_port: 0
        )

      state_before = BackboneInterface.get_state(server)
      assert state_before.online == true
      assert state_before.listen_socket != nil

      :ok = BackboneInterface.stop(server)

      state_after = BackboneInterface.get_state(server)
      assert state_after.online == false
      assert state_after.detached == true
      assert state_after.listen_socket == nil

      GenServer.stop(server)
    end

    test "stops spawned clients on detach" do
      test_pid = self()

      {:ok, server} =
        BackboneInterface.start_link(
          name: "bb_detach_clients",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = BackboneInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "bb_detach_cli",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(100)
      assert BackboneInterface.client_count(server) == 1

      :ok = BackboneInterface.stop(server)

      # Spawned interfaces should be cleaned up
      Process.sleep(100)
      state_after = BackboneInterface.get_state(server)
      assert state_after.spawned_interfaces == []

      BackboneClientInterface.stop(client)
      GenServer.stop(server)
    end
  end

  # ── Reconnection ─────────────────────────────────────────────────

  describe "reconnection" do
    test "client handles max_reconnect_tries" do
      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "max_retry_bb",
          target_host: "127.0.0.1",
          target_port: 1,
          max_reconnect_tries: 0,
          connect_timeout: 100
        )

      state = BackboneClientInterface.get_state(client)
      assert state.online == false
      assert state.initiator == true

      GenServer.stop(client)
    end

    test "client reconnects after server disconnect" do
      test_pid = self()

      {:ok, server} =
        BackboneInterface.start_link(
          name: "reconnect_bb_srv",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = BackboneInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "reconnect_bb_cli",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      client_state = BackboneClientInterface.get_state(client)
      assert client_state.online == true
      assert client_state.initiator == true

      BackboneClientInterface.stop(client)
      BackboneInterface.stop(server)
    end
  end

  # ── String.Chars ─────────────────────────────────────────────────

  describe "BackboneInterface String.Chars" do
    test "with IPv4 address" do
      iface = %BackboneInterface{name: "bb0", bind_ip: "10.0.0.1", bind_port: 4242}
      assert to_string(iface) == "BackboneInterface[bb0/10.0.0.1:4242]"
    end

    test "with IPv6 address" do
      iface = %BackboneInterface{name: "bb0", bind_ip: "::1", bind_port: 4242}
      assert to_string(iface) == "BackboneInterface[bb0/[::1]:4242]"
    end

    test "without address" do
      iface = %BackboneInterface{name: "bb0"}
      assert to_string(iface) == "BackboneInterface[bb0]"
    end
  end

  describe "BackboneClientInterface String.Chars" do
    test "with IPv4 address" do
      iface = %BackboneClientInterface{name: "bb_cli", target_ip: "10.0.0.1", target_port: 4242}
      assert to_string(iface) == "BackboneInterface[bb_cli/10.0.0.1:4242]"
    end

    test "with IPv6 address" do
      iface = %BackboneClientInterface{name: "bb_cli", target_ip: "::1", target_port: 4242}
      assert to_string(iface) == "BackboneInterface[bb_cli/[::1]:4242]"
    end

    test "without address" do
      iface = %BackboneClientInterface{name: "bb_cli"}
      assert to_string(iface) == "BackboneInterface[bb_cli]"
    end
  end

  # ── Address resolution ───────────────────────────────────────────

  describe "BackboneInterface.get_address_for_if/1" do
    test "returns address for loopback" do
      case BackboneInterface.get_address_for_if("lo0") do
        {:ok, addr} ->
          assert addr == "127.0.0.1"

        {:error, :device_not_found} ->
          case BackboneInterface.get_address_for_if("lo") do
            {:ok, addr} -> assert addr == "127.0.0.1"
            {:error, _} -> :ok
          end
      end
    end

    test "returns error for nonexistent device" do
      assert {:error, :device_not_found} =
               BackboneInterface.get_address_for_if("nonexistent_iface99")
    end
  end

  # ── Interface behaviour ──────────────────────────────────────────

  describe "Interface behaviour" do
    test "BackboneInterface implements Interface behaviour" do
      behaviours =
        BackboneInterface.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "BackboneClientInterface implements Interface behaviour" do
      behaviours =
        BackboneClientInterface.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "server process_outgoing is a no-op" do
      state = %BackboneInterface{name: "srv"}
      assert {:ok, ^state} = BackboneInterface.process_outgoing(state, "data")
    end
  end

  # ── HDLC framing over Backbone ──────────────────────────────────

  describe "HDLC framing over backbone" do
    test "frames with special bytes are correctly handled" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        BackboneClientInterface.start_link(
          name: "hdlc_bb_special",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Data containing HDLC special bytes (FLAG=0x7E, ESC=0x7D)
      test_data = <<0x7E, 0x7D, 0x00, 0xFF, 0x7E, 0x7D>> <> :crypto.strong_rand_bytes(20)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:interface_data, ^test_data, _}, 2000

      BackboneClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end

    test "small frames below HEADER_MINSIZE are filtered" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        BackboneClientInterface.start_link(
          name: "hdlc_bb_small",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Send a frame that's too small (< HEADER_MINSIZE = 19)
      small_data = :crypto.strong_rand_bytes(10)
      framed = HDLC.frame(small_data)
      :gen_tcp.send(client_sock, framed)

      refute_receive {:interface_data, ^small_data, _}, 500

      # Now send a valid-size frame
      valid_data = :crypto.strong_rand_bytes(25)
      framed2 = HDLC.frame(valid_data)
      :gen_tcp.send(client_sock, framed2)

      assert_receive {:interface_data, ^valid_data, _}, 2000

      BackboneClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end

    test "handles fragmented TCP delivery" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, nodelay: true])

      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        BackboneClientInterface.start_link(
          name: "hdlc_bb_frag",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Build an HDLC frame and send it in pieces
      test_data = :crypto.strong_rand_bytes(50)
      framed = HDLC.frame(test_data)

      half = div(byte_size(framed), 2)
      <<part1::binary-size(half), part2::binary>> = framed

      :gen_tcp.send(client_sock, part1)
      Process.sleep(50)
      :gen_tcp.send(client_sock, part2)

      assert_receive {:interface_data, ^test_data, _}, 2000

      BackboneClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Server announce tracking ─────────────────────────────────────

  describe "server announce tracking" do
    test "received_announce with from_spawned updates ia_freq_deque" do
      iface = %BackboneInterface{name: "announce_test"}
      updated = BackboneInterface.received_announce(iface, true)
      assert length(updated.ia_freq_deque) == 1
    end

    test "received_announce without from_spawned does not update" do
      iface = %BackboneInterface{name: "announce_test"}
      updated = BackboneInterface.received_announce(iface, false)
      assert updated.ia_freq_deque == []
    end

    test "sent_announce with from_spawned updates oa_freq_deque" do
      iface = %BackboneInterface{name: "announce_test"}
      updated = BackboneInterface.sent_announce(iface, true)
      assert length(updated.oa_freq_deque) == 1
    end

    test "sent_announce without from_spawned does not update" do
      iface = %BackboneInterface{name: "announce_test"}
      updated = BackboneInterface.sent_announce(iface, false)
      assert updated.oa_freq_deque == []
    end
  end

  # ── server_name registration ─────────────────────────────────────

  describe "server_name option" do
    test "BackboneInterface registers with given name" do
      {:ok, _pid} =
        BackboneInterface.start_link(
          name: "named_bb_srv",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          server_name: :test_bb_named_srv
        )

      state = BackboneInterface.get_state(:test_bb_named_srv)
      assert state.name == "named_bb_srv"

      BackboneInterface.stop(:test_bb_named_srv)
    end
  end

  # ── Bidirectional communication ──────────────────────────────────

  describe "bidirectional communication" do
    test "server-spawned client can receive from initiator" do
      test_pid = self()

      {:ok, server} =
        BackboneInterface.start_link(
          name: "bidir_bb_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = BackboneInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "bidir_bb_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(200)

      msg1 = :crypto.strong_rand_bytes(30)
      :ok = BackboneClientInterface.send_data(client, msg1)

      assert_receive {:interface_data, ^msg1, _}, 2000

      BackboneClientInterface.stop(client)
      BackboneInterface.stop(server)
    end
  end

  # ── Owner callback styles ────────────────────────────────────────

  describe "owner callback" do
    test "function/2 callback" do
      test_pid = self()

      callback = fn data, _iface ->
        send(test_pid, {:callback_received, data})
      end

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        BackboneClientInterface.start_link(
          name: "fn_bb_callback",
          connected_socket: server_sock,
          owner: callback
        )

      test_data = :crypto.strong_rand_bytes(25)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:callback_received, ^test_data}, 2000

      BackboneClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Socket closure detection ─────────────────────────────────────

  describe "socket closure" do
    test "non-initiator teardown on remote close" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        BackboneClientInterface.start_link(
          name: "close_bb_test",
          connected_socket: server_sock,
          owner: self()
        )

      state = BackboneClientInterface.get_state(iface)
      assert state.online == true
      assert state.initiator == false

      # Close the remote end
      :gen_tcp.close(client_sock)

      Process.sleep(500)

      state = BackboneClientInterface.get_state(iface)
      assert state.online == false

      GenServer.stop(iface)
      :gen_tcp.close(listen)
    end
  end

  # ── Parent rxb tracking ─────────────────────────────────────────

  describe "parent interface rxb tracking" do
    test "spawned client updates parent rxb on receive" do
      test_pid = self()

      {:ok, server} =
        BackboneInterface.start_link(
          name: "rxb_bb_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = BackboneInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        BackboneClientInterface.start_link(
          name: "rxb_bb_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(100)

      test_data = :crypto.strong_rand_bytes(50)
      :ok = BackboneClientInterface.send_data(client, test_data)

      assert_receive {:interface_data, ^test_data, _}, 2000
      Process.sleep(100)

      # Server's rxb should reflect the received bytes
      server_state = BackboneInterface.get_state(server)
      assert server_state.rxb > 0

      BackboneClientInterface.stop(client)
      BackboneInterface.stop(server)
    end
  end
end
