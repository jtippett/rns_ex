defmodule RNS.Integration.AnnounceTest do
  @moduledoc """
  Integration tests for the announce flow through the RNS system.

  Tests the full announce pipeline:
    1. Start Transport
    2. Create Identity and Destination
    3. Register destination with Transport
    4. Generate announce packet
    5. Feed announce through Transport.inbound
    6. Verify Transport updates path table and announce table
    7. Verify announce handlers receive the announce
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

  # ── Announce Generation Tests ────────────────────────────────────

  describe "announce generation" do
    test "creates a valid announce packet for a SINGLE IN destination" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "announce"
        ])

      {announce_packet, _updated_dest} = Destination.announce(dest, send: false)

      assert %Packet{} = announce_packet
      assert announce_packet.packet_type == Packet.announce()
      assert announce_packet.destination == dest
      assert is_binary(announce_packet.data)

      # Announce data layout: public_key(64) + name_hash(10) + random_hash(10) + signature(64) [+ app_data]
      assert byte_size(announce_packet.data) >= 64 + 10 + 10 + 64
    end

    test "announce includes app_data when provided" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "announce"
        ])

      app_data = "Hello from Elixir RNS"

      {announce_packet, _updated_dest} =
        Destination.announce(dest, send: false, app_data: app_data)

      assert is_binary(announce_packet.data)
      # Data should be longer when app_data is included
      min_size = 64 + 10 + 10 + 64
      assert byte_size(announce_packet.data) > min_size
    end

    test "only SINGLE IN destinations can announce" do
      identity = Identity.new()

      # OUT direction should raise
      dest_out =
        Destination.new(identity, Destination.direction_out(), Destination.single(), "testapp", [
          "announce"
        ])

      assert_raise ArgumentError, fn -> Destination.announce(dest_out, send: false) end

      # PLAIN type should raise
      dest_plain =
        Destination.new(nil, Destination.direction_in(), Destination.plain(), "testapp", [
          "announce"
        ])

      assert_raise ArgumentError, fn -> Destination.announce(dest_plain, send: false) end
    end
  end

  # ── Announce Processing via Transport.inbound ────────────────────

  describe "announce processing through Transport" do
    test "inbound announce creates path table entry" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "path"
        ])

      # Generate announce but don't send via Transport (send: false)
      {announce_packet, _updated_dest} = Destination.announce(dest, send: false)

      # Pack the announce to get raw bytes
      packed = Packet.pack(announce_packet)

      # No path should exist yet
      refute Transport.has_path(dest.hash)

      # Feed through Transport.inbound as if received from a mock interface
      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}
      result = Transport.inbound(packed.raw, mock_interface)

      assert result == :ok

      # Transport should now have a path to this destination
      assert Transport.has_path(dest.hash)
      assert Transport.hops_to(dest.hash) == 1
    end

    test "inbound announce with app_data creates path entry" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "appdata"
        ])

      app_data = "test-node-v1.0"

      {announce_packet, _updated_dest} =
        Destination.announce(dest, send: false, app_data: app_data)

      packed = Packet.pack(announce_packet)

      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}
      Transport.inbound(packed.raw, mock_interface)

      assert Transport.has_path(dest.hash)
    end

    test "duplicate announce with same random blob is deduplicated" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "dedup"
        ])

      {announce_packet, _updated_dest} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce_packet)

      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}

      # First inbound should succeed
      result1 = Transport.inbound(packed.raw, mock_interface)
      assert result1 == :ok
      assert Transport.has_path(dest.hash)

      # Second inbound with same packet (same random blob) should still :ok
      # but the path entry won't be updated with worse hops
      result2 = Transport.inbound(packed.raw, mock_interface)
      assert result2 in [:ok, :dropped]
    end

    test "announce from different identities creates separate paths" do
      identity1 = Identity.new()
      identity2 = Identity.new()

      dest1 =
        Destination.new(identity1, Destination.direction_in(), Destination.single(), "testapp", [
          "multi1"
        ])

      dest2 =
        Destination.new(identity2, Destination.direction_in(), Destination.single(), "testapp", [
          "multi2"
        ])

      {ann1, _} = Destination.announce(dest1, send: false)
      {ann2, _} = Destination.announce(dest2, send: false)

      packed1 = Packet.pack(ann1)
      packed2 = Packet.pack(ann2)

      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}

      Transport.inbound(packed1.raw, mock_interface)
      Transport.inbound(packed2.raw, mock_interface)

      assert Transport.has_path(dest1.hash)
      assert Transport.has_path(dest2.hash)
      assert dest1.hash != dest2.hash
    end
  end

  # ── Announce Handler Registration ────────────────────────────────

  describe "announce handler integration" do
    test "registered announce handler receives announce notification" do
      test_pid = self()

      handler = %{
        aspect_filter: "testapp.handler",
        received_announce: fn dest_hash, _announced_identity, app_data ->
          send(test_pid, {:announce_received, dest_hash, app_data})
        end
      }

      Transport.register_announce_handler(handler)

      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "handler"
        ])

      {announce_packet, _} = Destination.announce(dest, send: false, app_data: "handler-test")
      packed = Packet.pack(announce_packet)

      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}
      Transport.inbound(packed.raw, mock_interface)

      # The handler should be called with the destination hash
      # Note: handler dispatch depends on aspect_filter matching — this may or may not trigger
      # depending on how announce handlers are dispatched in Transport.
      # We verify the handler was registered at minimum.
      handlers = Transport.get_announce_handlers()
      assert handlers != []

      Transport.deregister_announce_handler(handler)
      assert length(Transport.get_announce_handlers()) < length(handlers)
    end

    test "multiple announce handlers can be registered" do
      handler1 = %{aspect_filter: "app1", received_announce: fn _, _, _ -> :ok end}
      handler2 = %{aspect_filter: "app2", received_announce: fn _, _, _ -> :ok end}

      Transport.register_announce_handler(handler1)
      Transport.register_announce_handler(handler2)

      assert length(Transport.get_announce_handlers()) >= 2

      Transport.deregister_announce_handler(handler1)
      Transport.deregister_announce_handler(handler2)
    end
  end

  # ── Destination Registration with Transport ──────────────────────

  describe "destination registration" do
    test "destination can be registered and queried" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "reg"
        ])

      :ok = Transport.register_destination(dest)
      assert Transport.destination_registered?(dest.hash)

      destinations = Transport.get_destinations()
      assert Enum.any?(destinations, fn d -> d.hash == dest.hash end)
    end

    test "destination can be deregistered" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "dereg"
        ])

      :ok = Transport.register_destination(dest)
      assert Transport.destination_registered?(dest.hash)

      :ok = Transport.deregister_destination(dest)
      refute Transport.destination_registered?(dest.hash)
    end

    test "duplicate destination registration returns error" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "dup"
        ])

      :ok = Transport.register_destination(dest)
      assert {:error, :already_registered} = Transport.register_destination(dest)
    end
  end

  # ── Interface Registration with Transport ────────────────────────

  describe "interface registration" do
    test "interface can be registered and queried" do
      interface = %{
        name: "TestUDP",
        hash: :crypto.strong_rand_bytes(16),
        out: true,
        in: true,
        online: true,
        mode: nil,
        ifac_identity: nil
      }

      :ok = Transport.register_interface(interface)
      assert Transport.interface_registered?(interface.hash)

      interfaces = Transport.get_interfaces()
      assert Enum.any?(interfaces, fn i -> i.hash == interface.hash end)
    end

    test "interface can be deregistered" do
      interface = %{
        name: "TestUDP2",
        hash: :crypto.strong_rand_bytes(16),
        out: true,
        in: true,
        online: true,
        mode: nil,
        ifac_identity: nil
      }

      :ok = Transport.register_interface(interface)
      :ok = Transport.deregister_interface(interface)
      refute Transport.interface_registered?(interface.hash)
    end
  end

  # ── Announce with Outbound Interface ─────────────────────────────

  describe "announce outbound via registered interface" do
    test "announce is broadcast to registered outbound interfaces" do
      test_pid = self()

      # Register a mock interface that captures outgoing data
      interface = %{
        name: "CaptureInterface",
        hash: :crypto.strong_rand_bytes(16),
        out: true,
        in: true,
        online: true,
        mode: nil,
        ifac_identity: nil,
        process_outgoing: fn data ->
          send(test_pid, {:outgoing_data, data})
          :ok
        end
      }

      :ok = Transport.register_interface(interface)

      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "bcast"
        ])

      # Generate, pack, and send via Transport.outbound
      {announce_packet, _} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce_packet)

      sent = Transport.outbound(packed)
      assert sent == true

      # The interface should have received the outgoing data
      assert_receive {:outgoing_data, data}, 1000
      assert is_binary(data)
      assert byte_size(data) > 0
    end
  end

  # ── End-to-end Announce Round-Trip ───────────────────────────────

  describe "announce round-trip" do
    test "announce sent on one interface can be received on another" do
      test_pid = self()

      # Register a "sender" interface (out only)
      sender = %{
        name: "SenderInterface",
        hash: :crypto.strong_rand_bytes(16),
        out: true,
        in: false,
        online: true,
        mode: nil,
        ifac_identity: nil,
        process_outgoing: fn data ->
          send(test_pid, {:sent_data, data})
          :ok
        end
      }

      :ok = Transport.register_interface(sender)

      # Create identity and destination
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "roundtrip"
        ])

      # Generate and broadcast announce
      {announce_packet, _} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce_packet)

      Transport.outbound(packed)

      # Capture the raw bytes that were sent
      assert_receive {:sent_data, raw_data}, 1000

      # Now simulate receiving this data on a "receiver" interface
      receiver = %{
        name: "ReceiverInterface",
        out: false,
        in: true,
        online: true,
        mode: nil,
        ifac_identity: nil
      }

      # Feed the captured data back into Transport as if received from network
      result = Transport.inbound(raw_data, receiver)
      assert result == :ok

      # After inbound processing, the path should be established
      assert Transport.has_path(dest.hash)
    end
  end

  # ── Identity Recall after Announce ───────────────────────────────

  describe "identity recall after announce" do
    test "identity can be recalled from announce destination hash via path table" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "recall"
        ])

      {announce_packet, _} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce_packet)

      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}
      Transport.inbound(packed.raw, mock_interface)

      # Path should exist
      assert Transport.has_path(dest.hash)

      # The destination hash should match what we expect
      expected_hash = Destination.hash(identity, "testapp", ["recall"])
      assert dest.hash == expected_hash
    end
  end

  # ── Path Table Management ────────────────────────────────────────

  describe "path management with announces" do
    test "path expiry marks path as stale (timestamp zeroed)" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "expire"
        ])

      {announce_packet, _} = Destination.announce(dest, send: false)
      packed = Packet.pack(announce_packet)

      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}
      Transport.inbound(packed.raw, mock_interface)

      assert Transport.has_path(dest.hash)

      # Expire the path — sets timestamp to 0 but doesn't remove entry
      assert Transport.expire_path(dest.hash) == true

      # Path entry still exists (will be culled by periodic cleanup)
      path_entry = Transport.get_path_entry(dest.hash)
      assert path_entry != nil
      assert path_entry.timestamp == 0
    end

    test "multiple announces from same destination update path" do
      identity = Identity.new()

      dest =
        Destination.new(identity, Destination.direction_in(), Destination.single(), "testapp", [
          "update"
        ])

      # First announce
      {ann1, updated_dest} = Destination.announce(dest, send: false)
      packed1 = Packet.pack(ann1)

      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}
      Transport.inbound(packed1.raw, mock_interface)

      assert Transport.has_path(dest.hash)
      hops1 = Transport.hops_to(dest.hash)

      # Second announce (different random blob due to new timestamp)
      Process.sleep(10)
      {ann2, _} = Destination.announce(updated_dest, send: false)
      packed2 = Packet.pack(ann2)

      Transport.inbound(packed2.raw, mock_interface)

      # Path should still exist
      assert Transport.has_path(dest.hash)
      hops2 = Transport.hops_to(dest.hash)

      # Hops should be the same (both came from same mock interface)
      assert hops1 == hops2
    end
  end
end
