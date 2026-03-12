defmodule RNS.Link.Callbacks do
  @moduledoc "Holds callback functions for link events."

  defstruct [
    :link_established,
    :link_closed,
    :packet,
    :resource,
    :resource_started,
    :resource_concluded,
    :remote_identified
  ]

  @type t :: %__MODULE__{
          link_established: function() | nil,
          link_closed: function() | nil,
          packet: function() | nil,
          resource: function() | nil,
          resource_started: function() | nil,
          resource_concluded: function() | nil,
          remote_identified: function() | nil
        }
end

defmodule RNS.Link do
  @moduledoc """
  Represents and manages links in the Reticulum Network Stack.

  Links provide encrypted, authenticated, bidirectional communication channels
  between two endpoints. They use a 3-step ECDH handshake:

  1. Initiator generates ephemeral X25519 keypair, sends link request
  2. Responder validates, generates own keypair, derives shared secret, sends proof
  3. Initiator verifies proof, derives same shared secret

  This module covers establishment and encryption (Task 5.2).
  Lifecycle management (keepalive, teardown, stale detection) is Task 5.3.

  Matches `python/RNS/Link.py`.
  """

  import Bitwise

  alias RNS.Cryptography.X25519
  alias RNS.Cryptography.Ed25519
  alias RNS.Cryptography.Token
  alias RNS.Cryptography.HKDF
  alias RNS.Identity

  # ── Size constants ──────────────────────────────────────────────

  @ecpubsize 32 + 32
  @keysize 32
  @link_mtu_size 3

  # ── Status constants ────────────────────────────────────────────

  @status_pending 0x00
  @status_handshake 0x01
  @status_active 0x02
  @status_stale 0x03
  @status_closed 0x04

  # ── Teardown reason constants ───────────────────────────────────

  @timeout 0x01
  @initiator_closed 0x02
  @destination_closed 0x03

  # ── Resource strategy constants ─────────────────────────────────

  @accept_none 0x00
  @accept_app 0x01
  @accept_all 0x02

  # ── Encryption mode constants ───────────────────────────────────

  @mode_aes128_cbc 0x00
  @mode_aes256_cbc 0x01
  @mode_aes256_gcm 0x02
  @mode_otp_reserved 0x03
  @mode_pq_reserved_1 0x04
  @mode_pq_reserved_2 0x05
  @mode_pq_reserved_3 0x06
  @mode_pq_reserved_4 0x07
  @enabled_modes [@mode_aes256_cbc]
  @mode_default @mode_aes256_cbc
  @mode_descriptions %{
    @mode_aes128_cbc => "AES_128_CBC",
    @mode_aes256_cbc => "AES_256_CBC",
    @mode_aes256_gcm => "MODE_AES256_GCM",
    @mode_otp_reserved => "MODE_OTP_RESERVED",
    @mode_pq_reserved_1 => "MODE_PQ_RESERVED_1",
    @mode_pq_reserved_2 => "MODE_PQ_RESERVED_2",
    @mode_pq_reserved_3 => "MODE_PQ_RESERVED_3",
    @mode_pq_reserved_4 => "MODE_PQ_RESERVED_4"
  }

  # ── MTU/mode byte masks ─────────────────────────────────────────

  @mtu_bytemask 0x1FFFFF
  @mode_bytemask 0xE0

  # ── Keepalive / timing constants ────────────────────────────────

  @keepalive_max 360
  @keepalive_min 5
  @keepalive @keepalive_max
  @stale_factor 2
  @stale_time @stale_factor * @keepalive
  @keepalive_max_rtt 1.75
  @keepalive_timeout_factor 4
  @stale_grace 5
  @traffic_timeout_factor 6
  @traffic_timeout_min_ms 5
  @watchdog_max_sleep 5

  @establishment_timeout_per_hop RNS.Packet.timeout_per_hop()

  # ── MDU calculation ─────────────────────────────────────────────

  @mtu 500
  @ifac_min_size 1
  @header_minsize 2 + 1 + div(128, 8)
  @token_overhead 48
  @aes128_blocksize 16

  @link_mdu div(@mtu - @ifac_min_size - @header_minsize - @token_overhead, @aes128_blocksize) *
              @aes128_blocksize - 1

  # ── Response grace time (from Resource, placeholder until Task 5.4) ─
  @response_max_grace_time 10

  # ── Struct ──────────────────────────────────────────────────────

  defstruct [
    :link_id,
    :hash,
    :destination,
    :owner,
    :attached_interface,
    :prv,
    :pub_bytes,
    :sig_prv,
    :sig_pub_bytes,
    :peer_pub_bytes,
    :peer_sig_pub_bytes,
    :shared_key,
    :derived_key,
    :token,
    :rtt,
    :remote_identity,
    :channel,
    :activated_at,
    :request_time,
    :teardown_reason,
    :expected_hops,
    :rssi,
    :snr,
    :q,
    :establishment_rate,
    status: @status_pending,
    initiator: false,
    mode: @mode_default,
    mtu: @mtu,
    mdu: @link_mdu,
    establishment_cost: 0,
    expected_rate: nil,
    resource_strategy: @accept_none,
    last_resource_window: nil,
    last_resource_eifr: nil,
    outgoing_resources: [],
    incoming_resources: [],
    pending_requests: [],
    last_inbound: 0,
    last_outbound: 0,
    last_keepalive: 0,
    last_proof: 0,
    last_data: 0,
    tx: 0,
    rx: 0,
    txbytes: 0,
    rxbytes: 0,
    traffic_timeout_factor: @traffic_timeout_factor,
    keepalive_timeout_factor: @keepalive_timeout_factor,
    keepalive: @keepalive,
    stale_time: @stale_time,
    track_phy_stats: false,
    type: 0x03,
    callbacks: nil
  ]

  @type t :: %__MODULE__{}

  # ── Constant accessors ─────────────────────────────────────────

  @spec ecpubsize() :: non_neg_integer()
  def ecpubsize, do: @ecpubsize

  @spec keysize() :: non_neg_integer()
  def keysize, do: @keysize

  @spec link_mtu_size() :: non_neg_integer()
  def link_mtu_size, do: @link_mtu_size

  @spec pending() :: non_neg_integer()
  def pending, do: @status_pending

  @spec handshake() :: non_neg_integer()
  def handshake, do: @status_handshake

  @spec active() :: non_neg_integer()
  def active, do: @status_active

  @spec stale() :: non_neg_integer()
  def stale, do: @status_stale

  @spec closed() :: non_neg_integer()
  def closed, do: @status_closed

  @spec timeout() :: non_neg_integer()
  def timeout, do: @timeout

  @spec initiator_closed() :: non_neg_integer()
  def initiator_closed, do: @initiator_closed

  @spec destination_closed() :: non_neg_integer()
  def destination_closed, do: @destination_closed

  @spec accept_none() :: non_neg_integer()
  def accept_none, do: @accept_none

  @spec accept_app() :: non_neg_integer()
  def accept_app, do: @accept_app

  @spec accept_all() :: non_neg_integer()
  def accept_all, do: @accept_all

  @spec mode_aes128_cbc() :: non_neg_integer()
  def mode_aes128_cbc, do: @mode_aes128_cbc

  @spec mode_aes256_cbc() :: non_neg_integer()
  def mode_aes256_cbc, do: @mode_aes256_cbc

  @spec mode_default() :: non_neg_integer()
  def mode_default, do: @mode_default

  @spec keepalive_max() :: non_neg_integer()
  def keepalive_max, do: @keepalive_max

  @spec keepalive_min() :: non_neg_integer()
  def keepalive_min, do: @keepalive_min

  @spec stale_factor() :: non_neg_integer()
  def stale_factor, do: @stale_factor

  @spec keepalive_max_rtt() :: float()
  def keepalive_max_rtt, do: @keepalive_max_rtt

  @spec traffic_timeout_factor() :: non_neg_integer()
  def traffic_timeout_factor, do: @traffic_timeout_factor

  @spec keepalive_timeout_factor() :: non_neg_integer()
  def keepalive_timeout_factor, do: @keepalive_timeout_factor

  @spec stale_grace() :: non_neg_integer()
  def stale_grace, do: @stale_grace

  @spec establishment_timeout_per_hop() :: non_neg_integer()
  def establishment_timeout_per_hop, do: @establishment_timeout_per_hop

  @spec mtu_bytemask() :: non_neg_integer()
  def mtu_bytemask, do: @mtu_bytemask

  @spec mode_bytemask() :: non_neg_integer()
  def mode_bytemask, do: @mode_bytemask

  @spec mdu() :: non_neg_integer()
  def mdu, do: @link_mdu

  @spec mode_description(non_neg_integer()) :: String.t()
  def mode_description(mode), do: Map.get(@mode_descriptions, mode, "UNKNOWN")

  # ── Constructor ─────────────────────────────────────────────────

  @doc "Creates a new Link struct with default values."
  @spec new() :: t()
  def new do
    %__MODULE__{callbacks: %__MODULE__.Callbacks{}}
  end

  # ── Signalling bytes ────────────────────────────────────────────

  @doc """
  Encodes MTU and encryption mode into 3 signalling bytes.

  The MTU occupies the lower 21 bits and the mode occupies
  the upper 3 bits of the first byte.
  """
  @spec signalling_bytes(non_neg_integer(), non_neg_integer()) :: binary()
  def signalling_bytes(mtu, mode) do
    signalling_value = (mtu &&& @mtu_bytemask) + (((mode <<< 5) &&& @mode_bytemask) <<< 16)
    <<_discard, b0, b1, b2>> = <<signalling_value::unsigned-big-32>>
    <<b0, b1, b2>>
  end

  # ── MTU/mode extraction from packets ────────────────────────────

  @doc "Extracts MTU from a link request packet's data."
  @spec mtu_from_lr_packet(map()) :: non_neg_integer() | nil
  def mtu_from_lr_packet(%{data: data}) when byte_size(data) == @ecpubsize + @link_mtu_size do
    <<_::binary-size(@ecpubsize), b0, b1, b2>> = data
    ((b0 <<< 16) + (b1 <<< 8) + b2) &&& @mtu_bytemask
  end

  def mtu_from_lr_packet(_), do: nil

  @doc "Extracts MTU from a link proof packet's data."
  @spec mtu_from_lp_packet(map()) :: non_neg_integer() | nil
  def mtu_from_lp_packet(%{data: data}) do
    sig_len = div(Identity.siglength(), 8)
    ec_half = div(@ecpubsize, 2)
    expected = sig_len + ec_half + @link_mtu_size

    if byte_size(data) == expected do
      offset = sig_len + ec_half
      <<_::binary-size(offset), b0, b1, b2>> = data
      ((b0 <<< 16) + (b1 <<< 8) + b2) &&& @mtu_bytemask
    else
      nil
    end
  end

  @doc "Extracts encryption mode from a link request packet."
  @spec mode_from_lr_packet(map()) :: non_neg_integer()
  def mode_from_lr_packet(%{data: data}) when byte_size(data) > @ecpubsize do
    <<_::binary-size(@ecpubsize), mode_byte, _::binary>> = data
    (mode_byte &&& @mode_bytemask) >>> 5
  end

  def mode_from_lr_packet(_), do: @mode_default

  @doc "Extracts encryption mode from a link proof packet."
  @spec mode_from_lp_packet(map()) :: non_neg_integer()
  def mode_from_lp_packet(%{data: data}) do
    sig_len = div(Identity.siglength(), 8)
    ec_half = div(@ecpubsize, 2)
    offset = sig_len + ec_half

    if byte_size(data) > offset do
      <<_::binary-size(offset), mode_byte, _::binary>> = data
      mode_byte >>> 5
    else
      @mode_default
    end
  end

  # ── Link ID ─────────────────────────────────────────────────────

  @doc "Computes link ID from a link request packet."
  @spec link_id_from_lr_packet(map()) :: binary()
  def link_id_from_lr_packet(%{data: data, get_hashable_part: hashable_part}) do
    hashable =
      if byte_size(data) > @ecpubsize do
        diff = byte_size(data) - @ecpubsize
        binary_part(hashable_part, 0, byte_size(hashable_part) - diff)
      else
        hashable_part
      end

    Identity.truncated_hash(hashable)
  end

  @doc "Sets the link_id and hash from a link request packet."
  @spec set_link_id(t(), map()) :: t()
  def set_link_id(%__MODULE__{} = link, packet) do
    link_id = link_id_from_lr_packet(packet)
    %{link | link_id: link_id, hash: link_id}
  end

  # ── Load peer ───────────────────────────────────────────────────

  @doc "Loads peer public keys into the link."
  @spec load_peer(t(), binary(), binary()) :: t()
  def load_peer(%__MODULE__{} = link, peer_pub_bytes, peer_sig_pub_bytes) do
    %{link | peer_pub_bytes: peer_pub_bytes, peer_sig_pub_bytes: peer_sig_pub_bytes}
  end

  # ── Handshake ───────────────────────────────────────────────────

  @doc """
  Performs the ECDH key exchange and derives encryption keys.

  Transitions link from PENDING to HANDSHAKE state.
  Uses X25519 for the key exchange and HKDF for key derivation.
  The link_id is used as the HKDF salt.
  """
  @spec handshake(t()) :: {:ok, t()} | {:error, :invalid_state}
  def handshake(%__MODULE__{status: @status_pending, prv: prv} = link) when prv != nil do
    shared_key = X25519.exchange(prv, link.peer_pub_bytes)

    derived_key_length =
      case link.mode do
        @mode_aes128_cbc -> 32
        @mode_aes256_cbc -> 64
        _ -> raise "Invalid link mode #{link.mode}"
      end

    derived_key =
      HKDF.derive_key(
        shared_key,
        derived_key_length,
        get_salt(link),
        get_context(link)
      )

    {:ok,
     %{link | status: @status_handshake, shared_key: shared_key, derived_key: derived_key}}
  end

  def handshake(%__MODULE__{}), do: {:error, :invalid_state}

  # ── Get salt / Get context ──────────────────────────────────────

  @doc "Returns the HKDF salt for key derivation (the link_id)."
  @spec get_salt(t()) :: binary() | nil
  def get_salt(%__MODULE__{link_id: link_id}), do: link_id

  @doc "Returns the HKDF context for key derivation (nil)."
  @spec get_context(t()) :: nil
  def get_context(%__MODULE__{}), do: nil

  # ── Encrypt / Decrypt ───────────────────────────────────────────

  @doc "Encrypts plaintext using the link's derived key."
  @spec encrypt(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(%__MODULE__{} = link, plaintext) do
    token = get_or_create_token(link)
    {:ok, Token.encrypt(token, plaintext)}
  rescue
    e -> {:error, e}
  end

  @doc "Decrypts ciphertext using the link's derived key."
  @spec decrypt(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(%__MODULE__{} = link, ciphertext) do
    token = get_or_create_token(link)
    plaintext = Token.decrypt(token, ciphertext)
    {:ok, plaintext}
  rescue
    e -> {:error, e}
  end

  defp get_or_create_token(%__MODULE__{token: %Token{} = token}), do: token
  defp get_or_create_token(%__MODULE__{derived_key: key}), do: Token.new(key)

  # ── Sign / Validate ─────────────────────────────────────────────

  @doc "Signs a message using the link's Ed25519 signing key."
  @spec sign(t(), binary()) :: binary()
  def sign(%__MODULE__{sig_prv: sig_prv}, message) do
    Ed25519.sign(sig_prv, message)
  end

  @doc "Validates a signature against the peer's signing public key."
  @spec validate(t(), binary(), binary()) :: boolean()
  def validate(%__MODULE__{peer_sig_pub_bytes: peer_sig_pub_bytes}, signature, message) do
    Ed25519.verify(signature, message, peer_sig_pub_bytes)
  rescue
    _ -> false
  end

  # ── Update MDU ──────────────────────────────────────────────────

  @doc "Recalculates the MDU based on the link's current MTU."
  @spec update_mdu(t()) :: t()
  def update_mdu(%__MODULE__{mtu: mtu} = link) do
    mdu =
      div(
        mtu - @ifac_min_size - @header_minsize - @token_overhead,
        @aes128_blocksize
      ) * @aes128_blocksize - 1

    %{link | mdu: mdu}
  end

  # ── Had outbound ────────────────────────────────────────────────

  @doc "Records an outbound event with timestamp."
  @spec had_outbound(t(), keyword()) :: t()
  def had_outbound(%__MODULE__{} = link, opts \\ []) do
    now = System.system_time(:second)
    is_keepalive = Keyword.get(opts, :is_keepalive, false)

    if is_keepalive do
      %{link | last_outbound: now, last_keepalive: now}
    else
      %{link | last_outbound: now, last_data: now}
    end
  end

  # ── Validate request (responder side) ───────────────────────────

  @doc """
  Validates an incoming link request and creates a new link.

  Called on the responder side when a LINKREQUEST packet arrives.
  Extracts the initiator's public keys, performs handshake, and
  generates a proof for the initiator.
  """
  @spec validate_request(map(), binary(), map()) :: {:ok, t()} | {:error, term()}
  def validate_request(owner, data, packet) do
    cond do
      byte_size(data) == @ecpubsize ->
        do_validate_request(owner, data, packet, nil)

      byte_size(data) == @ecpubsize + @link_mtu_size ->
        do_validate_request(owner, data, packet, :with_signalling)

      true ->
        {:error, :invalid_payload_size}
    end
  end

  defp do_validate_request(owner, data, packet, signalling_type) do
    peer_pub_bytes = binary_part(data, 0, div(@ecpubsize, 2))
    peer_sig_pub_bytes = binary_part(data, div(@ecpubsize, 2), div(@ecpubsize, 2))

    prv = X25519.generate_keypair()
    sig_prv = owner.identity.sig_prv_bytes && Ed25519.from_private_bytes(owner.identity.sig_prv_bytes)

    link =
      %__MODULE__{
        new()
        | initiator: false,
          prv: prv,
          pub_bytes: X25519.public_key(prv),
          sig_prv: sig_prv,
          sig_pub_bytes: owner.identity.sig_pub_bytes,
          peer_pub_bytes: peer_pub_bytes,
          peer_sig_pub_bytes: peer_sig_pub_bytes,
          owner: owner,
          destination: Map.get(packet, :destination)
      }
      |> set_link_id(packet)

    link =
      if signalling_type == :with_signalling do
        mtu = mtu_from_lr_packet(packet) || @mtu
        mode = mode_from_lr_packet(packet)
        %{link | mtu: mtu, mode: mode}
      else
        mode = mode_from_lr_packet(packet)
        %{link | mode: mode}
      end

    link = update_mdu(link)

    establishment_timeout =
      @establishment_timeout_per_hop * max(1, Map.get(packet, :hops, 1)) + @keepalive

    link = %{link |
      establishment_cost: link.establishment_cost + byte_size(Map.get(packet, :raw, <<>>)),
      attached_interface: Map.get(packet, :receiving_interface),
      last_inbound: System.system_time(:second),
      request_time: System.system_time(:second)
    }

    _ = establishment_timeout

    case handshake(link) do
      {:ok, handshaken} -> {:ok, handshaken}
      error -> error
    end
  rescue
    e -> {:error, e}
  end

  # ── Validate proof (initiator side) ─────────────────────────────

  @doc """
  Validates a link proof received from the responder.

  Extracts the responder's ephemeral public key from the proof,
  performs ECDH handshake, verifies the signature, and activates
  the link on success.
  """
  @spec validate_proof(t(), map()) :: {:ok, t()} | {:error, term()}
  def validate_proof(%__MODULE__{status: @status_pending, initiator: true} = link, packet) do
    sig_len = div(Identity.siglength(), 8)
    ec_half = div(@ecpubsize, 2)

    mode = mode_from_lp_packet(packet)

    if mode != link.mode do
      {:error, :mode_mismatch}
    else
      {confirmed_mtu, signalling, proof_data} =
        if byte_size(packet.data) == sig_len + ec_half + @link_mtu_size do
          mtu = mtu_from_lp_packet(packet)
          sig_bytes = signalling_bytes(mtu, mode)
          trimmed = binary_part(packet.data, 0, sig_len + ec_half)
          {mtu, sig_bytes, trimmed}
        else
          {nil, <<>>, packet.data}
        end

      if byte_size(proof_data) == sig_len + ec_half do
        peer_pub_bytes = binary_part(proof_data, sig_len, ec_half)

        # Get peer signing public key from destination identity
        dest_pub_key = Identity.get_public_key(link.destination.identity)
        peer_sig_pub_bytes = binary_part(dest_pub_key, ec_half, ec_half)

        updated = load_peer(link, peer_pub_bytes, peer_sig_pub_bytes)

        case handshake(updated) do
          {:ok, handshaken} ->
            signed_data =
              link.link_id <> handshaken.peer_pub_bytes <> handshaken.peer_sig_pub_bytes <>
                signalling

            signature = binary_part(proof_data, 0, sig_len)

            if Identity.validate(link.destination.identity, signature, signed_data) do
              if handshaken.status != @status_handshake do
                {:error, :invalid_link_state}
              else
                now = System.system_time(:second)
                rtt = now - link.request_time
                mtu = confirmed_mtu || @mtu

                activated =
                  handshaken
                  |> Map.put(:rtt, rtt)
                  |> Map.put(:attached_interface, Map.get(packet, :receiving_interface))
                  |> Map.put(:remote_identity, link.destination.identity)
                  |> Map.put(:mtu, mtu)
                  |> update_mdu()
                  |> Map.put(:status, @status_active)
                  |> Map.put(:activated_at, now)
                  |> Map.put(:last_proof, now)
                  |> Map.put(:establishment_cost,
                    handshaken.establishment_cost + byte_size(Map.get(packet, :raw, <<>>))
                  )

                activated =
                  if rtt > 0 and activated.establishment_cost > 0 do
                    %{activated | establishment_rate: activated.establishment_cost / rtt}
                  else
                    activated
                  end

                activated = update_keepalive(activated)

                {:ok, activated}
              end
            else
              {:error, :invalid_signature}
            end

          error ->
            error
        end
      else
        {:error, :invalid_proof_size}
      end
    end
  rescue
    e ->
      {:error, e}
  end

  def validate_proof(%__MODULE__{status: status}, _packet)
      when status != @status_pending do
    {:error, :not_pending}
  end

  def validate_proof(%__MODULE__{}, _packet), do: {:error, :not_initiator}

  # ── RTT packet handling ─────────────────────────────────────────

  @doc """
  Processes an RTT packet on the responder side.

  Decrypts the RTT data, activates the link, and updates keepalive timing.
  """
  @spec rtt_packet(t(), map()) :: {:ok, t()} | {:error, term()}
  def rtt_packet(%__MODULE__{} = link, packet) do
    case decrypt(link, packet.data) do
      {:ok, plaintext} ->
        rtt = Msgpax.unpack!(plaintext)
        measured_rtt = System.system_time(:second) - link.request_time
        final_rtt = max(measured_rtt, rtt)

        now = System.system_time(:second)

        activated =
          %{link |
            rtt: final_rtt,
            status: @status_active,
            activated_at: now
          }

        activated =
          if final_rtt > 0 and activated.establishment_cost > 0 do
            %{activated | establishment_rate: activated.establishment_cost / final_rtt}
          else
            activated
          end

        {:ok, update_keepalive(activated)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # ── Update keepalive ────────────────────────────────────────────

  defp update_keepalive(%__MODULE__{rtt: rtt} = link) when is_number(rtt) do
    ka = max(min(rtt * (@keepalive_max / @keepalive_max_rtt), @keepalive_max), @keepalive_min)
    %{link | keepalive: ka, stale_time: ka * @stale_factor}
  end

  defp update_keepalive(link), do: link

  # ── Identify ────────────────────────────────────────────────────

  @doc """
  Builds identify proof data for the initiator to reveal their identity.

  Returns the proof data (public_key + signature) that would be sent
  over the encrypted link.
  """
  @spec build_identify_data(t(), Identity.t()) :: {:ok, binary()} | {:error, term()}
  def build_identify_data(
        %__MODULE__{initiator: true, status: @status_active, link_id: link_id},
        %Identity{} = identity
      ) do
    pub_key = Identity.get_public_key(identity)
    signed_data = link_id <> pub_key
    signature = Identity.sign(identity, signed_data)
    {:ok, pub_key <> signature}
  end

  def build_identify_data(%__MODULE__{}, _identity),
    do: {:error, :not_initiator_or_not_active}

  # ── Request ─────────────────────────────────────────────────────

  @doc """
  Builds request data for sending over the link.

  Returns the packed request data and the timeout value.
  """
  @spec build_request_data(t(), String.t(), term(), keyword()) ::
          {:ok, binary(), number()} | {:error, term()}
  def build_request_data(%__MODULE__{} = link, path, data, opts \\ []) do
    request_path_hash = Identity.truncated_hash(path)
    timestamp = System.system_time(:second)
    unpacked_request = [timestamp, request_path_hash, data]
    packed_request = Msgpax.pack!(unpacked_request) |> IO.iodata_to_binary()

    timeout =
      Keyword.get_lazy(opts, :timeout, fn ->
        link.rtt * link.traffic_timeout_factor + @response_max_grace_time * 1.125
      end)

    {:ok, packed_request, timeout}
  end

  # ── Phy stats ───────────────────────────────────────────────────

  @doc "Enables or disables physical layer stat tracking."
  @spec track_phy_stats(t(), boolean()) :: t()
  def track_phy_stats(%__MODULE__{} = link, track) do
    %{link | track_phy_stats: track}
  end

  @doc "Returns the RSSI if tracking is enabled."
  @spec get_rssi(t()) :: number() | nil
  def get_rssi(%__MODULE__{track_phy_stats: true, rssi: rssi}), do: rssi
  def get_rssi(%__MODULE__{}), do: nil

  @doc "Returns the SNR if tracking is enabled."
  @spec get_snr(t()) :: number() | nil
  def get_snr(%__MODULE__{track_phy_stats: true, snr: snr}), do: snr
  def get_snr(%__MODULE__{}), do: nil

  @doc "Returns the link quality if tracking is enabled."
  @spec get_q(t()) :: number() | nil
  def get_q(%__MODULE__{track_phy_stats: true, q: q}), do: q
  def get_q(%__MODULE__{}), do: nil

  # ── Establishment rate ──────────────────────────────────────────

  @doc "Returns the establishment rate in bits per second."
  @spec get_establishment_rate(t()) :: float() | nil
  def get_establishment_rate(%__MODULE__{establishment_rate: rate}) when is_number(rate) do
    rate * 8
  end

  def get_establishment_rate(%__MODULE__{}), do: nil

  # ── Remote identity ─────────────────────────────────────────────

  @doc "Returns the remote peer's identity if known."
  @spec get_remote_identity(t()) :: Identity.t() | nil
  def get_remote_identity(%__MODULE__{remote_identity: id}), do: id

  # ── Channel ─────────────────────────────────────────────────────

  @doc "Gets or creates the Channel for this link."
  @spec get_channel(t()) :: {RNS.Channel.t(), t()}
  def get_channel(%__MODULE__{channel: %RNS.Channel{} = channel} = link) do
    {channel, link}
  end

  def get_channel(%__MODULE__{} = link) do
    outlet = RNS.Channel.LinkChannelOutlet.new(link)
    channel = RNS.Channel.new(outlet)
    {channel, %{link | channel: channel}}
  end

  # ── Callback setters ────────────────────────────────────────────

  @doc "Sets the link established callback."
  @spec set_link_established_callback(t(), function()) :: t()
  def set_link_established_callback(%__MODULE__{callbacks: cb} = link, callback) do
    %{link | callbacks: %{cb | link_established: callback}}
  end

  @doc "Sets the link closed callback."
  @spec set_link_closed_callback(t(), function()) :: t()
  def set_link_closed_callback(%__MODULE__{callbacks: cb} = link, callback) do
    %{link | callbacks: %{cb | link_closed: callback}}
  end

  @doc "Sets the packet callback."
  @spec set_packet_callback(t(), function()) :: t()
  def set_packet_callback(%__MODULE__{callbacks: cb} = link, callback) do
    %{link | callbacks: %{cb | packet: callback}}
  end

  @doc "Sets the resource callback."
  @spec set_resource_callback(t(), function()) :: t()
  def set_resource_callback(%__MODULE__{callbacks: cb} = link, callback) do
    %{link | callbacks: %{cb | resource: callback}}
  end

  @doc "Sets the resource started callback."
  @spec set_resource_started_callback(t(), function()) :: t()
  def set_resource_started_callback(%__MODULE__{callbacks: cb} = link, callback) do
    %{link | callbacks: %{cb | resource_started: callback}}
  end

  @doc "Sets the resource concluded callback."
  @spec set_resource_concluded_callback(t(), function()) :: t()
  def set_resource_concluded_callback(%__MODULE__{callbacks: cb} = link, callback) do
    %{link | callbacks: %{cb | resource_concluded: callback}}
  end

  @doc "Sets the remote identified callback."
  @spec set_remote_identified_callback(t(), function()) :: t()
  def set_remote_identified_callback(%__MODULE__{callbacks: cb} = link, callback) do
    %{link | callbacks: %{cb | remote_identified: callback}}
  end
end

# ── String.Chars implementation ───────────────────────────────────

defimpl String.Chars, for: RNS.Link do
  def to_string(%RNS.Link{link_id: nil}), do: "<Link:uninitialized>"

  def to_string(%RNS.Link{link_id: link_id}) do
    RNS.prettyhexrep(link_id)
  end
end
