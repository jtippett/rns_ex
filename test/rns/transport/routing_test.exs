defmodule RNS.Transport.RoutingTest do
  @moduledoc """
  Tests for RNS.Transport.Routing — pure routing decision functions.

  These tests verify routing logic WITHOUT starting any GenServers,
  ETS tables, or the supervision tree.
  """
  use ExUnit.Case, async: true

  alias RNS.Transport.Routing

  import Bitwise

  # ── Constants (matching Transport/Packet) ──────────────────────────────

  @packet_data 0x00
  @packet_announce 0x01
  @packet_linkrequest 0x02
  @packet_proof 0x03

  @dest_single 0x00
  @dest_group 0x01
  @dest_plain 0x02
  @dest_link 0x03

  @context_none 0x00
  @context_resource 0x01
  @context_keepalive 0xFA

  # ── should_use_path_table? ─────────────────────────────────────────────

  describe "should_use_path_table?/1" do
    test "returns false for announce packets" do
      packet = %{packet_type: @packet_announce, destination_type: @dest_single}
      refute Routing.should_use_path_table?(packet)
    end

    test "returns false for PLAIN destination" do
      packet = %{packet_type: @packet_data, destination_type: @dest_plain}
      refute Routing.should_use_path_table?(packet)
    end

    test "returns false for GROUP destination" do
      packet = %{packet_type: @packet_data, destination_type: @dest_group}
      refute Routing.should_use_path_table?(packet)
    end

    test "returns true for SINGLE data packet" do
      packet = %{packet_type: @packet_data, destination_type: @dest_single}
      assert Routing.should_use_path_table?(packet)
    end

    test "returns true for LINK data packet" do
      packet = %{packet_type: @packet_data, destination_type: @dest_link}
      assert Routing.should_use_path_table?(packet)
    end

    test "returns true for link request" do
      packet = %{packet_type: @packet_linkrequest, destination_type: @dest_single}
      assert Routing.should_use_path_table?(packet)
    end

    test "returns true for proof" do
      packet = %{packet_type: @packet_proof, destination_type: @dest_single}
      assert Routing.should_use_path_table?(packet)
    end
  end

  # ── should_generate_receipt? ───────────────────────────────────────────

  describe "should_generate_receipt?/1" do
    test "returns true for data packet with create_receipt and non-PLAIN dest" do
      packet = %{
        create_receipt: true,
        packet_type: @packet_data,
        destination_type: @dest_single,
        context: @context_none
      }

      assert Routing.should_generate_receipt?(packet)
    end

    test "returns false when create_receipt is false" do
      packet = %{
        create_receipt: false,
        packet_type: @packet_data,
        destination_type: @dest_single,
        context: @context_none
      }

      refute Routing.should_generate_receipt?(packet)
    end

    test "returns false when create_receipt is missing" do
      packet = %{
        packet_type: @packet_data,
        destination_type: @dest_single,
        context: @context_none
      }

      refute Routing.should_generate_receipt?(packet)
    end

    test "returns false for PLAIN destination" do
      packet = %{
        create_receipt: true,
        packet_type: @packet_data,
        destination_type: @dest_plain,
        context: @context_none
      }

      refute Routing.should_generate_receipt?(packet)
    end

    test "returns false for announce packets" do
      packet = %{
        create_receipt: true,
        packet_type: @packet_announce,
        destination_type: @dest_single,
        context: @context_none
      }

      refute Routing.should_generate_receipt?(packet)
    end

    test "returns false for keepalive context" do
      packet = %{
        create_receipt: true,
        packet_type: @packet_data,
        destination_type: @dest_single,
        context: @context_keepalive
      }

      refute Routing.should_generate_receipt?(packet)
    end

    test "returns false for resource context" do
      packet = %{
        create_receipt: true,
        packet_type: @packet_data,
        destination_type: @dest_single,
        context: @context_resource
      }

      refute Routing.should_generate_receipt?(packet)
    end
  end

  # ── determine_link_outbound_interface ──────────────────────────────────

  describe "determine_link_outbound_interface/2" do
    setup do
      iface_a = %{id: :interface_a}
      iface_b = %{id: :interface_b}

      link_entry = %{
        next_hop_interface: iface_a,
        received_on_interface: iface_b,
        remaining_hops: 3,
        taken_hops: 2
      }

      %{iface_a: iface_a, iface_b: iface_b, link_entry: link_entry}
    end

    test "routes from next-hop interface to received-on interface", ctx do
      packet = %{receiving_interface: ctx.iface_a, hops: ctx.link_entry.remaining_hops}

      result = Routing.determine_link_outbound_interface(packet, ctx.link_entry)
      assert result == ctx.iface_b
    end

    test "routes from received-on interface to next-hop interface", ctx do
      packet = %{receiving_interface: ctx.iface_b, hops: ctx.link_entry.taken_hops}

      result = Routing.determine_link_outbound_interface(packet, ctx.link_entry)
      assert result == ctx.iface_a
    end

    test "returns nil for wrong hop count from next-hop interface", ctx do
      packet = %{receiving_interface: ctx.iface_a, hops: 99}

      result = Routing.determine_link_outbound_interface(packet, ctx.link_entry)
      assert result == nil
    end

    test "returns nil for wrong hop count from received-on interface", ctx do
      packet = %{receiving_interface: ctx.iface_b, hops: 99}

      result = Routing.determine_link_outbound_interface(packet, ctx.link_entry)
      assert result == nil
    end

    test "returns nil for unknown interface", ctx do
      packet = %{receiving_interface: %{id: :unknown}, hops: 3}

      result = Routing.determine_link_outbound_interface(packet, ctx.link_entry)
      assert result == nil
    end

    test "handles same interface for both directions" do
      iface = %{id: :same}

      link_entry = %{
        next_hop_interface: iface,
        received_on_interface: iface,
        remaining_hops: 3,
        taken_hops: 2
      }

      # Matching remaining_hops
      packet = %{receiving_interface: iface, hops: 3}
      assert Routing.determine_link_outbound_interface(packet, link_entry) == iface

      # Matching taken_hops
      packet = %{receiving_interface: iface, hops: 2}
      assert Routing.determine_link_outbound_interface(packet, link_entry) == iface

      # Neither
      packet = %{receiving_interface: iface, hops: 99}
      assert Routing.determine_link_outbound_interface(packet, link_entry) == nil
    end
  end

  # ── IFAC Masking ───────────────────────────────────────────────────────

  describe "mask_ifac_payload/3 and unmask_ifac_payload/3" do
    test "masking preserves IFAC flag in first byte" do
      payload = <<0x80, 0x42, 0xAA, 0xBB, 0xCC, 0xDD>>
      mask = <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
      ifac_size = 1

      masked = Routing.mask_ifac_payload(payload, mask, ifac_size)

      # First byte: (0x80 XOR 0x11) OR 0x80 = 0x91 OR 0x80 = 0x91
      assert (hd(:binary.bin_to_list(masked)) &&& 0x80) == 0x80
    end

    test "masking does not modify IFAC bytes" do
      payload = <<0x80, 0x42, 0xAA, 0xBB, 0xCC, 0xDD>>
      mask = <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
      ifac_size = 1

      masked = Routing.mask_ifac_payload(payload, mask, ifac_size)
      bytes = :binary.bin_to_list(masked)

      # IFAC byte (index 2) should be unchanged
      assert Enum.at(bytes, 2) == 0xAA
    end

    test "mask and unmask are inverse operations (for header and payload)" do
      # Simulate outbound: header + ifac + payload
      payload = <<0x80, 0x42, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE>>
      mask = :crypto.strong_rand_bytes(7)
      ifac_size = 1

      masked = Routing.mask_ifac_payload(payload, mask, ifac_size)
      unmasked = Routing.unmask_ifac_payload(masked, mask, ifac_size)

      # Header bytes (0, 1) and payload bytes (after IFAC) should round-trip
      # IFAC bytes are unchanged in both directions
      payload_list = :binary.bin_to_list(payload)
      unmasked_list = :binary.bin_to_list(unmasked)

      # Second byte round-trips exactly
      assert Enum.at(unmasked_list, 1) == Enum.at(payload_list, 1)

      # IFAC byte unchanged
      assert Enum.at(unmasked_list, 2) == Enum.at(payload_list, 2)

      # Payload bytes after IFAC round-trip
      for i <- 3..6 do
        assert Enum.at(unmasked_list, i) == Enum.at(payload_list, i)
      end
    end

    test "unmask does not modify IFAC bytes" do
      payload = <<0x91, 0x60, 0xAA, 0xBB, 0xCC>>
      mask = <<0x11, 0x22, 0x33, 0x44, 0x55>>
      ifac_size = 1

      unmasked = Routing.unmask_ifac_payload(payload, mask, ifac_size)
      bytes = :binary.bin_to_list(unmasked)

      # IFAC byte (index 2) should be unchanged
      assert Enum.at(bytes, 2) == 0xAA
    end

    test "works with larger IFAC sizes" do
      payload = <<0x80, 0x42, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      mask = :crypto.strong_rand_bytes(8)
      ifac_size = 3

      masked = Routing.mask_ifac_payload(payload, mask, ifac_size)
      masked_bytes = :binary.bin_to_list(masked)

      # IFAC bytes (indices 2, 3, 4) should be unchanged
      payload_bytes = :binary.bin_to_list(payload)
      assert Enum.at(masked_bytes, 2) == Enum.at(payload_bytes, 2)
      assert Enum.at(masked_bytes, 3) == Enum.at(payload_bytes, 3)
      assert Enum.at(masked_bytes, 4) == Enum.at(payload_bytes, 4)
    end
  end
end
