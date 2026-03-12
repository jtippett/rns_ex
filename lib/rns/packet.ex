defmodule RNS.Packet do
  @moduledoc """
  Represents a packet in the Reticulum Network Stack.

  Packets are the fundamental unit of data transfer in Reticulum. They are
  automatically encrypted when addressed to SINGLE, GROUP, or LINK destinations.

  Matches `python/RNS/Packet.py`.
  """

  import Bitwise

  # ── Packet types ─────────────────────────────────────────────────

  @data 0x00
  @announce 0x01
  @linkrequest 0x02
  @proof 0x03
  @types [@data, @announce, @linkrequest, @proof]

  # ── Header types ─────────────────────────────────────────────────

  @header_1 0x00
  @header_2 0x01
  @header_types [@header_1, @header_2]

  # ── Context types ────────────────────────────────────────────────

  @context_none 0x00
  @context_resource 0x01
  @context_resource_adv 0x02
  @context_resource_req 0x03
  @context_resource_hmu 0x04
  @context_resource_prf 0x05
  @context_resource_icl 0x06
  @context_resource_rcl 0x07
  @context_cache_request 0x08
  @context_request 0x09
  @context_response 0x0A
  @context_path_response 0x0B
  @context_command 0x0C
  @context_command_status 0x0D
  @context_channel 0x0E
  @context_keepalive 0xFA
  @context_linkidentify 0xFB
  @context_linkclose 0xFC
  @context_linkproof 0xFD
  @context_lrrtt 0xFE
  @context_lrproof 0xFF

  # ── Flag constants ───────────────────────────────────────────────

  @flag_set 0x01
  @flag_unset 0x00

  # ── Size constants ───────────────────────────────────────────────

  @truncated_hashlength 128
  @dst_len div(@truncated_hashlength, 8)
  @mtu 500
  @header_maxsize 2 + 1 + @dst_len * 2
  @ifac_min_size 1
  @mdu @mtu - @header_maxsize - @ifac_min_size

  # Identity constants needed for ENCRYPTED_MDU calculation
  @token_overhead 48
  @identity_keysize 512
  @aes128_blocksize 16

  @encrypted_mdu div(@mdu - @token_overhead - div(@identity_keysize, 16), @aes128_blocksize) * @aes128_blocksize - 1
  @plain_mdu @mdu

  @timeout_per_hop 6

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

  @doc "Packet type: DATA (0x00)"
  @spec data() :: non_neg_integer()
  def data, do: @data

  @doc "Packet type: ANNOUNCE (0x01)"
  @spec announce() :: non_neg_integer()
  def announce, do: @announce

  @doc "Packet type: LINKREQUEST (0x02)"
  @spec linkrequest() :: non_neg_integer()
  def linkrequest, do: @linkrequest

  @doc "Packet type: PROOF (0x03)"
  @spec proof() :: non_neg_integer()
  def proof, do: @proof

  @doc "List of all packet types."
  @spec types() :: [non_neg_integer()]
  def types, do: @types

  @doc "Header type: HEADER_1 (0x00) — normal header."
  @spec header_1() :: non_neg_integer()
  def header_1, do: @header_1

  @doc "Header type: HEADER_2 (0x01) — transport header."
  @spec header_2() :: non_neg_integer()
  def header_2, do: @header_2

  @doc "List of all header types."
  @spec header_types() :: [non_neg_integer()]
  def header_types, do: @header_types

  @doc "Context: NONE (0x00)"
  @spec context_none() :: non_neg_integer()
  def context_none, do: @context_none

  @doc "Context: RESOURCE (0x01)"
  @spec context_resource() :: non_neg_integer()
  def context_resource, do: @context_resource

  @doc "Context: RESOURCE_ADV (0x02)"
  @spec context_resource_adv() :: non_neg_integer()
  def context_resource_adv, do: @context_resource_adv

  @doc "Context: RESOURCE_REQ (0x03)"
  @spec context_resource_req() :: non_neg_integer()
  def context_resource_req, do: @context_resource_req

  @doc "Context: RESOURCE_HMU (0x04)"
  @spec context_resource_hmu() :: non_neg_integer()
  def context_resource_hmu, do: @context_resource_hmu

  @doc "Context: RESOURCE_PRF (0x05)"
  @spec context_resource_prf() :: non_neg_integer()
  def context_resource_prf, do: @context_resource_prf

  @doc "Context: RESOURCE_ICL (0x06)"
  @spec context_resource_icl() :: non_neg_integer()
  def context_resource_icl, do: @context_resource_icl

  @doc "Context: RESOURCE_RCL (0x07)"
  @spec context_resource_rcl() :: non_neg_integer()
  def context_resource_rcl, do: @context_resource_rcl

  @doc "Context: CACHE_REQUEST (0x08)"
  @spec context_cache_request() :: non_neg_integer()
  def context_cache_request, do: @context_cache_request

  @doc "Context: REQUEST (0x09)"
  @spec context_request() :: non_neg_integer()
  def context_request, do: @context_request

  @doc "Context: RESPONSE (0x0A)"
  @spec context_response() :: non_neg_integer()
  def context_response, do: @context_response

  @doc "Context: PATH_RESPONSE (0x0B)"
  @spec context_path_response() :: non_neg_integer()
  def context_path_response, do: @context_path_response

  @doc "Context: COMMAND (0x0C)"
  @spec context_command() :: non_neg_integer()
  def context_command, do: @context_command

  @doc "Context: COMMAND_STATUS (0x0D)"
  @spec context_command_status() :: non_neg_integer()
  def context_command_status, do: @context_command_status

  @doc "Context: CHANNEL (0x0E)"
  @spec context_channel() :: non_neg_integer()
  def context_channel, do: @context_channel

  @doc "Context: KEEPALIVE (0xFA)"
  @spec context_keepalive() :: non_neg_integer()
  def context_keepalive, do: @context_keepalive

  @doc "Context: LINKIDENTIFY (0xFB)"
  @spec context_linkidentify() :: non_neg_integer()
  def context_linkidentify, do: @context_linkidentify

  @doc "Context: LINKCLOSE (0xFC)"
  @spec context_linkclose() :: non_neg_integer()
  def context_linkclose, do: @context_linkclose

  @doc "Context: LINKPROOF (0xFD)"
  @spec context_linkproof() :: non_neg_integer()
  def context_linkproof, do: @context_linkproof

  @doc "Context: LRRTT (0xFE)"
  @spec context_lrrtt() :: non_neg_integer()
  def context_lrrtt, do: @context_lrrtt

  @doc "Context: LRPROOF (0xFF)"
  @spec context_lrproof() :: non_neg_integer()
  def context_lrproof, do: @context_lrproof

  @doc "Flag value: SET (0x01)"
  @spec flag_set() :: non_neg_integer()
  def flag_set, do: @flag_set

  @doc "Flag value: UNSET (0x00)"
  @spec flag_unset() :: non_neg_integer()
  def flag_unset, do: @flag_unset

  @doc "Maximum header size in bytes (35)."
  @spec header_maxsize() :: non_neg_integer()
  def header_maxsize, do: @header_maxsize

  @doc "Maximum Transmission Unit in bytes (500)."
  @spec mtu() :: non_neg_integer()
  def mtu, do: @mtu

  @doc "Maximum Data Unit in bytes (464)."
  @spec mdu() :: non_neg_integer()
  def mdu, do: @mdu

  @doc "Maximum encrypted payload size in bytes (383)."
  @spec encrypted_mdu() :: non_neg_integer()
  def encrypted_mdu, do: @encrypted_mdu

  @doc "Maximum unencrypted payload size in bytes (equals MDU)."
  @spec plain_mdu() :: non_neg_integer()
  def plain_mdu, do: @plain_mdu

  @doc "Timeout per hop in seconds (6)."
  @spec timeout_per_hop() :: non_neg_integer()
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

    (packet.header_type <<< 6)
    ||| (packet.context_flag <<< 5)
    ||| (packet.transport_type <<< 4)
    ||| (dest_type <<< 2)
    ||| packet.packet_type
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

    packet = %{packet |
      destination_hash: destination_hash,
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
      packet_type = (flags &&& 0b00000011)

      {transport_id, destination_hash, context, data} =
        if header_type == @header_2 do
          <<tid::binary-size(@dst_len), dhash::binary-size(@dst_len), ctx::8, payload::binary>> = rest
          {tid, dhash, ctx, payload}
        else
          <<dhash::binary-size(@dst_len), ctx::8, payload::binary>> = rest
          {nil, dhash, ctx, payload}
        end

      packet = %{packet |
        flags: flags,
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
        RNS.log("Attempt to transmit over a closed link, dropping packet", RNS.log_debug())
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
      RNS.log("No interfaces could process the outbound packet", RNS.log_error())
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
      RNS.log("No interfaces could process the outbound packet", RNS.log_error())
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
        RNS.log("Could not prove packet associated with neither a destination nor a link", RNS.log_error())
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

  # ── Signal accessors ─────────────────────────────────────────────

  @doc "Returns the RSSI value if available."
  @spec get_rssi(t()) :: number() | nil
  def get_rssi(%__MODULE__{rssi: rssi}), do: rssi

  @doc "Returns the SNR value if available."
  @spec get_snr(t()) :: number() | nil
  def get_snr(%__MODULE__{snr: snr}), do: snr

  @doc "Returns the link quality value if available."
  @spec get_q(t()) :: number() | nil
  def get_q(%__MODULE__{q: q}), do: q
end
