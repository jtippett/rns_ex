defmodule RNS.Transport.Routing do
  @moduledoc """
  Pure routing decision functions for RNS Transport.

  All functions in this module are pure data transformations — no ETS access,
  no GenServer calls, no process messaging. This allows routing logic to be
  unit-tested without starting the supervision tree.
  """

  import Bitwise

  # ── Packet/Destination constants (must match Transport) ────────────────

  @packet_data 0x00
  @packet_announce 0x01

  @dest_plain 0x02
  @dest_group 0x01

  @context_resource 0x01
  @context_resource_rcl 0x07
  @context_keepalive 0xFA
  @context_lrproof 0xFF

  # ── Routing Predicates ─────────────────────────────────────────────────

  @doc """
  Determines whether a packet should use the path table for routing.

  Returns `false` for announces (always broadcast), PLAIN destinations
  (local-only), and GROUP destinations (local-only). All other packets
  use the path table if a path is known.
  """
  @spec should_use_path_table?(map()) :: boolean()
  def should_use_path_table?(packet) do
    packet.packet_type != @packet_announce and
      packet.destination_type != @dest_plain and
      packet.destination_type != @dest_group
  end

  @doc """
  Determines whether a packet should generate a delivery receipt.

  Receipts are generated for DATA packets to non-PLAIN destinations that
  have `create_receipt: true` and are not in keepalive/resource contexts.
  """
  @spec should_generate_receipt?(map()) :: boolean()
  def should_generate_receipt?(packet) do
    Map.get(packet, :create_receipt, false) and
      packet.packet_type == @packet_data and
      packet.destination_type != @dest_plain and
      not (packet.context >= @context_keepalive and packet.context <= @context_lrproof) and
      not (packet.context >= @context_resource and packet.context <= @context_resource_rcl)
  end

  @doc """
  Determines the outbound interface for link transport routing.

  Given a packet and a link table entry, returns the interface to transmit
  on based on hop counts and direction of travel. Returns `nil` if the
  packet doesn't match the expected hop pattern.

  This is the pure decision logic extracted from Transport's link routing.
  """
  @spec determine_link_outbound_interface(map(), map()) :: map() | nil
  def determine_link_outbound_interface(packet, link_entry) do
    cond do
      # Same interface for both directions: check hop count matches
      link_entry.next_hop_interface == link_entry.received_on_interface ->
        if packet.hops == link_entry.remaining_hops or packet.hops == link_entry.taken_hops do
          link_entry.next_hop_interface
        else
          nil
        end

      # Received on next-hop interface: send to received-on interface
      packet.receiving_interface == link_entry.next_hop_interface ->
        if packet.hops == link_entry.remaining_hops do
          link_entry.received_on_interface
        else
          nil
        end

      # Received on received-on interface: send to next-hop interface
      packet.receiving_interface == link_entry.received_on_interface ->
        if packet.hops == link_entry.taken_hops do
          link_entry.next_hop_interface
        else
          nil
        end

      true ->
        nil
    end
  end

  # ── IFAC Masking ───────────────────────────────────────────────────────

  @doc """
  Masks an IFAC (Interface Access Code) payload for outbound transmission.

  XORs the payload with the mask, preserving:
  - The IFAC flag bit (0x80) in the first byte
  - The IFAC bytes themselves (between header and payload)

  All inputs and outputs are binaries. This is a pure transformation.
  """
  @spec mask_ifac_payload(binary(), binary(), non_neg_integer()) :: binary()
  def mask_ifac_payload(payload, mask, ifac_size) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} ->
      mask_byte = :binary.at(mask, i)

      cond do
        # First byte: mask but keep IFAC flag set
        i == 0 -> bxor(byte, mask_byte) ||| 0x80
        # Second byte and payload (after IFAC): mask
        i == 1 or i > ifac_size + 1 -> bxor(byte, mask_byte)
        # IFAC itself: don't mask
        true -> byte
      end
    end)
    |> :binary.list_to_bin()
  end

  @doc """
  Unmasks an IFAC payload received from an interface.

  Reverses the masking applied by `mask_ifac_payload/3`, XORing header
  and payload bytes while preserving the IFAC bytes.
  """
  @spec unmask_ifac_payload(binary(), binary(), non_neg_integer()) :: binary()
  def unmask_ifac_payload(payload, mask, ifac_size) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} ->
      mask_byte = :binary.at(mask, i)

      if i <= 1 or i > ifac_size + 1 do
        bxor(byte, mask_byte)
      else
        byte
      end
    end)
    |> :binary.list_to_bin()
  end
end
