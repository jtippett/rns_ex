defmodule RNS.Packet do
  @moduledoc """
  Represents a packet in the Reticulum Network Stack.

  Packets are the fundamental unit of data transfer in Reticulum. They are
  automatically encrypted when addressed to SINGLE, GROUP, or LINK destinations.

  Matches `python/RNS/Packet.py`.
  """

  import Bitwise

  use RNS.Constants.Packet

  @types [@data, @announce, @linkrequest, @proof]
  @header_types [@header_1, @header_2]

  # ── Destination type constants (from Destination module) ─────────

  @dest_link 0x03
  @dest_single 0x00

  # ── Transport type constants ─────────────────────────────────────

  @transport_broadcast 0x00

  # ── Struct ───────────────────────────────────────────────────────

  defstruct [
    :hops,
    :header,
    :header_type,
    :packet_type,
    :transport_type,
    :context,
    :context_flag,
    :destination,
    :transport_id,
    :data,
    :flags,
    :raw,
    :packed,
    :sent,
    :create_receipt,
    :receipt,
    :from_packed,
    :mtu,
    :sent_at,
    :packet_hash,
    :ratchet_id,
    :attached_interface,
    :receiving_interface,
    :rssi,
    :snr,
    :q,
    :ciphertext,
    :plaintext,
    :destination_hash,
    :destination_type,
    :link,
    :map_hash
  ]

  @type t :: %__MODULE__{}

  # ── Constant accessors ──────────────────────────────────────────
  # For cross-module use, prefer `use RNS.Constants.Packet` which
  # injects compile-time module attributes. These functions are
  # retained for backward compatibility and public API usage.

  def data, do: @data
  def announce, do: @announce
  def linkrequest, do: @linkrequest
  def proof, do: @proof
  def types, do: @types
  def header_1, do: @header_1
  def header_2, do: @header_2
  def header_types, do: @header_types
  def context_none, do: @context_none
  def context_resource, do: @context_resource
  def context_resource_adv, do: @context_resource_adv
  def context_resource_req, do: @context_resource_req
  def context_resource_hmu, do: @context_resource_hmu
  def context_resource_prf, do: @context_resource_prf
  def context_resource_icl, do: @context_resource_icl
  def context_resource_rcl, do: @context_resource_rcl
  def context_cache_request, do: @context_cache_request
  def context_request, do: @context_request
  def context_response, do: @context_response
  def context_path_response, do: @context_path_response
  def context_command, do: @context_command
  def context_command_status, do: @context_command_status
  def context_channel, do: @context_channel
  def context_keepalive, do: @context_keepalive
  def context_linkidentify, do: @context_linkidentify
  def context_linkclose, do: @context_linkclose
  def context_linkproof, do: @context_linkproof
  def context_lrrtt, do: @context_lrrtt
  def context_lrproof, do: @context_lrproof
  def flag_set, do: @flag_set
  def flag_unset, do: @flag_unset
  def header_maxsize, do: @header_maxsize
  def mtu, do: @mtu
  def mdu, do: @mdu
  def encrypted_mdu, do: @encrypted_mdu
  def plain_mdu, do: @plain_mdu
  def timeout_per_hop, do: @timeout_per_hop

  # ── Construction ─────────────────────────────────────────────────

  @doc """
  Creates a new Packet.

  When `destination` is non-nil, creates a packet to be sent.
  When `destination` is nil, `data` is treated as raw packed bytes for unpacking.

  ## Options

    * `:packet_type` - packet type (default: DATA)
    * `:context` - context type (default: NONE)
    * `:transport_type` - transport type (default: BROADCAST)
    * `:header_type` - header type (default: HEADER_1)
    * `:transport_id` - transport ID for HEADER_2 packets
    * `:attached_interface` - the interface to send on
    * `:create_receipt` - whether to create a receipt (default: true)
    * `:context_flag` - context flag (default: FLAG_UNSET)
  """
  @spec new(map() | nil, binary(), keyword()) :: t()
  def new(destination, data, opts \\ [])

  def new(nil, raw_data, _opts) do
    %__MODULE__{
      raw: raw_data,
      packed: true,
      from_packed: true,
      create_receipt: false,
      sent_at: nil,
      packet_hash: nil,
      ratchet_id: nil,
      attached_interface: nil,
      receiving_interface: nil,
      rssi: nil,
      snr: nil,
      q: nil
    }
  end

  def new(destination, data, opts) do
    transport_type = Keyword.get(opts, :transport_type) || @transport_broadcast
    header_type = Keyword.get(opts, :header_type, @header_1)
    packet_type = Keyword.get(opts, :packet_type, @data)
    context = Keyword.get(opts, :context, @context_none)
    context_flag = Keyword.get(opts, :context_flag, @flag_unset)
    transport_id = Keyword.get(opts, :transport_id)
    attached_interface = Keyword.get(opts, :attached_interface)
    create_receipt = Keyword.get(opts, :create_receipt, true)

    dest_type = Map.get(destination, :type, @dest_single)

    pkt_mtu =
      if dest_type == @dest_link do
        Map.get(destination, :mtu) || @mtu
      else
        @mtu
      end

    packet = %__MODULE__{
      header_type: header_type,
      packet_type: packet_type,
      transport_type: transport_type,
      context: context,
      context_flag: context_flag,
      hops: 0,
      destination: destination,
      transport_id: transport_id,
      data: data,
      raw: nil,
      packed: false,
      sent: false,
      create_receipt: create_receipt,
      receipt: nil,
      from_packed: false,
      mtu: pkt_mtu,
      sent_at: nil,
      packet_hash: nil,
      ratchet_id: nil,
      attached_interface: attached_interface,
      receiving_interface: nil,
      rssi: nil,
      snr: nil,
      q: nil
    }

    %{packet | flags: get_packed_flags(packet)}
  end

  # ── Flags ────────────────────────────────────────────────────────

  @doc """
  Computes the packed flags byte for a packet.
  """
  @spec get_packed_flags(t()) :: non_neg_integer()
  def get_packed_flags(%__MODULE__{} = packet) do
    dest_type =
      if packet.context == @context_lrproof do
        @dest_link
      else
        Map.get(packet.destination, :type, @dest_single)
      end

    packet.header_type <<< 6 |||
      packet.context_flag <<< 5 |||
      packet.transport_type <<< 4 |||
      dest_type <<< 2 |||
      packet.packet_type
  end

  # ── Pack ─────────────────────────────────────────────────────────

  @doc """
  Packs the packet into its raw binary representation.

  Returns the updated packet with `:raw`, `:packed`, `:ciphertext`,
  `:destination_hash`, and `:packet_hash` set.
  """
  @spec pack(t()) :: t()
  def pack(%__MODULE__{} = packet) do
    destination_hash = Map.get(packet.destination, :hash)
    flags = get_packed_flags(packet)

    header = <<flags::8, packet.hops::8>>

    {header, ciphertext, ratchet_id} =
      if packet.context == @context_lrproof do
        link_id = Map.get(packet.destination, :link_id)
        {header <> link_id, packet.data, packet.ratchet_id}
      else
        pack_by_header_type(packet, header, destination_hash)
      end

    header = header <> <<packet.context::8>>
    raw = header <> ciphertext

    if byte_size(raw) > packet.mtu do
      raise "Packet size of #{byte_size(raw)} exceeds MTU of #{packet.mtu} bytes"
    end

    packet = %{
      packet
      | destination_hash: destination_hash,
        header: header,
        flags: flags,
        ciphertext: ciphertext,
        raw: raw,
        packed: true,
        ratchet_id: ratchet_id
    }

    update_hash(packet)
  end

  defp pack_by_header_type(%__MODULE__{header_type: @header_1} = packet, header, dest_hash) do
    header = header <> dest_hash
    {ciphertext, ratchet_id} = encrypt_for_pack(packet)
    {header, ciphertext, ratchet_id}
  end

  defp pack_by_header_type(%__MODULE__{header_type: @header_2} = packet, header, dest_hash) do
    if packet.transport_id == nil do
      raise "Packet with header type 2 must have a transport ID"
    end

    header = header <> packet.transport_id <> dest_hash

    ciphertext =
      if packet.packet_type == @announce do
        packet.data
      else
        packet.data
      end

    {header, ciphertext, packet.ratchet_id}
  end

  defp encrypt_for_pack(%__MODULE__{} = packet) do
    cond do
      packet.packet_type == @announce ->
        {packet.data, packet.ratchet_id}

      packet.packet_type == @linkrequest ->
        {packet.data, packet.ratchet_id}

      packet.packet_type == @proof and packet.context == @context_resource_prf ->
        {packet.data, packet.ratchet_id}

      packet.packet_type == @proof and Map.get(packet.destination, :type) == @dest_link ->
        {packet.data, packet.ratchet_id}

      packet.context == @context_resource ->
        {packet.data, packet.ratchet_id}

      packet.context == @context_keepalive ->
        {packet.data, packet.ratchet_id}

      packet.context == @context_cache_request ->
        {packet.data, packet.ratchet_id}

      true ->
        # Encrypt with destination's encryption method
        encrypt_fn = Map.get(packet.destination, :encrypt)

        ciphertext =
          if is_function(encrypt_fn, 1) do
            encrypt_fn.(packet.data)
          else
            packet.data
          end

        ratchet_id =
          case Map.get(packet.destination, :latest_ratchet_id) do
            nil -> packet.ratchet_id
            id -> id
          end

        {ciphertext, ratchet_id}
    end
  end

  # ── Unpack ───────────────────────────────────────────────────────

  @doc """
  Unpacks a raw binary packet into its component fields.

  Returns the updated packet with all header fields set, or `false` if
  the packet is malformed.
  """
  @spec unpack(t()) :: t() | false
  def unpack(%__MODULE__{raw: raw} = packet) do
    try do
      <<flags::8, hops::8, rest::binary>> = raw

      header_type = (flags &&& 0b01000000) >>> 6
      context_flag = (flags &&& 0b00100000) >>> 5
      transport_type = (flags &&& 0b00010000) >>> 4
      destination_type = (flags &&& 0b00001100) >>> 2
      packet_type = flags &&& 0b00000011

      {transport_id, destination_hash, context, data} =
        if header_type == @header_2 do
          <<tid::binary-size(@dst_len), dhash::binary-size(@dst_len), ctx::8, payload::binary>> =
            rest

          {tid, dhash, ctx, payload}
        else
          <<dhash::binary-size(@dst_len), ctx::8, payload::binary>> = rest
          {nil, dhash, ctx, payload}
        end

      packet = %{
        packet
        | flags: flags,
          hops: hops,
          header_type: header_type,
          context_flag: context_flag,
          transport_type: transport_type,
          destination_type: destination_type,
          packet_type: packet_type,
          transport_id: transport_id,
          destination_hash: destination_hash,
          context: context,
          data: data,
          packed: false
      }

      update_hash(packet)
    rescue
      _ -> false
    end
  end

  # ── Hash computation ─────────────────────────────────────────────

  @doc """
  Returns the full SHA-256 hash of the packet's hashable part.
  """
  @spec get_hash(t()) :: binary()
  def get_hash(%__MODULE__{} = packet) do
    RNS.Identity.full_hash(get_hashable_part(packet))
  end

  @doc """
  Returns the truncated (16-byte) hash of the packet's hashable part.
  """
  @spec get_truncated_hash(t()) :: binary()
  def get_truncated_hash(%__MODULE__{} = packet) do
    RNS.Identity.truncated_hash(get_hashable_part(packet))
  end

  @doc """
  Returns the hashable portion of the packet.

  For HEADER_1: lower nibble of flags byte + everything after flags+hops.
  For HEADER_2: lower nibble of flags byte + everything after flags+hops+transport_id.
  """
  @spec get_hashable_part(t()) :: binary()
  def get_hashable_part(%__MODULE__{raw: raw} = packet) do
    masked_flags = :binary.at(raw, 0) &&& 0x0F

    rest =
      if packet.header_type == @header_2 do
        binary_part(raw, @dst_len + 2, byte_size(raw) - @dst_len - 2)
      else
        binary_part(raw, 2, byte_size(raw) - 2)
      end

    <<masked_flags::8>> <> rest
  end

  @doc """
  Updates the packet's stored hash.
  """
  @spec update_hash(t()) :: t()
  def update_hash(%__MODULE__{} = packet) do
    %{packet | packet_hash: get_hash(packet)}
  end

  # ── Send / Resend ────────────────────────────────────────────────

  @doc """
  Sends the packet via Transport.

  Returns a PacketReceipt if create_receipt is true, nil otherwise,
  or false if the packet could not be sent.
  """
  @spec send(t()) :: RNS.PacketReceipt.t() | nil | false
  def send(%__MODULE__{sent: true}) do
    raise "Packet was already sent"
  end

  def send(%__MODULE__{} = packet) do
    dest_type = Map.get(packet.destination, :type)

    if dest_type == @dest_link do
      dest_status = Map.get(packet.destination, :status)

      # Link.CLOSED = 0x04
      if dest_status == 0x04 do
        RNS.Log.log("Attempt to transmit over a closed link, dropping packet", :debug)
        false
      else
        do_send(packet)
      end
    else
      do_send(packet)
    end
  end

  defp do_send(packet) do
    packet = if not packet.packed, do: pack(packet), else: packet

    # Transport.outbound/1 will be implemented in Phase 4
    if transport_outbound(packet) do
      packet.receipt
    else
      RNS.Log.log("No interfaces could process the outbound packet", :error)
      false
    end
  end

  @doc false
  def transport_outbound(_packet) do
    # Placeholder — will delegate to RNS.Transport.outbound/1 in Phase 4
    false
  end

  @doc """
  Re-sends an already-sent packet.
  """
  @spec resend(t()) :: RNS.PacketReceipt.t() | nil | false
  def resend(%__MODULE__{sent: false}) do
    raise "Packet was not sent yet"
  end

  def resend(%__MODULE__{} = packet) do
    packet = pack(packet)

    if transport_outbound(packet) do
      packet.receipt
    else
      RNS.Log.log("No interfaces could process the outbound packet", :error)
      false
    end
  end

  # ── Prove ────────────────────────────────────────────────────────

  @doc """
  Generates and sends a proof for this packet.
  """
  @spec prove(t(), map() | nil) :: :ok | :error
  def prove(packet, destination \\ nil)

  def prove(%__MODULE__{from_packed: true, destination: dest} = packet, _destination)
      when dest != nil do
    identity = Map.get(dest, :identity)

    cond do
      identity != nil and Map.get(identity, :prv_bytes) != nil ->
        # Destination-based proof — will delegate to Identity.prove in Phase 3
        :ok

      Map.get(packet, :link) != nil ->
        # Link-based proof
        :ok

      true ->
        RNS.Log.log(
          "Could not prove packet associated with neither a destination nor a link",
          :error
        )

        :error
    end
  end

  def prove(%__MODULE__{}, _destination), do: :error

  @doc """
  Generates a ProofDestination for routing proofs back to this packet's sender.
  """
  @spec generate_proof_destination(t()) :: RNS.ProofDestination.t()
  def generate_proof_destination(%__MODULE__{} = packet) do
    RNS.ProofDestination.new(packet)
  end

end
