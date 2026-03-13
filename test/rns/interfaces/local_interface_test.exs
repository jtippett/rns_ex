defmodule RNS.Interfaces.LocalInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.Interface.HDLC
  alias RNS.Interfaces.LocalClientInterface
  alias RNS.Interfaces.LocalInterface
  alias RNS.Interfaces.LocalServerInterface

  # ── LocalInterface constants ──────────────────────────────────────

  describe "LocalInterface constants" do
    test "HW_MTU is 262144" do
      assert LocalInterface.hw_mtu() == 262_144
    end
  end

  # ── LocalClientInterface constants ────────────────────────────────

  describe "LocalClientInterface constants" do
    test "bitrate is 1 Gbps" do
      assert LocalClientInterface.bitrate_const() == 1_000_000_000
    end

    test "reconnect_wait is 8 seconds" do
      assert LocalClientInterface.reconnect_wait() == 8
    end

    test "header_minsize is 19 bytes" do
      assert LocalClientInterface.header_minsize() == 19
    end
  end

  # ── LocalClientInterface struct ───────────────────────────────────

  describe "LocalClientInterface struct" do
    test "has default interface fields" do
      iface = %LocalClientInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has local-specific fields" do
      iface = %LocalClientInterface{}
      assert iface.socket == nil
      assert iface.target_ip == nil
      assert iface.target_port == nil
      assert iface.socket_path == nil
      assert iface.is_connected_to_shared_instance == false
      assert iface.reconnecting == false
      assert iface.never_connected == true
      assert iface.parent_interface == nil
      assert iface.owner == nil
      assert iface.receives == false
      assert iface.frame_buffer == <<>>
    end
  end

  # ── LocalServerInterface constants ────────────────────────────────

  describe "LocalServerInterface constants" do
    test "bitrate is 1 Gbps" do
      assert LocalServerInterface.bitrate_const() == 1_000_000_000
    end
  end

  # ── LocalServerInterface struct ───────────────────────────────────

  describe "LocalServerInterface struct" do
    test "has default interface fields" do
      iface = %LocalServerInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
    end

    test "has server-specific fields" do
      iface = %LocalServerInterface{}
      assert iface.bind_ip == nil
      assert iface.bind_port == nil
      assert iface.listen_socket == nil
      assert iface.socket_path == nil
      assert iface.clients == 0
      assert iface.spawned_interfaces == []
      assert iface.owner == nil
      assert iface.receives == false
      assert iface.is_local_shared_instance == false
    end
  end

  # ── Server start and listen ─────────────────────────────────────

  describe "LocalServerInterface start_link" do
    test "starts and listens on localhost with TCP" do
      {:ok, server} =
        LocalServerInterface.start_link(
          name: "test_local_server",
          bindport: 0
        )

      state = LocalServerInterface.get_state(server)
      assert state.name == "test_local_server"
      assert state.online == true
      assert state.receives == true
      assert state.bind_ip == "127.0.0.1"
      assert state.listen_socket != nil
      assert state.in == true
      assert state.is_local_shared_instance == true
      assert state.bitrate == 1_000_000_000
      assert is_binary(state.hash)

      LocalServerInterface.stop(server)
    end

    test "defaults name to Reticulum" do
      {:ok, server} =
        LocalServerInterface.start_link(bindport: 0)

      state = LocalServerInterface.get_state(server)
      assert state.name == "Reticulum"

      LocalServerInterface.stop(server)
    end

    test "starts with zero clients" do
      {:ok, server} =
        LocalServerInterface.start_link(
          name: "test_zero_clients",
          bindport: 0
        )

      assert LocalServerInterface.client_count(server) == 0

      LocalServerInterface.stop(server)
    end
  end

  # ── Client connect to server ────────────────────────────────────

  describe "client/server connection" do
    setup do
      test_pid = self()

      {:ok, server} =
        LocalServerInterface.start_link(
          name: "conn_local_server",
          bindport: 0,
          owner: test_pid
        )

      server_state = LocalServerInterface.get_state(server)
      {:ok, server_port} = :inet.port(server_state.listen_socket)

      on_exit(fn ->
        if Process.alive?(server), do: LocalServerInterface.stop(server)
      end)

      %{server: server, server_port: server_port, test_pid: test_pid}
    end

    test "client connects to server", %{server_port: server_port, server: server} do
      {:ok, client} =
        LocalClientInterface.start_link(
          name: "conn_local_client",
          target_port: server_port,
          owner: self()
        )

      client_state = LocalClientInterface.get_state(client)
      assert client_state.online == true
      assert client_state.target_ip == "127.0.0.1"
      assert client_state.target_port == server_port
      assert client_state.is_connected_to_shared_instance == true
      assert client_state.never_connected == false
      assert client_state.socket != nil

      # Give server time to accept the connection
      Process.sleep(100)

      assert LocalServerInterface.client_count(server) == 1

      LocalClientInterface.stop(client)
    end

    test "client sends data to server-spawned client", %{server_port: server_port} do
      test_pid = self()

      {:ok, client} =
        LocalClientInterface.start_link(
          name: "send_local_client",
          target_port: server_port,
          owner: test_pid
        )

      # Wait for connection to be established
      Process.sleep(100)

      # Send data from client
      :ok = LocalClientInterface.send_data(client, :crypto.strong_rand_bytes(50))

      client_state = LocalClientInterface.get_state(client)
      assert client_state.txb > 0

      LocalClientInterface.stop(client)
    end

    test "HDLC framing roundtrip over local TCP", %{} do
      test_pid = self()

      {:ok, server2} =
        LocalServerInterface.start_link(
          name: "hdlc_local_server",
          bindport: 0,
          owner: test_pid
        )

      server2_state = LocalServerInterface.get_state(server2)
      {:ok, port2} = :inet.port(server2_state.listen_socket)

      {:ok, client} =
        LocalClientInterface.start_link(
          name: "hdlc_local_client",
          target_port: port2,
          owner: test_pid
        )

      Process.sleep(100)

      # Send data from client
      test_data = :crypto.strong_rand_bytes(100)
      :ok = LocalClientInterface.send_data(client, test_data)

      # The server-spawned client should receive and process the HDLC-framed data
      assert_receive {:local_interface_data, ^test_data, _iface}, 2000

      LocalClientInterface.stop(client)
      LocalServerInterface.stop(server2)
    end

    test "multiple messages over local TCP" do
      test_pid = self()

      {:ok, server} =
        LocalServerInterface.start_link(
          name: "multi_local_server",
          bindport: 0,
          owner: test_pid
        )

      server_state = LocalServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        LocalClientInterface.start_link(
          name: "multi_local_client",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(100)

      # Send multiple messages
      msg1 = :crypto.strong_rand_bytes(50)
      msg2 = :crypto.strong_rand_bytes(75)
      msg3 = :crypto.strong_rand_bytes(100)

      :ok = LocalClientInterface.send_data(client, msg1)
      :ok = LocalClientInterface.send_data(client, msg2)
      :ok = LocalClientInterface.send_data(client, msg3)

      assert_receive {:local_interface_data, ^msg1, _}, 2000
      assert_receive {:local_interface_data, ^msg2, _}, 2000
      assert_receive {:local_interface_data, ^msg3, _}, 2000

      LocalClientInterface.stop(client)
      LocalServerInterface.stop(server)
    end

    test "multiple clients connect to server" do
      test_pid = self()

      {:ok, server} =
        LocalServerInterface.start_link(
          name: "multi_client_srv",
          bindport: 0,
          owner: test_pid
        )

      server_state = LocalServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client1} =
        LocalClientInterface.start_link(
          name: "mc_client1",
          target_port: port,
          owner: test_pid
        )

      {:ok, client2} =
        LocalClientInterface.start_link(
          name: "mc_client2",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(200)

      assert LocalServerInterface.client_count(server) == 2

      # Each client can send independently
      msg1 = :crypto.strong_rand_bytes(30)
      msg2 = :crypto.strong_rand_bytes(40)

      :ok = LocalClientInterface.send_data(client1, msg1)
      :ok = LocalClientInterface.send_data(client2, msg2)

      assert_receive {:local_interface_data, ^msg1, _}, 2000
      assert_receive {:local_interface_data, ^msg2, _}, 2000

      LocalClientInterface.stop(client1)
      LocalClientInterface.stop(client2)
      LocalServerInterface.stop(server)
    end
  end

  # ── Pre-connected socket ────────────────────────────────────────

  describe "pre-connected socket" do
    test "wraps an existing connected socket" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      test_pid = self()

      {:ok, iface} =
        LocalClientInterface.start_link(
          name: "pre_connected_local",
          connected_socket: server_sock,
          owner: test_pid
        )

      state = LocalClientInterface.get_state(iface)
      assert state.online == true
      assert state.never_connected == false
      assert state.is_connected_to_shared_instance == false

      # Send HDLC-framed data through the raw socket
      test_data = :crypto.strong_rand_bytes(30)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:local_interface_data, ^test_data, _iface}, 2000

      LocalClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Detach ──────────────────────────────────────────────────────

  describe "LocalClientInterface detach" do
    test "closes socket and marks offline" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        LocalClientInterface.start_link(
          name: "detach_local_test",
          connected_socket: server_sock,
          owner: self()
        )

      state_before = LocalClientInterface.get_state(iface)
      assert state_before.online == true

      :ok = LocalClientInterface.stop(iface)

      state_after = LocalClientInterface.get_state(iface)
      assert state_after.online == false
      assert state_after.detached == true
      assert state_after.socket == nil

      GenServer.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  describe "LocalServerInterface detach" do
    test "closes listen socket and stops spawned clients" do
      {:ok, server} =
        LocalServerInterface.start_link(
          name: "server_detach_local",
          bindport: 0
        )

      state_before = LocalServerInterface.get_state(server)
      assert state_before.online == true
      assert state_before.listen_socket != nil

      :ok = LocalServerInterface.stop(server)

      state_after = LocalServerInterface.get_state(server)
      assert state_after.online == false
      assert state_after.detached == true
      assert state_after.listen_socket == nil
      assert state_after.clients == 0
      assert state_after.spawned_interfaces == []

      GenServer.stop(server)
    end
  end

  # ── should_ingress_limit ──────────────────────────────────────────

  describe "should_ingress_limit" do
    test "always returns false for LocalClientInterface" do
      iface = %LocalClientInterface{name: "test"}
      assert LocalClientInterface.should_ingress_limit(iface) == false
    end
  end

  # ── String.Chars ────────────────────────────────────────────────

  describe "LocalClientInterface String.Chars" do
    test "with port" do
      iface = %LocalClientInterface{name: "local0", target_port: 37_428}
      assert to_string(iface) == "LocalInterface[37428]"
    end

    test "with socket path" do
      iface = %LocalClientInterface{name: "local0", socket_path: "/tmp/rns.sock"}
      assert to_string(iface) == "LocalInterface[/tmp/rns.sock]"
    end

    test "with name only" do
      iface = %LocalClientInterface{name: "local0"}
      assert to_string(iface) == "LocalInterface[local0]"
    end
  end

  describe "LocalServerInterface String.Chars" do
    test "with port" do
      iface = %LocalServerInterface{name: "Reticulum", bind_port: 37_428}
      assert to_string(iface) == "Shared Instance[37428]"
    end

    test "with socket path" do
      iface = %LocalServerInterface{name: "Reticulum", socket_path: "/tmp/rns.sock"}
      assert to_string(iface) == "Shared Instance[/tmp/rns.sock]"
    end

    test "with name only" do
      iface = %LocalServerInterface{name: "Reticulum"}
      assert to_string(iface) == "Shared Instance[Reticulum]"
    end
  end

  # ── Interface behaviour ─────────────────────────────────────────

  describe "Interface behaviour" do
    test "LocalClientInterface implements Interface behaviour" do
      behaviours =
        LocalClientInterface.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "LocalServerInterface implements Interface behaviour" do
      behaviours =
        LocalServerInterface.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert RNS.Interfaces.Interface in behaviours
    end

    test "server process_outgoing returns :ok (no-op)" do
      state = %LocalServerInterface{name: "srv"}
      assert :ok = LocalServerInterface.process_outgoing(state, "data")
    end
  end

  # ── HDLC framing over local TCP ────────────────────────────────

  describe "HDLC framing over local TCP" do
    test "frames with special bytes are correctly handled" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        LocalClientInterface.start_link(
          name: "hdlc_special_local",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Data containing HDLC special bytes (FLAG=0x7E, ESC=0x7D)
      test_data = <<0x7E, 0x7D, 0x00, 0xFF, 0x7E, 0x7D>> <> :crypto.strong_rand_bytes(20)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:local_interface_data, ^test_data, _}, 2000

      LocalClientInterface.stop(iface)
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
        LocalClientInterface.start_link(
          name: "hdlc_small_local",
          connected_socket: server_sock,
          owner: test_pid
        )

      # Send a frame that's too small (< HEADER_MINSIZE = 19)
      small_data = :crypto.strong_rand_bytes(10)
      framed = HDLC.frame(small_data)
      :gen_tcp.send(client_sock, framed)

      # Should NOT receive the small frame
      refute_receive {:local_interface_data, ^small_data, _}, 500

      # Now send a valid-size frame
      valid_data = :crypto.strong_rand_bytes(25)
      framed2 = HDLC.frame(valid_data)
      :gen_tcp.send(client_sock, framed2)

      assert_receive {:local_interface_data, ^valid_data, _}, 2000

      LocalClientInterface.stop(iface)
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
        LocalClientInterface.start_link(
          name: "hdlc_frag_local",
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

      assert_receive {:local_interface_data, ^test_data, _}, 2000

      LocalClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Server name registration ──────────────────────────────────────

  describe "server_name option" do
    test "LocalServerInterface registers with given name" do
      {:ok, _pid} =
        LocalServerInterface.start_link(
          name: "named_local_srv",
          bindport: 0,
          server_name: :test_local_named_srv
        )

      state = LocalServerInterface.get_state(:test_local_named_srv)
      assert state.name == "named_local_srv"

      LocalServerInterface.stop(:test_local_named_srv)
    end
  end

  # ── Bidirectional communication ─────────────────────────────────

  describe "bidirectional communication" do
    test "server-spawned client can send back to initiator" do
      test_pid = self()

      {:ok, server} =
        LocalServerInterface.start_link(
          name: "bidir_local_server",
          bindport: 0,
          owner: test_pid
        )

      server_state = LocalServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        LocalClientInterface.start_link(
          name: "bidir_local_client",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(200)

      # Client sends data to server
      msg1 = :crypto.strong_rand_bytes(30)
      :ok = LocalClientInterface.send_data(client, msg1)

      # Should receive from the server-spawned client
      assert_receive {:local_interface_data, ^msg1, _}, 2000

      LocalClientInterface.stop(client)
      LocalServerInterface.stop(server)
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
        LocalClientInterface.start_link(
          name: "fn_callback_local",
          connected_socket: server_sock,
          owner: callback
        )

      test_data = :crypto.strong_rand_bytes(25)
      framed = HDLC.frame(test_data)
      :gen_tcp.send(client_sock, framed)

      assert_receive {:callback_received, ^test_data}, 2000

      LocalClientInterface.stop(iface)
      :gen_tcp.close(client_sock)
      :gen_tcp.close(listen)
    end
  end

  # ── Socket closure detection ────────────────────────────────────

  describe "socket closure" do
    test "non-shared-instance teardown on remote close" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      {:ok, client_sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server_sock} = :gen_tcp.accept(listen)

      {:ok, iface} =
        LocalClientInterface.start_link(
          name: "close_local_test",
          connected_socket: server_sock,
          owner: self()
        )

      ref = Process.monitor(iface)

      state = LocalClientInterface.get_state(iface)
      assert state.online == true
      assert state.is_connected_to_shared_instance == false

      # Close the remote end — non-shared-instance clients stop on socket close
      :gen_tcp.close(client_sock)

      # Wait for the process to terminate
      assert_receive {:DOWN, ^ref, :process, ^iface, :normal}, 2000

      :gen_tcp.close(listen)
    end

    test "server client count decrements on client disconnect" do
      test_pid = self()

      {:ok, server} =
        LocalServerInterface.start_link(
          name: "count_dec_server",
          bindport: 0,
          owner: test_pid
        )

      server_state = LocalServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        LocalClientInterface.start_link(
          name: "count_dec_client",
          target_port: port,
          owner: test_pid
        )

      Process.sleep(200)
      assert LocalServerInterface.client_count(server) == 1

      # Stop the client process entirely so DOWN message fires
      GenServer.stop(client)

      # Give time for DOWN message to propagate
      Process.sleep(500)

      assert LocalServerInterface.client_count(server) == 0

      LocalServerInterface.stop(server)
    end
  end

  # ── Server announce tracking ────────────────────────────────────

  describe "LocalServerInterface announce tracking" do
    test "received_announce tracks from spawned" do
      state = %LocalServerInterface{name: "test", ia_freq_deque: []}

      # Not from spawned - no change
      unchanged = LocalServerInterface.received_announce(state, false)
      assert unchanged.ia_freq_deque == []

      # From spawned - adds timestamp
      updated = LocalServerInterface.received_announce(state, true)
      assert length(updated.ia_freq_deque) == 1
    end

    test "sent_announce tracks from spawned" do
      state = %LocalServerInterface{name: "test", oa_freq_deque: []}

      # Not from spawned - no change
      unchanged = LocalServerInterface.sent_announce(state, false)
      assert unchanged.oa_freq_deque == []

      # From spawned - adds timestamp
      updated = LocalServerInterface.sent_announce(state, true)
      assert length(updated.oa_freq_deque) == 1
    end
  end

  # ── String port as target_port ─────────────────────────────────

  describe "string port handling" do
    test "accepts string port and converts to integer" do
      {:ok, server} =
        LocalServerInterface.start_link(
          name: "str_port_server",
          bindport: 0
        )

      server_state = LocalServerInterface.get_state(server)
      {:ok, port} = :inet.port(server_state.listen_socket)

      {:ok, client} =
        LocalClientInterface.start_link(
          name: "str_port_client",
          target_port: Integer.to_string(port),
          owner: self()
        )

      client_state = LocalClientInterface.get_state(client)
      assert client_state.online == true
      assert client_state.target_port == port

      LocalClientInterface.stop(client)
      LocalServerInterface.stop(server)
    end
  end
end
