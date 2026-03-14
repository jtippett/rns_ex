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

defmodule RNS.Link.CryptoState do
  @moduledoc "Holds cryptographic keys and encryption state for a Link."

  use RNS.Constants.Link

  defstruct [
    :prv,
    :pub_bytes,
    :sig_prv,
    :sig_pub_bytes,
    :shared_key,
    :derived_key,
    :token,
    mode: @mode_default
  ]

  @type t :: %__MODULE__{
          prv: binary() | nil,
          pub_bytes: binary() | nil,
          sig_prv: binary() | nil,
          sig_pub_bytes: binary() | nil,
          shared_key: binary() | nil,
          derived_key: binary() | nil,
          token: any() | nil,
          mode: non_neg_integer()
        }
end

defmodule RNS.Link.PeerState do
  @moduledoc "Holds peer public keys and identity for a Link."

  defstruct [
    :peer_pub_bytes,
    :peer_sig_pub_bytes,
    :remote_identity
  ]

  @type t :: %__MODULE__{
          peer_pub_bytes: binary() | nil,
          peer_sig_pub_bytes: binary() | nil,
          remote_identity: any() | nil
        }
end

defmodule RNS.Link.Stats do
  @moduledoc "Holds statistics and timing information for a Link."

  defstruct [
    :rtt,
    :rssi,
    :snr,
    :q,
    :establishment_rate,
    :expected_hops,
    tx: 0,
    rx: 0,
    txbytes: 0,
    rxbytes: 0,
    last_inbound: 0,
    last_outbound: 0,
    last_keepalive: 0,
    last_proof: 0,
    last_data: 0
  ]

  @type t :: %__MODULE__{
          rtt: number() | nil,
          rssi: number() | nil,
          snr: number() | nil,
          q: number() | nil,
          establishment_rate: number() | nil,
          expected_hops: non_neg_integer() | nil,
          tx: non_neg_integer(),
          rx: non_neg_integer(),
          txbytes: non_neg_integer(),
          rxbytes: non_neg_integer(),
          last_inbound: non_neg_integer(),
          last_outbound: non_neg_integer(),
          last_keepalive: non_neg_integer(),
          last_proof: non_neg_integer(),
          last_data: non_neg_integer()
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

  Includes establishment, encryption (Task 5.2), and lifecycle management:
  keepalive, teardown, stale detection, packet receive dispatch,
  resource management, and watchdog checks (Task 5.3).
  """

  require Logger

  import Bitwise

  alias RNS.Cryptography.Ed25519
  alias RNS.Cryptography.HKDF
  alias RNS.Cryptography.Token
  alias RNS.Cryptography.X25519
  alias RNS.Identity
  alias RNS.Link.{CryptoState, PeerState, Stats}

  use RNS.Constants.Link
  use RNS.Constants.Destination

  @establishment_timeout_per_hop 6

  # ── Struct ──────────────────────────────────────────────────────

  defstruct [
    :link_id,
    :hash,
    :destination,
    :owner,
    :attached_interface,
    :channel,
    :activated_at,
    :request_time,
    :teardown_reason,
    status: @status_pending,
    initiator: false,
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
    traffic_timeout_factor: @traffic_timeout_factor,
    keepalive_timeout_factor: @keepalive_timeout_factor,
    keepalive: @keepalive,
    stale_time: @stale_time,
    track_phy_stats: false,
    type: 0x03,
    callbacks: nil,
    crypto: %CryptoState{},
    peer: %PeerState{},
    stats: %Stats{}
  ]

  @type t :: %__MODULE__{}

  # ── Constant accessors ─────────────────────────────────────────
  # For cross-module use, prefer `use RNS.Constants.Link`.

  def ecpubsize, do: @ecpubsize
  def keysize, do: @keysize
  def link_mtu_size, do: @link_mtu_size
  def pending, do: @status_pending
  def handshake, do: @status_handshake
  def active, do: @status_active
  def stale, do: @status_stale
  def closed, do: @status_closed
  def timeout, do: @timeout
  def initiator_closed, do: @initiator_closed
  def destination_closed, do: @destination_closed
  def accept_none, do: @accept_none
  def accept_app, do: @accept_app
  def accept_all, do: @accept_all
  def mode_aes128_cbc, do: @mode_aes128_cbc
  def mode_aes256_cbc, do: @mode_aes256_cbc
  def mode_default, do: @mode_default
  def keepalive_max, do: @keepalive_max
  def keepalive_min, do: @keepalive_min
  def stale_factor, do: @stale_factor
  def keepalive_max_rtt, do: @keepalive_max_rtt
  def traffic_timeout_factor, do: @traffic_timeout_factor
  def keepalive_timeout_factor, do: @keepalive_timeout_factor
  def stale_grace, do: @stale_grace
  def establishment_timeout_per_hop, do: @establishment_timeout_per_hop
  def mtu_bytemask, do: @mtu_bytemask
  def mode_bytemask, do: @mode_bytemask
  def mdu, do: @link_mdu
  def mode_description(mode), do: Map.get(@mode_descriptions, mode, "UNKNOWN")

  # ── Constructor ─────────────────────────────────────────────────

  @doc "Creates a new Link struct with default values."
  @spec new() :: t()
  def new do
    %__MODULE__{
      callbacks: %__MODULE__.Callbacks{},
      crypto: %CryptoState{},
      peer: %PeerState{},
      stats: %Stats{}
    }
  end

  # ── Signalling bytes ────────────────────────────────────────────

  @doc """
  Encodes MTU and encryption mode into 3 signalling bytes.

  The MTU occupies the lower 21 bits and the mode occupies
  the upper 3 bits of the first byte.
  """
  @spec signalling_bytes(non_neg_integer(), non_neg_integer()) :: binary()
  def signalling_bytes(mtu, mode) do
    signalling_value = (mtu &&& @mtu_bytemask) + ((mode <<< 5 &&& @mode_bytemask) <<< 16)
    <<_discard, b0, b1, b2>> = <<signalling_value::unsigned-big-32>>
    <<b0, b1, b2>>
  end

  # ── MTU/mode extraction from packets ────────────────────────────

  @doc "Extracts MTU from a link request packet's data."
  @spec mtu_from_lr_packet(map()) :: non_neg_integer() | nil
  def mtu_from_lr_packet(%{data: data}) when byte_size(data) == @ecpubsize + @link_mtu_size do
    <<_::binary-size(@ecpubsize), b0, b1, b2>> = data
    (b0 <<< 16) + (b1 <<< 8) + b2 &&& @mtu_bytemask
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
      (b0 <<< 16) + (b1 <<< 8) + b2 &&& @mtu_bytemask
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
  def link_id_from_lr_packet(%{data: data, hashable_part: hashable_part}) do
    hashable =
      if byte_size(data) > @ecpubsize do
        trim_len = byte_size(hashable_part) - (byte_size(data) - @ecpubsize)
        <<trimmed::binary-size(trim_len), _::binary>> = hashable_part
        trimmed
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
  def load_peer(%__MODULE__{peer: peer} = link, peer_pub_bytes, peer_sig_pub_bytes) do
    %{
      link
      | peer: %{peer | peer_pub_bytes: peer_pub_bytes, peer_sig_pub_bytes: peer_sig_pub_bytes}
    }
  end

  # ── Handshake ───────────────────────────────────────────────────

  @doc """
  Performs the ECDH key exchange and derives encryption keys.

  Transitions link from PENDING to HANDSHAKE state.
  Uses X25519 for the key exchange and HKDF for key derivation.
  The link_id is used as the HKDF salt.
  """
  @spec handshake(t()) :: {:ok, t()} | {:error, :invalid_state}
  def handshake(
        %__MODULE__{status: @status_pending, crypto: %CryptoState{prv: prv} = crypto} = link
      )
      when prv != nil do
    shared_key = X25519.exchange(prv, link.peer.peer_pub_bytes)

    derived_key_length =
      case crypto.mode do
        @mode_aes128_cbc -> 32
        @mode_aes256_cbc -> 64
        _ -> raise "Invalid link mode #{crypto.mode}"
      end

    derived_key =
      HKDF.derive_key(
        shared_key,
        derived_key_length,
        salt(link),
        context(link)
      )

    {:ok,
     %{
       link
       | status: @status_handshake,
         crypto: %{crypto | shared_key: shared_key, derived_key: derived_key}
     }}
  end

  def handshake(%__MODULE__{}), do: {:error, :invalid_state}

  # ── Salt / Context ─────────────────────────────────────────────

  @doc "Returns the HKDF salt for key derivation (the link_id)."
  @spec salt(t()) :: binary() | nil
  def salt(%__MODULE__{link_id: link_id}), do: link_id

  @doc "Returns the HKDF context for key derivation (nil)."
  @spec context(t()) :: nil
  def context(%__MODULE__{}), do: nil

  # ── Encrypt / Decrypt ───────────────────────────────────────────

  @doc "Encrypts plaintext using the link's derived key."
  @spec encrypt(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(%__MODULE__{} = link, plaintext) do
    token = get_or_create_token(link)
    {:ok, Token.encrypt(token, plaintext)}
  rescue
    e ->
      Logger.debug("Link encryption failed: #{inspect(e)}")
      {:error, e}
  end

  @doc "Decrypts ciphertext using the link's derived key."
  @spec decrypt(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(%__MODULE__{} = link, ciphertext) do
    token = get_or_create_token(link)
    plaintext = Token.decrypt(token, ciphertext)
    {:ok, plaintext}
  rescue
    e ->
      Logger.debug("Link decryption failed: #{inspect(e)}")
      {:error, e}
  end

  defp get_or_create_token(%__MODULE__{crypto: %CryptoState{token: %Token{} = token}}), do: token

  defp get_or_create_token(%__MODULE__{crypto: %CryptoState{derived_key: key}}),
    do: Token.new(key)

  # ── Sign / Validate ─────────────────────────────────────────────

  @doc "Signs a message using the link's Ed25519 signing key."
  @spec sign(t(), binary()) :: binary()
  def sign(%__MODULE__{crypto: %CryptoState{sig_prv: sig_prv}}, message) do
    Ed25519.sign(sig_prv, message)
  end

  @doc "Validates a signature against the peer's signing public key."
  @spec validate(t(), binary(), binary()) :: boolean()
  def validate(
        %__MODULE__{peer: %PeerState{peer_sig_pub_bytes: peer_sig_pub_bytes}},
        signature,
        message
      ) do
    Ed25519.verify(signature, message, peer_sig_pub_bytes)
  rescue
    e ->
      Logger.debug("Link signature validation failed: #{inspect(e)}")
      false
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
  def had_outbound(%__MODULE__{stats: stats} = link, opts \\ []) do
    now = System.system_time(:second)
    is_keepalive = Keyword.get(opts, :is_keepalive, false)

    if is_keepalive do
      %{link | stats: %{stats | last_outbound: now, last_keepalive: now}}
    else
      %{link | stats: %{stats | last_outbound: now, last_data: now}}
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
    ec_half = div(@ecpubsize, 2)

    <<peer_pub_bytes::binary-size(ec_half), peer_sig_pub_bytes::binary-size(ec_half), _::binary>> =
      data

    prv = X25519.generate_keypair()

    sig_prv =
      owner.identity.sig_prv_bytes && Ed25519.from_private_bytes(owner.identity.sig_prv_bytes)

    link =
      %__MODULE__{
        new()
        | initiator: false,
          crypto: %CryptoState{
            prv: prv,
            pub_bytes: X25519.public_key(prv),
            sig_prv: sig_prv,
            sig_pub_bytes: owner.identity.sig_pub_bytes
          },
          peer: %PeerState{
            peer_pub_bytes: peer_pub_bytes,
            peer_sig_pub_bytes: peer_sig_pub_bytes
          },
          owner: owner,
          destination: Map.get(packet, :destination)
      }
      |> set_link_id(packet)

    link =
      if signalling_type == :with_signalling do
        mtu = mtu_from_lr_packet(packet) || @mtu
        mode = mode_from_lr_packet(packet)
        %{link | mtu: mtu, crypto: %{link.crypto | mode: mode}}
      else
        mode = mode_from_lr_packet(packet)
        %{link | crypto: %{link.crypto | mode: mode}}
      end

    link = update_mdu(link)

    establishment_timeout =
      @establishment_timeout_per_hop * max(1, Map.get(packet, :hops, 1)) + @keepalive

    link = %{
      link
      | establishment_cost: link.establishment_cost + byte_size(Map.get(packet, :raw, <<>>)),
        attached_interface: Map.get(packet, :receiving_interface),
        stats: %{link.stats | last_inbound: System.system_time(:second)},
        request_time: System.system_time(:second)
    }

    _ = establishment_timeout

    case handshake(link) do
      {:ok, handshaken} -> {:ok, handshaken}
      error -> error
    end
  rescue
    e ->
      Logger.debug("Link request validation failed: #{inspect(e)}")
      {:error, e}
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

    if mode != link.crypto.mode do
      {:error, :mode_mismatch}
    else
      {confirmed_mtu, signalling, proof_data} =
        if byte_size(packet.data) == sig_len + ec_half + @link_mtu_size do
          mtu = mtu_from_lp_packet(packet)
          sig_bytes = signalling_bytes(mtu, mode)
          <<trimmed::binary-size(sig_len + ec_half), _::binary>> = packet.data
          {mtu, sig_bytes, trimmed}
        else
          {nil, <<>>, packet.data}
        end

      if byte_size(proof_data) == sig_len + ec_half do
        <<_sig::binary-size(sig_len), peer_pub_bytes::binary-size(ec_half)>> = proof_data

        # Get peer signing public key from destination identity
        dest_pub_key = Identity.public_key(link.destination.identity)

        <<_enc_pub::binary-size(ec_half), peer_sig_pub_bytes::binary-size(ec_half)>> =
          dest_pub_key

        updated = load_peer(link, peer_pub_bytes, peer_sig_pub_bytes)

        case handshake(updated) do
          {:ok, handshaken} ->
            signed_data =
              link.link_id <>
                handshaken.peer.peer_pub_bytes <>
                handshaken.peer.peer_sig_pub_bytes <>
                signalling

            activate_after_proof(link, handshaken, packet, proof_data, signed_data, confirmed_mtu)

          error ->
            error
        end
      else
        {:error, :invalid_proof_size}
      end
    end
  rescue
    e ->
      Logger.debug("Link proof validation failed: #{inspect(e)}")
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
          %{
            link
            | stats: %{link.stats | rtt: final_rtt},
              status: @status_active,
              activated_at: now
          }

        activated =
          if final_rtt > 0 and activated.establishment_cost > 0 do
            %{
              activated
              | stats: %{
                  activated.stats
                  | establishment_rate: activated.establishment_cost / final_rtt
                }
            }
          else
            activated
          end

        {:ok, update_keepalive(activated)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.debug("Link handshake failed: #{inspect(e)}")
      {:error, e}
  end

  # ── Update keepalive ────────────────────────────────────────────

  defp update_keepalive(%__MODULE__{stats: %Stats{rtt: rtt}} = link) when is_number(rtt) do
    ka = max(min(rtt * (@keepalive_max / @keepalive_max_rtt), @keepalive_max), @keepalive_min)
    %{link | keepalive: ka, stale_time: ka * @stale_factor}
  end

  defp update_keepalive(link), do: link

  defp maybe_set_establishment_rate(%__MODULE__{} = link, rtt)
       when rtt > 0 and link.establishment_cost > 0 do
    %{link | stats: %{link.stats | establishment_rate: link.establishment_cost / rtt}}
  end

  defp maybe_set_establishment_rate(link, _rtt), do: link

  defp activate_after_proof(link, handshaken, packet, proof_data, signed_data, confirmed_mtu) do
    sig_len = div(Identity.siglength(), 8)
    <<signature::binary-size(sig_len), _::binary>> = proof_data

    if Identity.validate(link.destination.identity, signature, signed_data) do
      now = System.system_time(:second)
      rtt = now - link.request_time
      mtu = confirmed_mtu || @mtu

      activated =
        %{
          handshaken
          | stats: %{handshaken.stats | rtt: rtt, last_proof: now},
            attached_interface: Map.get(packet, :receiving_interface),
            peer: %{handshaken.peer | remote_identity: link.destination.identity},
            mtu: mtu,
            status: @status_active,
            activated_at: now,
            establishment_cost:
              handshaken.establishment_cost + byte_size(Map.get(packet, :raw, <<>>))
        }
        |> update_mdu()
        |> maybe_set_establishment_rate(rtt)
        |> update_keepalive()

      {:ok, activated}
    else
      {:error, :invalid_signature}
    end
  end

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
    pub_key = Identity.public_key(identity)
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
        link.stats.rtt * link.traffic_timeout_factor + @response_max_grace_time * 1.125
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
  @spec rssi(t()) :: number() | nil
  def rssi(%__MODULE__{track_phy_stats: true, stats: %Stats{rssi: rssi}}), do: rssi
  def rssi(%__MODULE__{}), do: nil

  @doc "Returns the SNR if tracking is enabled."
  @spec snr(t()) :: number() | nil
  def snr(%__MODULE__{track_phy_stats: true, stats: %Stats{snr: snr}}), do: snr
  def snr(%__MODULE__{}), do: nil

  @doc "Returns the link quality if tracking is enabled."
  @spec q(t()) :: number() | nil
  def q(%__MODULE__{track_phy_stats: true, stats: %Stats{q: q}}), do: q
  def q(%__MODULE__{}), do: nil

  # ── Establishment rate ──────────────────────────────────────────

  @doc "Returns the establishment rate in bits per second."
  @spec establishment_rate(t()) :: float() | nil
  def establishment_rate(%__MODULE__{stats: %Stats{establishment_rate: rate}})
      when is_number(rate) do
    rate * 8
  end

  def establishment_rate(%__MODULE__{}), do: nil

  # ── Remote identity ─────────────────────────────────────────────

  @doc "Returns the remote peer's identity if known."
  @spec remote_identity(t()) :: Identity.t() | nil
  def remote_identity(%__MODULE__{peer: %PeerState{remote_identity: id}}), do: id

  # ── Channel ─────────────────────────────────────────────────────

  @doc "Gets or creates the Channel for this link."
  @spec channel(t()) :: {RNS.Channel.t(), t()}
  def channel(%__MODULE__{channel: %RNS.Channel{} = channel} = link) do
    {channel, link}
  end

  def channel(%__MODULE__{} = link) do
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

  # ══════════════════════════════════════════════════════════════════
  # Task 5.3 — Lifecycle management
  # ══════════════════════════════════════════════════════════════════

  # ── Timing queries ─────────────────────────────────────────────

  @doc "Returns the time in seconds since this link was established."
  @spec get_age(t()) :: number() | nil
  def get_age(%__MODULE__{activated_at: nil}), do: nil

  def get_age(%__MODULE__{activated_at: activated_at}) do
    System.system_time(:second) - activated_at
  end

  @doc "Returns the time in seconds since last inbound packet (including keepalive)."
  @spec no_inbound_for(t()) :: number()
  def no_inbound_for(%__MODULE__{
        stats: %Stats{last_inbound: last_inbound},
        activated_at: activated_at
      }) do
    activated = activated_at || 0
    effective_last = max(last_inbound, activated)
    System.system_time(:second) - effective_last
  end

  @doc "Returns the time in seconds since last outbound packet (including keepalive)."
  @spec no_outbound_for(t()) :: number()
  def no_outbound_for(%__MODULE__{stats: %Stats{last_outbound: last_outbound}}) do
    System.system_time(:second) - last_outbound
  end

  @doc "Returns the time in seconds since payload data traversed the link (excludes keepalive)."
  @spec no_data_for(t()) :: number()
  def no_data_for(%__MODULE__{stats: %Stats{last_data: last_data}}) do
    System.system_time(:second) - last_data
  end

  @doc "Returns the time in seconds since any activity on the link (including keepalive)."
  @spec inactive_for(t()) :: number()
  def inactive_for(%__MODULE__{} = link) do
    min(no_inbound_for(link), no_outbound_for(link))
  end

  # ── Send keepalive ─────────────────────────────────────────────

  @doc """
  Builds keepalive packet data.

  Returns `{keepalive_data, context, updated_link}` where keepalive_data is
  `<<0xFF>>` and context is `:keepalive`. The caller creates and sends the packet.
  """
  @spec send_keepalive(t()) :: {binary(), atom(), t()}
  def send_keepalive(%__MODULE__{} = link) do
    updated = had_outbound(link, is_keepalive: true)
    {<<0xFF>>, :keepalive, updated}
  end

  # ── Prove (responder side) ─────────────────────────────────────

  @doc """
  Builds proof data for the responder to send to the initiator.

  Returns `{proof_data, updated_link}` where proof_data contains
  signature + pub_bytes + signalling_bytes.
  """
  @spec prove(t()) :: {binary(), t()}
  def prove(%__MODULE__{} = link) do
    sig_bytes = signalling_bytes(link.mtu, link.crypto.mode)

    signed_data =
      link.link_id <> link.crypto.pub_bytes <> link.crypto.sig_pub_bytes <> sig_bytes

    signature = link.owner.identity |> Identity.sign(signed_data)
    proof_data = signature <> link.crypto.pub_bytes <> sig_bytes

    updated = had_outbound(link)
    {proof_data, updated}
  end

  # ── Prove packet (explicit proof for data packets) ─────────────

  @doc """
  Builds an explicit proof for a received data packet.

  Returns `{proof_data, updated_link}` where proof_data contains
  packet_hash + signature.
  """
  @spec prove_packet(t(), binary()) :: {binary(), t()}
  def prove_packet(%__MODULE__{} = link, packet_hash) do
    signature = sign(link, packet_hash)
    proof_data = packet_hash <> signature
    updated = had_outbound(link)
    {proof_data, updated}
  end

  # ── Teardown ───────────────────────────────────────────────────

  @doc """
  Closes the link and purges encryption keys.

  Returns `{teardown_data, updated_link}` where teardown_data is the
  encrypted link_id to send as a LINKCLOSE packet (nil if link was PENDING).
  """
  @spec teardown(t()) :: {binary() | nil, t()}
  def teardown(%__MODULE__{status: status} = link)
      when status != @status_pending and status != @status_closed do
    # Build teardown packet data (encrypted link_id)
    teardown_data =
      case encrypt(link, link.link_id) do
        {:ok, data} -> data
        _ -> nil
      end

    reason =
      if link.initiator, do: @initiator_closed, else: @destination_closed

    updated =
      %{link | status: @status_closed, teardown_reason: reason}
      |> link_closed()

    {teardown_data, updated}
  end

  def teardown(%__MODULE__{} = link) do
    reason =
      if link.initiator, do: @initiator_closed, else: @destination_closed

    updated =
      %{link | status: @status_closed, teardown_reason: reason}
      |> link_closed()

    {nil, updated}
  end

  # ── Teardown packet (received LINKCLOSE from peer) ─────────────

  @doc """
  Processes an incoming LINKCLOSE packet.

  Decrypts the payload and verifies it matches the link_id.
  Returns `{:ok, updated_link}` on success or `{:error, reason}` on failure.
  """
  @spec teardown_packet(t(), map()) :: {:ok, t()} | {:error, term()}
  def teardown_packet(%__MODULE__{} = link, packet) do
    case decrypt(link, packet.data) do
      {:ok, plaintext} ->
        if plaintext == link.link_id do
          reason =
            if link.initiator, do: @destination_closed, else: @initiator_closed

          updated =
            %{link | status: @status_closed, teardown_reason: reason}
            |> update_phy_stats(packet)
            |> link_closed()

          {:ok, updated}
        else
          {:error, :invalid_teardown_data}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.debug("Link teardown packet decryption failed: #{inspect(e)}")
      {:error, :decryption_failed}
  end

  # ── Link closed (internal cleanup) ─────────────────────────────

  @doc """
  Clears encryption keys, cancels resources, shuts down channel,
  and invokes the link_closed callback.
  """
  @spec link_closed(t()) :: t()
  def link_closed(%__MODULE__{} = link) do
    # Shut down channel if present
    updated =
      if link.channel do
        %{link | channel: RNS.Channel.shutdown(link.channel)}
      else
        link
      end

    # Clear encryption keys
    updated = %{
      updated
      | crypto: %{
          updated.crypto
          | prv: nil,
            pub_bytes: nil,
            shared_key: nil,
            derived_key: nil,
            token: nil
        }
    }

    # Invoke link_closed callback
    if updated.callbacks && updated.callbacks.link_closed do
      try do
        updated.callbacks.link_closed.(updated)
      rescue
        e ->
          require Logger
          Logger.error("Error in link closed callback: #{inspect(e)}")
      end
    end

    updated
  end

  # ── Update phy stats ───────────────────────────────────────────

  @doc "Updates physical layer statistics from a received packet."
  @spec update_phy_stats(t(), map(), keyword()) :: t()
  def update_phy_stats(%__MODULE__{stats: stats} = link, packet, opts \\ []) do
    force = Keyword.get(opts, :force_update, false)

    if link.track_phy_stats or force do
      rssi = Map.get(packet, :rssi, stats.rssi)
      snr = Map.get(packet, :snr, stats.snr)
      q = Map.get(packet, :q, stats.q)

      %{link | stats: %{stats | rssi: rssi || stats.rssi, snr: snr || stats.snr, q: q || stats.q}}
    else
      link
    end
  end

  # ── Receive packet ─────────────────────────────────────────────

  @doc """
  Processes an inbound packet on this link.

  Dispatches by packet type and context. Returns `{:ok, updated_link, actions}`
  where actions is a list of side-effect tuples the caller should execute:
  - `{:send_proof, proof_data}` — send a PROOF packet
  - `{:send_keepalive_response, data}` — send a KEEPALIVE response
  - `{:callback, fun, args}` — invoke a callback
  """
  @spec receive_packet(t(), map()) :: {:ok, t(), list()} | {:ignored, t()}
  def receive_packet(%__MODULE__{status: @status_closed} = link, _packet) do
    {:ignored, link}
  end

  def receive_packet(
        %__MODULE__{initiator: true} = link,
        %{context: context, data: data} = _packet
      )
      when context == :keepalive and data == <<0xFF>> do
    # Initiator ignores keepalive request packets
    {:ignored, link}
  end

  def receive_packet(%__MODULE__{} = link, packet) do
    context = Map.get(packet, :context)
    receiving_interface = Map.get(packet, :receiving_interface)

    if receiving_interface != nil and link.attached_interface != nil and
         receiving_interface != link.attached_interface do
      require Logger
      Logger.error("Link packet received on unexpected interface!")
      {:ignored, link}
    else
      now = System.system_time(:second)
      stats = link.stats

      updated_stats = %{
        stats
        | last_inbound: now,
          rx: stats.rx + 1,
          rxbytes: stats.rxbytes + byte_size(Map.get(packet, :data, <<>>))
      }

      # Update last_data for non-keepalive packets
      updated_stats =
        if context != :keepalive do
          %{updated_stats | last_data: now}
        else
          updated_stats
        end

      updated = %{link | stats: updated_stats}

      # Revive stale link on any inbound
      updated =
        if updated.status == @status_stale do
          %{updated | status: @status_active}
        else
          updated
        end

      packet_type = Map.get(packet, :packet_type, :data)
      do_receive_packet(updated, packet, packet_type, context)
    end
  end

  # ── Receive dispatch by packet type and context ────────────────

  defp do_receive_packet(link, packet, :data, :none) do
    case decrypt(link, packet.data) do
      {:ok, plaintext} ->
        link = update_phy_stats(link, packet)

        actions = build_data_actions(link, packet, plaintext)
        {:ok, link, actions}

      {:error, _} ->
        {:ok, link, []}
    end
  end

  defp do_receive_packet(link, packet, :data, :linkidentify) do
    case decrypt(link, packet.data) do
      {:ok, plaintext} ->
        keysize_bytes = div(Identity.keysize(), 8)
        siglength_bytes = div(Identity.siglength(), 8)

        if not link.initiator and byte_size(plaintext) == keysize_bytes + siglength_bytes do
          <<public_key::binary-size(keysize_bytes), signature::binary-size(siglength_bytes)>> =
            plaintext

          signed_data = link.link_id <> public_key

          identity = Identity.new(create_keys: false)
          identity = Identity.load_public_key(identity, public_key)

          if Identity.validate(identity, signature, signed_data) do
            link = %{link | peer: %{link.peer | remote_identity: identity}}
            link = update_phy_stats(link, packet)

            actions =
              if link.callbacks && link.callbacks.remote_identified do
                [{:callback, link.callbacks.remote_identified, [link, identity]}]
              else
                []
              end

            {:ok, link, actions}
          else
            {:ok, link, []}
          end
        else
          {:ok, link, []}
        end

      {:error, _} ->
        {:ok, link, []}
    end
  end

  defp do_receive_packet(link, packet, :data, :request) do
    case decrypt(link, packet.data) do
      {:ok, packed_request} ->
        link = update_phy_stats(link, packet)
        request_id = Identity.truncated_hash(Map.get(packet, :raw, packet.data))

        unpacked_request = Msgpax.unpack!(packed_request)
        actions = [{:handle_request, request_id, unpacked_request}]
        {:ok, link, actions}

      {:error, _} ->
        {:ok, link, []}
    end
  rescue
    e ->
      Logger.debug("Link request packet processing failed: #{inspect(e)}")
      {:ok, link, []}
  end

  defp do_receive_packet(link, packet, :data, :response) do
    case decrypt(link, packet.data) do
      {:ok, packed_response} ->
        link = update_phy_stats(link, packet)
        unpacked = Msgpax.unpack!(packed_response)
        request_id = Enum.at(unpacked, 0)
        response_data = Enum.at(unpacked, 1)
        transfer_size = byte_size(Msgpax.pack!(response_data) |> IO.iodata_to_binary()) - 2
        actions = [{:handle_response, request_id, response_data, transfer_size, transfer_size}]
        {:ok, link, actions}

      {:error, _} ->
        {:ok, link, []}
    end
  rescue
    e ->
      Logger.debug("Link response packet processing failed: #{inspect(e)}")
      {:ok, link, []}
  end

  defp do_receive_packet(link, packet, :data, :lrrtt) do
    if link.initiator do
      {:ok, link, []}
    else
      link = update_phy_stats(link, packet)

      case rtt_packet(link, packet) do
        {:ok, activated} ->
          actions =
            if activated.owner && activated.owner[:callbacks] &&
                 activated.owner[:callbacks][:link_established] do
              [{:callback, activated.owner[:callbacks][:link_established], [activated]}]
            else
              []
            end

          {:ok, activated, actions}

        {:error, _} ->
          {:ok, link, []}
      end
    end
  end

  defp do_receive_packet(link, packet, :data, :linkclose) do
    case teardown_packet(link, packet) do
      {:ok, closed_link} -> {:ok, closed_link, []}
      {:error, _} -> {:ok, link, []}
    end
  end

  defp do_receive_packet(link, packet, :data, :keepalive) do
    if not link.initiator and packet.data == <<0xFF>> do
      # Responder responds to keepalive request
      link = had_outbound(link, is_keepalive: true)
      {:ok, link, [{:send_keepalive_response, <<0xFE>>}]}
    else
      {:ok, link, []}
    end
  end

  defp do_receive_packet(link, packet, :data, :channel) do
    if link.channel do
      case decrypt(link, packet.data) do
        {:ok, plaintext} ->
          link = update_phy_stats(link, packet)
          packet_hash = Map.get(packet, :packet_hash, <<>>)

          actions = [
            {:send_proof, packet_hash},
            {:channel_receive, plaintext}
          ]

          {:ok, link, actions}

        {:error, _} ->
          {:ok, link, []}
      end
    else
      {:ok, link, []}
    end
  end

  defp do_receive_packet(link, packet, :data, :resource_adv) do
    case decrypt(link, packet.data) do
      {:ok, plaintext} ->
        link = update_phy_stats(link, packet)
        {:ok, link, [{:resource_advertisement, plaintext}]}

      {:error, _} ->
        {:ok, link, []}
    end
  end

  defp do_receive_packet(link, packet, :data, context)
       when context in [:resource_req, :resource_hmu, :resource_icl, :resource_rcl] do
    case decrypt(link, packet.data) do
      {:ok, plaintext} ->
        link = update_phy_stats(link, packet)
        {:ok, link, [{:resource_message, context, plaintext}]}

      {:error, _} ->
        {:ok, link, []}
    end
  end

  defp do_receive_packet(link, packet, :data, :resource) do
    link = update_phy_stats(link, packet)
    {:ok, link, [{:resource_data, packet}]}
  end

  defp do_receive_packet(link, packet, :proof, :resource_prf) do
    link = update_phy_stats(link, packet)
    {:ok, link, [{:resource_proof, packet.data}]}
  end

  defp do_receive_packet(link, _packet, _type, _context) do
    {:ok, link, []}
  end

  # ── Build data actions helper ──────────────────────────────────

  defp build_data_actions(link, packet, plaintext) do
    actions = []

    # Invoke packet callback
    actions =
      if link.callbacks && link.callbacks.packet do
        [{:callback, link.callbacks.packet, [plaintext, packet]} | actions]
      else
        actions
      end

    # Handle proof strategy
    dest = link.destination

    actions =
      cond do
        dest && Map.get(dest, :proof_strategy) == @prove_all ->
          packet_hash = Map.get(packet, :packet_hash, <<>>)
          [{:send_proof, packet_hash} | actions]

        dest && Map.get(dest, :proof_strategy) == @prove_app &&
          dest.callbacks && dest.callbacks.proof_requested ->
          try do
            if dest.callbacks.proof_requested.(packet) do
              packet_hash = Map.get(packet, :packet_hash, <<>>)
              [{:send_proof, packet_hash} | actions]
            else
              actions
            end
          rescue
            e ->
              Logger.warning("Link proof_requested callback raised: #{inspect(e)}")
              actions
          end

        true ->
          actions
      end

    Enum.reverse(actions)
  end

  # ── Handle request (on responder side) ─────────────────────────

  @doc """
  Handles an incoming request on the link.

  Returns `{:ok, response_actions, updated_link}` where response_actions
  contains the response to send.
  """
  @spec handle_request(t(), binary(), list()) :: {:ok, list(), t()}
  def handle_request(%__MODULE__{status: @status_active} = link, request_id, unpacked_request) do
    [requested_at, path_hash, request_data] = unpacked_request

    dest = link.destination

    allow_none = @allow_none
    allow_all = @allow_all
    allow_list = @allow_list

    if dest && Map.has_key?(dest, :request_handlers) &&
         Map.has_key?(dest.request_handlers, path_hash) do
      %RNS.Destination.RequestHandler{
        path: path,
        response_generator: response_generator,
        allow: allow,
        allowed_list: allowed_list
      } = Map.get(dest.request_handlers, path_hash)

      allowed =
        case allow do
          ^allow_none ->
            false

          ^allow_all ->
            true

          ^allow_list ->
            link.peer.remote_identity != nil and
              link.peer.remote_identity.hash in allowed_list

          _ ->
            false
        end

      if allowed do
        context = %{
          path: path,
          request_id: request_id,
          link_id: link.link_id,
          remote_identity: link.peer.remote_identity,
          requested_at: requested_at
        }

        response = response_generator.(request_data, context)

        if response != nil do
          packed_response = Msgpax.pack!([request_id, response]) |> IO.iodata_to_binary()

          if byte_size(packed_response) <= link.mdu do
            {:ok, [{:send_response, packed_response}], link}
          else
            {:ok, [{:send_response_resource, packed_response, request_id}], link}
          end
        else
          {:ok, [], link}
        end
      else
        {:ok, [], link}
      end
    else
      {:ok, [], link}
    end
  end

  def handle_request(%__MODULE__{} = link, _request_id, _unpacked_request) do
    {:ok, [], link}
  end

  # ── Handle response ────────────────────────────────────────────

  @doc """
  Handles a response to a pending request on the link.

  Finds the matching pending request by request_id and invokes its
  response callback.
  """
  @spec handle_response(t(), binary(), term(), non_neg_integer(), non_neg_integer()) :: t()
  def handle_response(
        %__MODULE__{status: @status_active} = link,
        request_id,
        response_data,
        response_size,
        response_transfer_size
      ) do
    {matching, remaining} =
      Enum.split_with(link.pending_requests, fn req ->
        Map.get(req, :request_id) == request_id
      end)

    case matching do
      [pending_request | _] ->
        if Map.has_key?(pending_request, :response_received) do
          pending_request.response_received.(response_data, response_size, response_transfer_size)
        end

        %{link | pending_requests: remaining}

      [] ->
        link
    end
  end

  def handle_response(
        %__MODULE__{} = link,
        _request_id,
        _response_data,
        _response_size,
        _response_transfer_size
      ) do
    link
  end

  # ── Resource management ────────────────────────────────────────

  @doc "Sets the resource acceptance strategy."
  @spec set_resource_strategy(t(), non_neg_integer()) :: t()
  def set_resource_strategy(%__MODULE__{} = link, strategy)
      when strategy in [@accept_none, @accept_app, @accept_all] do
    %{link | resource_strategy: strategy}
  end

  @doc "Registers an outgoing resource on the link."
  @spec register_outgoing_resource(t(), term()) :: t()
  def register_outgoing_resource(%__MODULE__{} = link, resource) do
    %{link | outgoing_resources: link.outgoing_resources ++ [resource]}
  end

  @doc "Registers an incoming resource on the link."
  @spec register_incoming_resource(t(), term()) :: t()
  def register_incoming_resource(%__MODULE__{} = link, resource) do
    %{link | incoming_resources: link.incoming_resources ++ [resource]}
  end

  @doc "Checks if an incoming resource with the same hash already exists."
  @spec has_incoming_resource?(t(), term()) :: boolean()
  def has_incoming_resource?(%__MODULE__{incoming_resources: resources}, resource) do
    resource_hash = Map.get(resource, :hash)
    Enum.any?(resources, fn r -> Map.get(r, :hash) == resource_hash end)
  end

  @doc "Removes an outgoing resource from the link."
  @spec cancel_outgoing_resource(t(), term()) :: t()
  def cancel_outgoing_resource(%__MODULE__{} = link, resource) do
    %{link | outgoing_resources: List.delete(link.outgoing_resources, resource)}
  end

  @doc "Removes an incoming resource from the link."
  @spec cancel_incoming_resource(t(), term()) :: t()
  def cancel_incoming_resource(%__MODULE__{} = link, resource) do
    %{link | incoming_resources: List.delete(link.incoming_resources, resource)}
  end

  @doc "Returns true if the link is ready for a new outgoing resource."
  @spec ready_for_new_resource?(t()) :: boolean()
  def ready_for_new_resource?(%__MODULE__{outgoing_resources: []}), do: true
  def ready_for_new_resource?(%__MODULE__{}), do: false

  @doc "Records resource conclusion and updates expected rate."
  @spec resource_concluded(t(), term()) :: t()
  def resource_concluded(%__MODULE__{} = link, resource) do
    concluded_at = System.system_time(:second)

    link =
      if resource in link.incoming_resources do
        started = Map.get(resource, :started_transferring, concluded_at)
        size = Map.get(resource, :size, 0)
        rate = size * 8 / max(concluded_at - started, 0.0001)

        %{
          link
          | last_resource_window: Map.get(resource, :window),
            last_resource_eifr: Map.get(resource, :eifr),
            incoming_resources: List.delete(link.incoming_resources, resource),
            expected_rate: rate
        }
      else
        link
      end

    if resource in link.outgoing_resources do
      started = Map.get(resource, :started_transferring, concluded_at)
      size = Map.get(resource, :size, 0)
      rate = size * 8 / max(concluded_at - started, 0.0001)

      %{
        link
        | outgoing_resources: List.delete(link.outgoing_resources, resource),
          expected_rate: rate
      }
    else
      link
    end
  end

  @doc "Returns the last resource window size."
  @spec get_last_resource_window(t()) :: non_neg_integer() | nil
  def get_last_resource_window(%__MODULE__{last_resource_window: w}), do: w

  @doc "Returns the last resource EIFR."
  @spec get_last_resource_eifr(t()) :: number() | nil
  def get_last_resource_eifr(%__MODULE__{last_resource_eifr: e}), do: e

  # ── Get MTU / Get MDU / Get expected rate (status-gated) ───────

  @doc "Returns the MTU of an established link."
  @spec get_mtu(t()) :: non_neg_integer() | nil
  def get_mtu(%__MODULE__{status: @status_active, mtu: mtu}), do: mtu
  def get_mtu(%__MODULE__{}), do: nil

  @doc "Returns the packet MDU of an established link."
  @spec get_mdu(t()) :: non_neg_integer() | nil
  def get_mdu(%__MODULE__{status: @status_active, mdu: mdu}), do: mdu
  def get_mdu(%__MODULE__{}), do: nil

  @doc "Returns the expected in-flight data rate of an established link."
  @spec get_expected_rate(t()) :: number() | nil
  def get_expected_rate(%__MODULE__{status: @status_active, expected_rate: rate}), do: rate
  def get_expected_rate(%__MODULE__{}), do: nil

  @doc "Returns the encryption mode of the link."
  @spec get_mode(t()) :: non_neg_integer()
  def get_mode(%__MODULE__{crypto: %CryptoState{mode: mode}}), do: mode

  # ── Watchdog check ─────────────────────────────────────────────

  @doc """
  Performs a watchdog check on the link state.

  Returns `{:ok, updated_link, actions}` where actions may include:
  - `{:send_keepalive}` — initiator should send keepalive
  - `{:teardown, reason}` — link should be torn down
  - `{:stale}` — link has gone stale

  This replaces the Python watchdog thread. Should be called periodically
  via `Process.send_after`.
  """
  @spec watchdog_check(t()) :: {:ok, t(), list()}
  def watchdog_check(%__MODULE__{status: @status_closed} = link) do
    {:ok, link, []}
  end

  def watchdog_check(%__MODULE__{status: @status_pending} = link) do
    establishment_timeout =
      @establishment_timeout_per_hop * max(1, link.stats.expected_hops || 1) + @keepalive

    if link.request_time &&
         System.system_time(:second) >= link.request_time + establishment_timeout do
      closed = %{link | status: @status_closed, teardown_reason: @timeout}
      closed = link_closed(closed)
      {:ok, closed, [{:teardown, :timeout}]}
    else
      {:ok, link, []}
    end
  end

  def watchdog_check(%__MODULE__{status: @status_handshake} = link) do
    establishment_timeout =
      @establishment_timeout_per_hop * max(1, link.stats.expected_hops || 1) + @keepalive

    if link.request_time &&
         System.system_time(:second) >= link.request_time + establishment_timeout do
      closed = %{link | status: @status_closed, teardown_reason: @timeout}
      closed = link_closed(closed)
      {:ok, closed, [{:teardown, :timeout}]}
    else
      {:ok, link, []}
    end
  end

  def watchdog_check(%__MODULE__{status: @status_active} = link) do
    activated = link.activated_at || 0
    last_inbound = max(max(link.stats.last_inbound, link.stats.last_proof), activated)
    now = System.system_time(:second)

    cond do
      now >= last_inbound + link.stale_time ->
        # Link is stale
        stale = %{link | status: @status_stale}
        {:ok, stale, [{:stale}]}

      now >= last_inbound + link.keepalive ->
        # Need keepalive
        actions =
          if link.initiator and now >= link.stats.last_keepalive + link.keepalive do
            [{:send_keepalive}]
          else
            []
          end

        {:ok, link, actions}

      true ->
        {:ok, link, []}
    end
  end

  def watchdog_check(%__MODULE__{status: @status_stale} = link) do
    # Stale link: send final teardown and close
    {teardown_data, closed} = teardown(link)
    closed = %{closed | teardown_reason: @timeout}

    actions =
      if teardown_data do
        [{:send_teardown, teardown_data}, {:teardown, :timeout}]
      else
        [{:teardown, :timeout}]
      end

    {:ok, closed, actions}
  end

  def watchdog_check(%__MODULE__{} = link) do
    {:ok, link, []}
  end
end

# ── String.Chars implementation ───────────────────────────────────

defimpl String.Chars, for: RNS.Link do
  def to_string(%RNS.Link{link_id: nil}), do: "<Link:uninitialized>"

  def to_string(%RNS.Link{link_id: link_id}) do
    RNS.prettyhexrep(link_id)
  end
end
