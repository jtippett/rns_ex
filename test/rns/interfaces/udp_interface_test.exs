defmodule RNS.Interfaces.UDPInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.UDPInterface

  # ── Constants ──────────────────────────────────────────────────

  describe "constants" do
    test "bitrate_guess is 10 Mbps" do
      assert UDPInterface.bitrate_guess() == 10_000_000
    end

    test "default_ifac_size is 16" do
      assert UDPInterface.default_ifac_size() == 16
    end
  end

  # ── Struct fields ──────────────────────────────────────────────

  describe "struct" do
    test "has default interface fields" do
      iface = %UDPInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.bitrate == 62_500
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has UDP-specific fields" do
      iface = %UDPInterface{}
      assert iface.receives == false
      assert iface.forwards == false
      assert iface.bind_ip == nil
      assert iface.bind_port == nil
      assert iface.forward_ip == nil
      assert iface.forward_port == nil
      assert iface.recv_socket == nil
      assert iface.owner == nil
    end
  end

  # ── GenServer lifecycle ────────────────────────────────────────

  describe "start_link/1 with bind and forward" do
    test "starts and listens on localhost" do
      {:ok, pid} =
        UDPInterface.start_link(
          name: "test_udp_both",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          forward_ip: "127.0.0.1",
          forward_port: 19999
        )

      state = UDPInterface.get_state(pid)
      assert state.name == "test_udp_both"
      assert state.online == true
      assert state.receives == true
      assert state.forwards == true
      assert state.bind_ip == "127.0.0.1"
      assert state.forward_ip == "127.0.0.1"
      assert state.forward_port == 19999
      assert state.bitrate == 10_000_000
      assert state.hw_mtu == 1064
      assert state.in == true
      assert state.out == true
      assert is_binary(state.hash)

      GenServer.stop(pid)
    end

    test "port shorthand applies to both bind and forward" do
      {:ok, pid} =
        UDPInterface.start_link(
          name: "test_udp_port",
          bind_ip: "127.0.0.1",
          forward_ip: "127.0.0.1",
          port: 0
        )

      state = UDPInterface.get_state(pid)
      assert state.receives == true
      assert state.forwards == true
      # bind_port gets 0 but OS assigns a real port to the socket
      assert state.bind_port == 0
      assert state.forward_port == 0

      GenServer.stop(pid)
    end
  end

  describe "start_link/1 forward only" do
    test "starts without binding a receive socket" do
      {:ok, pid} =
        UDPInterface.start_link(
          name: "test_udp_forward_only",
          forward_ip: "127.0.0.1",
          forward_port: 19998
        )

      state = UDPInterface.get_state(pid)
      assert state.receives == false
      assert state.forwards == true
      assert state.online == true
      assert state.recv_socket == nil

      GenServer.stop(pid)
    end
  end

  describe "start_link/1 bind only" do
    test "starts without forwarding config" do
      {:ok, pid} =
        UDPInterface.start_link(
          name: "test_udp_bind_only",
          bind_ip: "127.0.0.1",
          bind_port: 0
        )

      state = UDPInterface.get_state(pid)
      assert state.receives == true
      assert state.forwards == false
      assert state.online == true
      assert state.recv_socket != nil

      GenServer.stop(pid)
    end
  end

  # ── Send/receive over localhost ────────────────────────────────

  describe "send and receive" do
    test "send data over UDP to a receiver" do
      test_pid = self()

      # Start receiver
      {:ok, receiver} =
        UDPInterface.start_link(
          name: "test_receiver",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          owner: test_pid
        )

      receiver_state = UDPInterface.get_state(receiver)
      # Get the actual port the OS assigned
      {:ok, actual_port} = :inet.port(receiver_state.recv_socket)

      # Start sender
      {:ok, sender} =
        UDPInterface.start_link(
          name: "test_sender",
          forward_ip: "127.0.0.1",
          forward_port: actual_port
        )

      # Send some data
      test_data = "hello RNS over UDP"
      :ok = UDPInterface.send_data(sender, test_data)

      # Receiver should get it via owner notification
      assert_receive {:udp_interface_data, ^test_data, _iface}, 1000

      # Check TX bytes on sender
      sender_state = UDPInterface.get_state(sender)
      assert sender_state.txb == byte_size(test_data)

      GenServer.stop(sender)
      GenServer.stop(receiver)
    end

    test "send binary data" do
      test_pid = self()

      {:ok, receiver} =
        UDPInterface.start_link(
          name: "test_bin_receiver",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          owner: test_pid
        )

      receiver_state = UDPInterface.get_state(receiver)
      {:ok, actual_port} = :inet.port(receiver_state.recv_socket)

      {:ok, sender} =
        UDPInterface.start_link(
          name: "test_bin_sender",
          forward_ip: "127.0.0.1",
          forward_port: actual_port
        )

      # Send binary packet data
      test_data = :crypto.strong_rand_bytes(100)
      :ok = UDPInterface.send_data(sender, test_data)

      assert_receive {:udp_interface_data, ^test_data, _iface}, 1000

      GenServer.stop(sender)
      GenServer.stop(receiver)
    end

    test "multiple sends accumulate byte counters" do
      test_pid = self()

      {:ok, receiver} =
        UDPInterface.start_link(
          name: "test_multi_receiver",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          owner: test_pid
        )

      receiver_state = UDPInterface.get_state(receiver)
      {:ok, actual_port} = :inet.port(receiver_state.recv_socket)

      {:ok, sender} =
        UDPInterface.start_link(
          name: "test_multi_sender",
          forward_ip: "127.0.0.1",
          forward_port: actual_port
        )

      :ok = UDPInterface.send_data(sender, "msg1")
      :ok = UDPInterface.send_data(sender, "msg22")
      :ok = UDPInterface.send_data(sender, "msg333")

      # Wait for all three messages
      assert_receive {:udp_interface_data, "msg1", _}, 1000
      assert_receive {:udp_interface_data, "msg22", _}, 1000
      assert_receive {:udp_interface_data, "msg333", _}, 1000

      sender_state = UDPInterface.get_state(sender)
      assert sender_state.txb == 4 + 5 + 6

      # RX bytes accumulate on receiver
      receiver_state = UDPInterface.get_state(receiver)
      assert receiver_state.rxb == 4 + 5 + 6

      GenServer.stop(sender)
      GenServer.stop(receiver)
    end

    test "send fails when not configured for forwarding" do
      {:ok, pid} =
        UDPInterface.start_link(
          name: "test_no_forward",
          bind_ip: "127.0.0.1",
          bind_port: 0
        )

      assert {:error, :not_configured_for_forwarding} = UDPInterface.send_data(pid, "test")

      GenServer.stop(pid)
    end
  end

  # ── Owner callback styles ──────────────────────────────────────

  describe "owner callback" do
    test "function/2 callback" do
      test_pid = self()

      callback = fn data, _iface ->
        send(test_pid, {:callback_received, data})
      end

      {:ok, receiver} =
        UDPInterface.start_link(
          name: "test_fn_callback",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          owner: callback
        )

      receiver_state = UDPInterface.get_state(receiver)
      {:ok, actual_port} = :inet.port(receiver_state.recv_socket)

      {:ok, sender} =
        UDPInterface.start_link(
          name: "test_fn_sender",
          forward_ip: "127.0.0.1",
          forward_port: actual_port
        )

      :ok = UDPInterface.send_data(sender, "fn_test")
      assert_receive {:callback_received, "fn_test"}, 1000

      GenServer.stop(sender)
      GenServer.stop(receiver)
    end
  end

  # ── Detach ─────────────────────────────────────────────────────

  describe "detach/1" do
    test "closes socket and marks offline" do
      {:ok, pid} =
        UDPInterface.start_link(
          name: "test_detach",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          forward_ip: "127.0.0.1",
          forward_port: 19997
        )

      state_before = UDPInterface.get_state(pid)
      assert state_before.online == true
      assert state_before.recv_socket != nil

      :ok = UDPInterface.stop(pid)

      state_after = UDPInterface.get_state(pid)
      assert state_after.online == false
      assert state_after.detached == true
      assert state_after.recv_socket == nil

      GenServer.stop(pid)
    end
  end

  # ── String.Chars ───────────────────────────────────────────────

  describe "String.Chars" do
    test "with bind address" do
      iface = %UDPInterface{name: "udp0", bind_ip: "127.0.0.1", bind_port: 4242}
      assert to_string(iface) == "UDPInterface[udp0/127.0.0.1:4242]"
    end

    test "without bind address" do
      iface = %UDPInterface{name: "udp0"}
      assert to_string(iface) == "UDPInterface[udp0]"
    end
  end

  # ── Address resolution ─────────────────────────────────────────

  describe "get_address_for_if/1" do
    test "returns address for loopback" do
      case UDPInterface.get_address_for_if("lo0") do
        {:ok, addr} ->
          assert addr == "127.0.0.1"

        {:error, :device_not_found} ->
          # Linux uses "lo" not "lo0"
          case UDPInterface.get_address_for_if("lo") do
            {:ok, addr} -> assert addr == "127.0.0.1"
            {:error, _} -> :ok
          end
      end
    end

    test "returns error for nonexistent device" do
      assert {:error, :device_not_found} = UDPInterface.get_address_for_if("nonexistent_iface99")
    end
  end

  describe "get_broadcast_for_if/1" do
    test "returns error for nonexistent device" do
      assert {:error, :device_not_found} =
               UDPInterface.get_broadcast_for_if("nonexistent_iface99")
    end
  end

  # ── Behaviour implementation ───────────────────────────────────

  describe "Interface behaviour" do
    test "process_outgoing/2 sends data" do
      test_pid = self()

      {:ok, receiver} =
        UDPInterface.start_link(
          name: "test_behaviour_recv",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          owner: test_pid
        )

      receiver_state = UDPInterface.get_state(receiver)
      {:ok, actual_port} = :inet.port(receiver_state.recv_socket)

      state = %UDPInterface{
        name: "test_behaviour_send",
        forwards: true,
        forward_ip: "127.0.0.1",
        forward_port: actual_port
      }

      {:ok, updated} = UDPInterface.process_outgoing(state, "behaviour_test")
      assert updated.txb == byte_size("behaviour_test")

      assert_receive {:udp_interface_data, "behaviour_test", _}, 1000

      GenServer.stop(receiver)
    end

    test "process_incoming/2 updates rxb and notifies owner" do
      test_pid = self()

      state = %UDPInterface{
        name: "test_incoming",
        owner: test_pid,
        rxb: 0
      }

      {:ok, updated} = UDPInterface.process_incoming(state, "incoming_data")
      assert updated.rxb == byte_size("incoming_data")

      assert_receive {:udp_interface_data, "incoming_data", _}, 100
    end

    test "process_outgoing/2 returns error when not forwarding" do
      state = %UDPInterface{name: "no_fwd", forwards: false}

      assert {:error, :not_configured_for_forwarding} =
               UDPInterface.process_outgoing(state, "test")
    end
  end

  # ── Config parsing ─────────────────────────────────────────────

  describe "config parsing" do
    test "listen_ip alias for bind_ip" do
      {:ok, pid} =
        UDPInterface.start_link(
          name: "test_listen_alias",
          listen_ip: "127.0.0.1",
          listen_port: 0
        )

      state = UDPInterface.get_state(pid)
      assert state.bind_ip == "127.0.0.1"
      assert state.receives == true

      GenServer.stop(pid)
    end
  end

  # ── Registration name ──────────────────────────────────────────

  describe "server_name option" do
    test "registers with given name" do
      {:ok, _pid} =
        UDPInterface.start_link(
          name: "test_named",
          bind_ip: "127.0.0.1",
          bind_port: 0,
          server_name: :test_udp_named
        )

      state = UDPInterface.get_state(:test_udp_named)
      assert state.name == "test_named"

      GenServer.stop(:test_udp_named)
    end
  end
end
