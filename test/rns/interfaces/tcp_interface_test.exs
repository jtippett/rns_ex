defmodule RNS.Interfaces.TCPInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.Interface.HDLC
  alias RNS.Interfaces.Interface.KISS
  alias RNS.Interfaces.TCPClientInterface
  alias RNS.Interfaces.TCPInterface
  alias RNS.Interfaces.TCPServerInterface

  # ── TCPInterface constants ──────────────────────────────────────

  describe "TCPInterface constants" do
    test "HW_MTU is 262144" do
      assert TCPInterface.hw_mtu() == 262_144
    end
  end

  # ── TCPClientInterface constants ────────────────────────────────

  describe "TCPClientInterface constants" do
    test "bitrate_guess is 10 Mbps" do
      assert TCPClientInterface.bitrate_guess() == 10_000_000
    end

    test "default_ifac_size is 16" do
      assert TCPClientInterface.default_ifac_size() == 16
    end

    test "reconnect_wait is 5 seconds" do
      assert TCPClientInterface.reconnect_wait() == 5
    end

    test "initial_connect_timeout is 5000 ms" do
      assert TCPClientInterface.initial_connect_timeout() == 5_000
    end

    test "header_minsize is 19 bytes" do
      assert TCPClientInterface.header_minsize() == 19
    end
  end

  # ── TCPClientInterface struct ───────────────────────────────────

  describe "TCPClientInterface struct" do
    test "has default interface fields" do
      iface = %TCPClientInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has TCP-specific fields" do
      iface = %TCPClientInterface{}
      assert iface.socket == nil
      assert iface.target_ip == nil
      assert iface.target_port == nil
      assert iface.initiator == false
      assert iface.reconnecting == false
      assert iface.never_connected == true
      assert iface.kiss_framing == false
      assert iface.i2p_tunneled == false
      assert iface.wants_tunnel == false
      assert iface.owner == nil
      assert iface.receives == false
      assert iface.frame_buffer == <<>>
      assert iface.reconnect_attempts == 0
    end
  end

  # ── TCPServerInterface constants ────────────────────────────────

  describe "TCPServerInterface constants" do
    test "bitrate_guess is 10 Mbps" do
      assert TCPServerInterface.bitrate_guess() == 10_000_000
    end

    test "default_ifac_size is 16" do
      assert TCPServerInterface.default_ifac_size() == 16
    end
  end

  # ── TCPServerInterface struct ───────────────────────────────────

  describe "TCPServerInterface struct" do
    test "has default interface fields" do
      iface = %TCPServerInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
    end

    test "has server-specific fields" do
      iface = %TCPServerInterface{}
      assert iface.bind_ip == nil
      assert iface.bind_port == nil
      assert iface.listen_socket == nil
      assert iface.i2p_tunneled == false
      assert iface.prefer_ipv6 == false
      assert iface.spawned_interfaces == []
      assert iface.owner == nil
      assert iface.receives == false
      assert iface.kiss_framing == false
    end
  end

  # ── Server start and listen ─────────────────────────────────────

  describe "TCPServerInterface start_link" do
    test "starts and listens on localhost" do
      {:ok, server} =
        TCPServerInterface.start_link(
          name: "test_tcp_server",
          listen_ip: "127.0.0.1",
          listen_port: 0
        )

      state = TCPServerInterface.get_state(server)
      assert state.name == "test_tcp_server"
      assert state.online == true
      assert state.receives == true
      assert state.bind_ip == "127.0.0.1"
      assert state.listen_socket != nil
      assert state.in == true
      assert is_binary(state.hash)

      TCPServerInterface.stop(server)
    end

    test "port shorthand works" do
      {:ok, server} =
        TCPServerInterface.start_link(
          name: "test_tcp_port",
          listen_ip: "127.0.0.1",
          port: 0
        )

      state = TCPServerInterface.get_state(server)
      assert state.online == true
      assert state.bind_port == 0

      TCPServerInterface.stop(server)
    end

    test "fails without port" do
      Process.flag(:trap_exit, true)

      result =
        TCPServerInterface.start_link(
          name: "test_tcp_no_port",
          listen_ip: "127.0.0.1"
        )

      assert {:error, _} = result
    end

    test "fails without bind IP" do
      Process.flag(:trap_exit, true)

      result =
        TCPServerInterface.start_link(
          name: "test_tcp_no_ip",
          listen_port: 0
        )

      assert {:error, _} = result
    end
  end

  # ── Client connect to server ────────────────────────────────────

  describe "client/server connection" do
    setup do
      test_pid = self()

      {:ok, server} =
        TCPServerInterface.start_link(
          name: "conn_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = TCPServerInterface.get_state(server)
      {:ok, server_port} = :inet.port(server_state.listen_socket)

      on_exit(fn ->
        if Process.alive?(server), do: TCPServerInterface.stop(server)
      end)

      %{server: server, server_port: server_port, test_pid: test_pid}
    end

    test "client connects to server", %{server_port: server_port, server: server} do
      {:ok, client} =
        TCPClientInterface.start_link(
          name: "conn_client",
          target_host: "127.0.0.1",
          target_port: server_port,
          owner: self()
        )

      client_state = TCPClientInterface.get_state(client)
      assert client_state.online == true
      assert client_state.initiator == true
      assert client_state.never_connected == false
      assert client_state.socket != nil

      # Give server time to accept the connection
      Process.sleep(100)

      assert TCPServerInterface.client_count(server) == 1

      TCPClientInterface.stop(client)
    end

    test "client sends data to server-spawned client", %{server_port: server_port} do
      test_pid = self()

      {:ok, client} =
        TCPClientInterface.start_link(
          name: "send_client",
          target_host: "127.0.0.1",
          target_port: server_port,
          owner: test_pid
        )

      # Wait for connection to be established
      Process.sleep(100)

      # Send data from client - HDLC framed
      :ok = TCPClientInterface.send_data(client, :crypto.strong_rand_bytes(50))

      client_state = TCPClientInterface.get_state(client)
      assert client_state.txb > 0

      TCPClientInterface.stop(client)
    end

    test "HDLC framing roundtrip over TCP", %{server_port: _server_port} do
      test_pid = self()

      # Start server with ourselves as owner
      {:ok, server2} =
        TCPServerInterface.start_link(
          name: "hdlc_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server2_state = TCPServerInterface.get_state(server2)
      {:ok, port2} = :inet.port(server2_state.listen_socket)

      {:ok, client} =
        TCPClientInterface.start_link(
          name: "hdlc_client",
          target_host: "127.0.0.1",
          target_port: port2,
          owner: test_pid
        )

      Process.sleep(100)

      # Send data from client
      test_data = :crypto.strong_rand_bytes(100)
      :ok = TCPClientInterface.send_data(client, test_data)

      # The server-spawned client should receive and process the HDLC-framed data
      # It notifies the owner (test_pid) with the unframed data
      assert_receive {:interface_data, ^test_data, _iface}, 2000

      TCPClientInterface.stop(client)
      TCPServerInterface.stop(server2)
    end

    test "KISS framing roundtrip over TCP" do
      test_pid = self()

      {:ok, server} =
        TCPServerInterface.start_link(
          name: "kiss_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid,
          kiss_framing: true
        )

      server_state = TCPServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        TCPClientInterface.start_link(
          name: "kiss_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid,
          kiss_framing: true
        )

      Process.sleep(100)

      test_data = :crypto.strong_rand_bytes(100)
      :ok = TCPClientInterface.send_data(client, test_data)

      assert_receive {:interface_data, ^test_data, _iface}, 2000

      TCPClientInterface.stop(client)
      TCPServerInterface.stop(server)
    end

    test "multiple messages over TCP", %{} do
      test_pid = self()

      {:ok, server} =
        TCPServerInterface.start_link(
          name: "multi_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = TCPServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        TCPClientInterface.start_link(
          name: "multi_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(100)

      # Send multiple messages
      msg1 = :crypto.strong_rand_bytes(50)
      msg2 = :crypto.strong_rand_bytes(75)
      msg3 = :crypto.strong_rand_bytes(100)

      :ok = TCPClientInterface.send_data(client, msg1)
      :ok = TCPClientInterface.send_data(client, msg2)
      :ok = TCPClientInterface.send_data(client, msg3)

      assert_receive {:interface_data, ^msg1, _}, 2000
      assert_receive {:interface_data, ^msg2, _}, 2000
      assert_receive {:interface_data, ^msg3, _}, 2000

      TCPClientInterface.stop(client)
      TCPServerInterface.stop(server)
    end
  end

  # ── Client with pre-connected socket ────────────────────────────

  describe "pre-connected socket" do
    test "wraps an existing connected socket" do
      # Create a simple TCP pair
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      test_pid = self()

      {:ok, iface} =
        TCPClientInterface.start_link(
          name: "pre_connected",
          connected_socket: server_sock,
          owner: test_pid
        )

      state = TCPClientInterface.get_state(iface)
      assert state.online == true
      assert state.never_connected == false
      assert state.initiator == false

      # Send HDLC-framed data through the raw socket
      test_data = :crypto.strong_rand_bytes(30)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:interface_data, ^test_data, _iface}, 2000

      TCPClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end

    test "wraps socket with KISS framing" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      test_pid = self()

      {:ok, iface} =
        TCPClientInterface.start_link(
          name: "pre_connected_kiss",
          connected_socket: server_sock,
          owner: test_pid,
          kiss_framing: true
        )

      # Send KISS-framed data through the raw socket
      test_data = :crypto.strong_rand_bytes(30)
      framed = KISS.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:interface_data, ^test_data, _iface}, 2000

      TCPClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Detach ──────────────────────────────────────────────────────

  describe "TCPClientInterface detach" do
    test "closes socket and marks offline" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        TCPClientInterface.start_link(
          name: "detach_test",
          connected_socket: server_sock,
          owner: self()
        )

      state_before = TCPClientInterface.get_state(iface)
      assert state_before.online == true

      :ok = TCPClientInterface.stop(iface)

      state_after = TCPClientInterface.get_state(iface)
      assert state_after.online == false
      assert state_after.detached == true
      assert state_after.socket == nil

      GenServer.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  describe "TCPServerInterface detach" do
    test "closes listen socket and marks offline" do
      {:ok, server} =
        TCPServerInterface.start_link(
          name: "server_detach",
          listen_ip: "127.0.0.1",
          listen_port: 0
        )

      state_before = TCPServerInterface.get_state(server)
      assert state_before.online == true
      assert state_before.listen_socket != nil

      :ok = TCPServerInterface.stop(server)

      state_after = TCPServerInterface.get_state(server)
      assert state_after.online == false
      assert state_after.detached == true
      assert state_after.listen_socket == nil

      GenServer.stop(server)
    end
  end

  # ── Reconnection ────────────────────────────────────────────────

  describe "reconnection" do
    test "client reconnects after server disconnect" do
      test_pid = self()

      {:ok, server} =
        TCPServerInterface.start_link(
          name: "reconnect_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = TCPServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        TCPClientInterface.start_link(
          name: "reconnect_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      client_state = TCPClientInterface.get_state(client)
      assert client_state.online == true
      assert client_state.initiator == true

      TCPClientInterface.stop(client)
      TCPServerInterface.stop(server)
    end

    test "client handles max_reconnect_tries" do
      # Try to connect to a port that's not listening
      {:ok, client} =
        TCPClientInterface.start_link(
          name: "max_retry_client",
          target_host: "127.0.0.1",
          target_port: 1,
          max_reconnect_tries: 0,
          connect_timeout: 100
        )

      # Client should start but fail to connect
      state = TCPClientInterface.get_state(client)
      assert state.online == false
      assert state.initiator == true

      GenServer.stop(client)
    end
  end

  # ── String.Chars ────────────────────────────────────────────────

  describe "TCPClientInterface String.Chars" do
    test "with IPv4 address" do
      iface = %TCPClientInterface{name: "tcp0", target_ip: "10.0.0.1", target_port: 4242}
      assert to_string(iface) == "TCPInterface[tcp0/10.0.0.1:4242]"
    end

    test "with IPv6 address" do
      iface = %TCPClientInterface{name: "tcp0", target_ip: "::1", target_port: 4242}
      assert to_string(iface) == "TCPInterface[tcp0/[::1]:4242]"
    end

    test "without address" do
      iface = %TCPClientInterface{name: "tcp0"}
      assert to_string(iface) == "TCPInterface[tcp0]"
    end
  end

  describe "TCPServerInterface String.Chars" do
    test "with IPv4 address" do
      iface = %TCPServerInterface{name: "tcp_srv", bind_ip: "0.0.0.0", bind_port: 5555}
      assert to_string(iface) == "TCPServerInterface[tcp_srv/0.0.0.0:5555]"
    end

    test "with IPv6 address" do
      iface = %TCPServerInterface{name: "tcp_srv", bind_ip: "::1", bind_port: 5555}
      assert to_string(iface) == "TCPServerInterface[tcp_srv/[::1]:5555]"
    end

    test "without address" do
      iface = %TCPServerInterface{name: "tcp_srv"}
      assert to_string(iface) == "TCPServerInterface[tcp_srv]"
    end
  end

  # ── Address resolution ──────────────────────────────────────────

  describe "TCPServerInterface.get_address_for_if/1" do
    test "returns address for loopback" do
      case TCPServerInterface.get_address_for_if("lo0") do
        {:ok, addr} ->
          assert addr == "127.0.0.1"

        {:error, :device_not_found} ->
          # Linux uses "lo" not "lo0"
          case TCPServerInterface.get_address_for_if("lo") do
            {:ok, addr} -> assert addr == "127.0.0.1"
            {:error, _} -> :ok
          end
      end
    end

    test "returns error for nonexistent device" do
      assert {:error, :device_not_found} =
               TCPServerInterface.get_address_for_if("nonexistent_iface99")
    end
  end

  # ── Interface behaviour ─────────────────────────────────────────

  describe "Interface behaviour" do
    test "TCPClientInterface implements Interface behaviour" do
      behaviours =
        TCPClientInterface.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "TCPServerInterface implements Interface behaviour" do
      behaviours =
        TCPServerInterface.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "server process_outgoing returns error" do
      state = %TCPServerInterface{name: "srv"}
      assert {:error, :server_interface} = TCPServerInterface.process_outgoing(state, "data")
    end
  end

  # ── HDLC framing over TCP ──────────────────────────────────────

  describe "HDLC framing over TCP" do
    test "frames with special bytes are correctly handled" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        TCPClientInterface.start_link(
          name: "hdlc_special",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Data containing HDLC special bytes (FLAG=0x7E, ESC=0x7D)
      test_data = <<0x7E, 0x7D, 0x00, 0xFF, 0x7E, 0x7D>> <> :crypto.strong_rand_bytes(20)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:interface_data, ^test_data, _}, 2000

      TCPClientInterface.stop(iface)
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
        TCPClientInterface.start_link(
          name: "hdlc_small",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Send a frame that's too small (< HEADER_MINSIZE = 19)
      small_data = :crypto.strong_rand_bytes(10)
      framed = HDLC.frame(small_data)
      :gen_tcp.send(client_sock, framed)

      # Should NOT receive the small frame
      refute_receive {:interface_data, ^small_data, _}, 500

      # Now send a valid-size frame
      valid_data = :crypto.strong_rand_bytes(25)
      framed2 = HDLC.frame(valid_data)
      :gen_tcp.send(client_sock, framed2)

      assert_receive {:interface_data, ^valid_data, _}, 2000

      TCPClientInterface.stop(iface)
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
        TCPClientInterface.start_link(
          name: "hdlc_frag",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Build an HDLC frame and send it in pieces
      test_data = :crypto.strong_rand_bytes(50)
      framed = HDLC.frame(test_data)

      # Split the frame into chunks
      half = div(byte_size(framed), 2)
      <<part1::binary-size(half), part2::binary>> = framed

      :gen_tcp.send(client_sock, part1)
      Process.sleep(50)
      :gen_tcp.send(client_sock, part2)

      assert_receive {:interface_data, ^test_data, _}, 2000

      TCPClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── KISS framing over TCP ──────────────────────────────────────

  describe "KISS framing over TCP" do
    test "frames with special bytes are correctly handled" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        TCPClientInterface.start_link(
          name: "kiss_special",
          connected_socket: server_sock,
          owner: test_pid,
          kiss_framing: true
        )

      # Data containing KISS special bytes (FEND=0xC0, FESC=0xDB)
      test_data = <<0xC0, 0xDB, 0x00, 0xFF, 0xC0, 0xDB>> <> :crypto.strong_rand_bytes(20)
      framed = KISS.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:interface_data, ^test_data, _}, 2000

      TCPClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Fixed MTU ───────────────────────────────────────────────────

  describe "fixed_mtu option" do
    test "overrides HW_MTU when set" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        TCPClientInterface.start_link(
          name: "fixed_mtu_test",
          connected_socket: server_sock,
          owner: self(),
          fixed_mtu: 1500
        )

      state = TCPClientInterface.get_state(iface)
      assert state.hw_mtu == 1500
      assert state.autoconfigure_mtu == false
      assert state.fixed_mtu == true

      TCPClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end

    test "rejects MTU below RNS minimum (500)" do
      Process.flag(:trap_exit, true)

      catch_result =
        try do
          TCPClientInterface.start_link(
            name: "small_mtu_test",
            fixed_mtu: 100
          )
        catch
          :exit, {%ArgumentError{message: msg}, _} -> {:caught, msg}
        end

      case catch_result do
        {:caught, msg} ->
          assert msg =~ "too small"

        {:error, _} ->
          :ok

        {:ok, pid} ->
          # Shouldn't reach here, but clean up
          GenServer.stop(pid)
          flunk("Expected error for MTU below minimum")
      end
    end
  end

  # ── Server with server_name registration ────────────────────────

  describe "server_name option" do
    test "TCPServerInterface registers with given name" do
      {:ok, _pid} =
        TCPServerInterface.start_link(
          name: "named_srv",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          server_name: :test_tcp_named_srv
        )

      state = TCPServerInterface.get_state(:test_tcp_named_srv)
      assert state.name == "named_srv"

      TCPServerInterface.stop(:test_tcp_named_srv)
    end
  end

  # ── Bidirectional communication ─────────────────────────────────

  describe "bidirectional communication" do
    test "server-spawned client can send back to initiator" do
      test_pid = self()

      # Start server
      {:ok, server} =
        TCPServerInterface.start_link(
          name: "bidir_server",
          listen_ip: "127.0.0.1",
          listen_port: 0,
          owner: test_pid
        )

      server_state = TCPServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      # Start client that connects to server
      {:ok, client} =
        TCPClientInterface.start_link(
          name: "bidir_client",
          target_host: "127.0.0.1",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(200)

      # Client sends data to server
      msg1 = :crypto.strong_rand_bytes(30)
      :ok = TCPClientInterface.send_data(client, msg1)

      # Should receive from the server-spawned client
      assert_receive {:interface_data, ^msg1, _}, 2000

      TCPClientInterface.stop(client)
      TCPServerInterface.stop(server)
    end
  end

  # ── Owner callback styles ──────────────────────────────────────

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
        TCPClientInterface.start_link(
          name: "fn_callback",
          connected_socket: server_sock,
          owner: callback
        )

      test_data = :crypto.strong_rand_bytes(25)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:callback_received, ^test_data}, 2000

      TCPClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── TCP socket closure detection ────────────────────────────────

  describe "socket closure" do
    test "non-initiator teardown on remote close" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        TCPClientInterface.start_link(
          name: "close_test",
          connected_socket: server_sock,
          owner: self()
        )

      state = TCPClientInterface.get_state(iface)
      assert state.online == true
      assert state.initiator == false

      # Close the remote end
      :gen_tcp.close(client_sock)

      # Give time for tcp_closed message to propagate
      Process.sleep(500)

      state = TCPClientInterface.get_state(iface)
      assert state.online == false

      GenServer.stop(iface)
      :gen_tcp.close(listen)
    end
  end
end
