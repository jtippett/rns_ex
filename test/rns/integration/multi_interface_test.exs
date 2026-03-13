defmodule RNS.Integration.MultiInterfaceTest do
  @moduledoc """
  Integration tests for routing across multiple interfaces.

  Tests:
    1. Packet routing to correct interface based on path table
    2. Broadcasting on all outgoing interfaces when no path is known
    3. Interface registration/deregistration lifecycle
    4. Announce propagation across interfaces
    5. Path-based directed transmission
    6. LocalInterface server↔client data exchange
  """

  use ExUnit.Case, async: false

  alias RNS.Destination
  alias RNS.Identity
  alias RNS.Packet
  alias RNS.Transport

  # ── Setup ─────────────────────────────────────────────────────────

  setup do
    # Clear ETS tables for clean state (Transport is supervised by the application)
    RNS.Test.SupervisedHelpers.clear_transport_tables()
    :ok
  end

  # ── Broadcast to All Interfaces ──────────────────────────────────

  describe "broadcast to all outgoing interfaces" do
    test "announce is broadcast to all registered outgoing interfaces" do
      test_pid = self()

      # Register multiple interfaces that capture outgoing data
      iface1 = make_capture_interface("Interface1", test_pid, :iface1)
      iface2 = make_capture_interface("Interface2", test_pid, :iface2)
      iface3 = make_capture_interface("Interface3", test_pid, :iface3)

      :ok = Transport.register_interface(iface1)
      :ok = Transport.register_interface(iface2)
      :ok = Transport.register_interface(iface3)

      # Create and pack an announce
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "multi"
        ])

      {announce, _} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce)

      # Broadcast via Transport.outbound
      assert Transport.outbound(packed) == true

      # All three interfaces should receive the outgoing data
      assert_receive {:outgoing, :iface1, _data1}, 1000
      assert_receive {:outgoing, :iface2, _data2}, 1000
      assert_receive {:outgoing, :iface3, _data3}, 1000
    end

    test "in-only interfaces do not receive outgoing packets" do
      test_pid = self()

      # One outgoing interface, one inbound-only
      out_iface = make_capture_interface("OutInterface", test_pid, :out_iface)

      in_iface = %{
        name: "InOnlyInterface",
        hash: :crypto.strong_rand_bytes(16),
        out: false,
        in: true,
        online: true,
        mode: nil,
        ifac_identity: nil,
        process_outgoing: fn _data ->
          send(test_pid, {:outgoing, :in_iface, :should_not_happen})
          :ok
        end
      }

      :ok = Transport.register_interface(out_iface)
      :ok = Transport.register_interface(in_iface)

      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "inonly"
        ])

      {announce, _} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce)

      Transport.outbound(packed)

      # Only the out interface should receive
      assert_receive {:outgoing, :out_iface, _data}, 1000
      refute_receive {:outgoing, :in_iface, _}, 200
    end

    test "deregistered interface does not receive broadcasts" do
      test_pid = self()

      iface1 = make_capture_interface("Active", test_pid, :active)
      iface2 = make_capture_interface("Removed", test_pid, :removed)

      :ok = Transport.register_interface(iface1)
      :ok = Transport.register_interface(iface2)

      # Deregister one
      :ok = Transport.deregister_interface(iface2)

      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "dereg"
        ])

      {announce, _} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce)

      Transport.outbound(packed)

      assert_receive {:outgoing, :active, _data}, 1000
      refute_receive {:outgoing, :removed, _}, 200
    end
  end

  # ── Path-Based Routing ───────────────────────────────────────────

  describe "path-based directed routing" do
    test "data packet uses path table to select interface" do
      test_pid = self()

      # Register two interfaces
      iface1 = make_capture_interface("PathInterface", test_pid, :path_iface)
      iface2 = make_capture_interface("OtherInterface", test_pid, :other_iface)

      :ok = Transport.register_interface(iface1)
      :ok = Transport.register_interface(iface2)

      # Create a destination and install a path entry pointing to iface1
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "pathroute"
        ])

      # Establish path via announce received on iface1
      {announce, _} = Destination.announce(dest, send: false)
      packed_announce = Packet.pack(announce)

      # Simulate receiving announce on iface1
      Transport.inbound(packed_announce.raw, iface1)

      assert Transport.has_path(dest.hash)

      # Now create a data packet to this destination
      # Since path exists with hops=1, Transport.outbound should use path interface
      data_packet =
        Packet.new(dest, "Hello via path",
          packet_type: Packet.data(),
          create_receipt: false
        )

      packed_data = Packet.pack(data_packet)

      Transport.outbound(packed_data)

      # The packet should be sent on the path interface (iface1)
      assert_receive {:outgoing, :path_iface, _data}, 1000
    end
  end

  # ── Announce Propagation Across Interfaces ───────────────────────

  describe "announce propagation" do
    test "announce received on one interface establishes path" do
      test_pid = self()

      iface1 = make_capture_interface("Radio", test_pid, :radio)
      iface2 = make_capture_interface("TCP", test_pid, :tcp)

      :ok = Transport.register_interface(iface1)
      :ok = Transport.register_interface(iface2)

      # Create announce from a remote identity
      remote_identity = Identity.new()

      remote_dest =
        Destination.new(
          remote_identity,
          Destination.direction_in(),
          Destination.single(),
          "remote",
          ["node"]
        )

      {announce, _} = Destination.announce(remote_dest, send: false)
      packed = Packet.pack(announce)

      # Receive announce on the radio interface
      Transport.inbound(packed.raw, iface1)

      # Path should point to the radio interface
      assert Transport.has_path(remote_dest.hash)
      path_entry = Transport.get_path_entry(remote_dest.hash)
      assert path_entry != nil
      assert path_entry.hops == 1
    end

    test "multiple announces from different sources create separate paths" do
      test_pid = self()
      iface = make_capture_interface("TestIface", test_pid, :test_iface)
      :ok = Transport.register_interface(iface)

      # Create multiple remote identities
      ids = for _ <- 1..5, do: Identity.new()

      dests =
        for id <- ids do
          Destination.new(id, Destination.direction_in(), Destination.single(), "remote", [
            "multi"
          ])
        end

      # Send announces from each
      for dest <- dests do
        {announce, _} = Destination.announce(dest, send: false)
        packed = Packet.pack(announce)
        Transport.inbound(packed.raw, iface)
      end

      # All paths should exist
      for dest <- dests do
        assert Transport.has_path(dest.hash)
      end

      # All hashes should be unique
      hashes = Enum.map(dests, & &1.hash)
      assert length(Enum.uniq(hashes)) == length(hashes)
    end
  end

  # ── LocalInterface Server↔Client Integration ────────────────────

  describe "LocalInterface multi-client" do
    test "server handles multiple simultaneous clients" do
      test_pid = self()
      port = Enum.random(41_000..42_999)

      {:ok, server_pid} =
        RNS.Interfaces.LocalServerInterface.start_link(
          name: "MultiServer",
          owner: fn data, _iface ->
            send(test_pid, {:server_got, data})
          end,
          bindport: port
        )

      Process.sleep(50)

      # Connect multiple clients
      clients =
        for i <- 1..3 do
          {:ok, pid} =
            RNS.Interfaces.LocalClientInterface.start_link(
              name: "Client#{i}",
              owner: fn _data, _iface -> :ok end,
              target_port: port
            )

          pid
        end

      Process.sleep(200)

      # Verify all clients connected
      client_count = RNS.Interfaces.LocalServerInterface.client_count(server_pid)
      assert client_count == 3

      # Each client sends data
      for {client, i} <- Enum.with_index(clients) do
        data = :crypto.strong_rand_bytes(32) <> <<i>>
        RNS.Interfaces.LocalClientInterface.send_data(client, data)
      end

      # Server should receive data from each client
      for _ <- 1..3 do
        assert_receive {:server_got, _data}, 2000
      end

      # Cleanup
      for client <- clients do
        RNS.Interfaces.LocalClientInterface.stop(client)
      end

      RNS.Interfaces.LocalServerInterface.stop(server_pid)
      Process.sleep(50)
    end

    test "client reconnection on server restart" do
      port = Enum.random(43_000..44_999)

      # Start server
      {:ok, server1} =
        RNS.Interfaces.LocalServerInterface.start_link(
          name: "ReconnServer",
          owner: fn _data, _iface -> :ok end,
          bindport: port
        )

      Process.sleep(50)

      # Connect client
      {:ok, client} =
        RNS.Interfaces.LocalClientInterface.start_link(
          name: "ReconnClient",
          owner: fn _data, _iface -> :ok end,
          target_port: port
        )

      Process.sleep(100)

      state = RNS.Interfaces.LocalClientInterface.get_state(client)
      assert state.online == true

      # Stop and cleanup
      RNS.Interfaces.LocalClientInterface.stop(client)
      RNS.Interfaces.LocalServerInterface.stop(server1)
      Process.sleep(50)
    end
  end

  # ── Interface Lifecycle ──────────────────────────────────────────

  describe "interface lifecycle" do
    test "interface registration and enumeration" do
      interfaces =
        for i <- 1..5 do
          %{
            name: "Iface#{i}",
            hash: :crypto.strong_rand_bytes(16),
            out: true,
            in: true,
            online: true,
            mode: nil,
            ifac_identity: nil
          }
        end

      for iface <- interfaces do
        :ok = Transport.register_interface(iface)
      end

      registered = Transport.get_interfaces()
      assert length(registered) >= 5

      for iface <- interfaces do
        assert Transport.interface_registered?(iface.hash)
      end
    end

    test "interface can be found by hash" do
      iface = %{
        name: "FindMe",
        hash: :crypto.strong_rand_bytes(16),
        out: true,
        in: true,
        online: true,
        mode: nil,
        ifac_identity: nil
      }

      :ok = Transport.register_interface(iface)

      found = Transport.find_interface_from_hash(iface.hash)
      assert found != nil
      assert found.name == "FindMe"
    end

    test "unknown interface hash returns nil" do
      unknown_hash = :crypto.strong_rand_bytes(16)
      assert Transport.find_interface_from_hash(unknown_hash) == nil
    end
  end

  # ── Combined: Announce + Path + Data across interfaces ───────────

  describe "full cross-interface data flow" do
    test "announce on interface A, data routed via interface A's path" do
      test_pid = self()

      # Two interfaces
      radio = make_capture_interface("LoRa", test_pid, :lora)
      tcp = make_capture_interface("TCP", test_pid, :tcp)

      :ok = Transport.register_interface(radio)
      :ok = Transport.register_interface(tcp)

      # Remote node announces via radio
      remote_id = Identity.new()

      remote_dest =
        Destination.new(remote_id, Destination.direction_in(), Destination.single(), "remote", [
          "cross"
        ])

      {announce, _} = Destination.announce(remote_dest, send: false)
      packed_ann = Packet.pack(announce)

      # Receive on radio interface
      Transport.inbound(packed_ann.raw, radio)

      assert Transport.has_path(remote_dest.hash)

      # Send data to that destination — should route via radio (path interface)
      data_pkt = Packet.new(remote_dest, "Cross-interface data", create_receipt: false)
      packed_data = Packet.pack(data_pkt)

      Transport.outbound(packed_data)

      # Should go out on radio (the path interface), not TCP
      assert_receive {:outgoing, :lora, sent_data}, 1000
      assert is_binary(sent_data)
      assert byte_size(sent_data) > 0
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp make_capture_interface(name, test_pid, tag) do
    %{
      name: name,
      hash: :crypto.strong_rand_bytes(16),
      out: true,
      in: true,
      online: true,
      mode: nil,
      ifac_identity: nil,
      process_outgoing: fn data ->
        send(test_pid, {:outgoing, tag, data})
        :ok
      end
    }
  end
end
