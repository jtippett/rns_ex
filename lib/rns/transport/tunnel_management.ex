defmodule RNS.Transport.TunnelManagement do
  @moduledoc """
  Manages transport tunnels for the RNS Transport system.

  Handles tunnel establishment, path restoration when tunnels reappear,
  and tunnel interface voiding.
  """

  require Logger

  alias RNS.Identity
  alias RNS.Transport
  alias RNS.Transport.TunnelEntry

  # ── Tunnel Synthesize Handler ─────────────────────────────────────

  @doc """
  Processes a tunnel establishment packet.

  Validates the packet's signature and, if valid, calls `handle_tunnel/2`
  to register or restore the tunnel.

  Expected data layout:
    - public_key:     KEYSIZE/8 bytes (64 bytes)
    - interface_hash: HASHLENGTH/8 bytes (32 bytes)
    - random_hash:    TRUNCATED_HASHLENGTH/8 bytes (16 bytes)
    - signature:      SIGLENGTH/8 bytes (64 bytes)

  Total expected length: 64 + 32 + 16 + 64 = 176 bytes
  """
  @spec tunnel_synthesize_handler(binary(), map()) :: :ok | :invalid
  def tunnel_synthesize_handler(data, packet) do
    keysize_bytes = div(Identity.keysize(), 8)
    hashlength_bytes = div(Identity.hashlength(), 8)
    truncated_hashlength_bytes = div(Identity.truncated_hashlength(), 8)
    siglength_bytes = div(Identity.siglength(), 8)

    expected_length =
      keysize_bytes + hashlength_bytes + truncated_hashlength_bytes + siglength_bytes

    if byte_size(data) == expected_length do
      try do
        <<public_key::binary-size(keysize_bytes), interface_hash::binary-size(hashlength_bytes),
          random_hash::binary-size(truncated_hashlength_bytes),
          signature::binary-size(siglength_bytes)>> = data

        tunnel_id_data = public_key <> interface_hash
        tunnel_id = Identity.full_hash(tunnel_id_data)

        signed_data = tunnel_id_data <> random_hash

        # Create identity from public key and validate signature
        remote_identity = Identity.new(create_keys: false)
        remote_identity = Identity.load_public_key(remote_identity, public_key)

        if Identity.validate(remote_identity, signature, signed_data) do
          receiving_interface = Map.get(packet, :receiving_interface)
          handle_tunnel(tunnel_id, receiving_interface)
          :ok
        else
          RNS.Log.trace("Tunnel establishment packet signature validation failed")
          :invalid
        end
      rescue
        e ->
          RNS.Log.trace("Error validating tunnel establishment packet: #{Exception.message(e)}")
          :invalid
      end
    else
      :invalid
    end
  end

  # ── Handle Tunnel ─────────────────────────────────────────────────

  @doc """
  Registers a new tunnel or restores an existing one.

  For new tunnels:
  - Creates a new TunnelEntry with empty paths
  - Sets the tunnel_id on the interface

  For existing tunnels (reappearing):
  - Updates the interface and expiry
  - Restores valid paths to the path table
  - Removes deprecated paths from the tunnel
  """
  @spec handle_tunnel(binary(), map() | nil) :: :ok
  def handle_tunnel(tunnel_id, interface) do
    expires = System.system_time(:second) + Transport.destination_timeout()

    case Transport.get_tunnel_entry(tunnel_id) do
      nil ->
        # New tunnel
        Logger.debug("Tunnel endpoint #{Base.encode16(tunnel_id)} established")

        entry = %TunnelEntry{
          tunnel_id: tunnel_id,
          interface: interface,
          paths: %{},
          expires: expires
        }

        Transport.put_tunnel_entry(tunnel_id, entry)

      existing ->
        # Tunnel reappearing — restore paths
        Logger.debug("Tunnel endpoint #{Base.encode16(tunnel_id)} reappeared. Restoring paths...")

        updated = %{existing | interface: interface, expires: expires}
        Transport.put_tunnel_entry(tunnel_id, updated)

        restore_tunnel_paths(tunnel_id, existing.paths, interface)
    end

    :ok
  end

  # ── Void Tunnel Interface ─────────────────────────────────────────

  @doc """
  Voids (nullifies) the interface for a tunnel, typically when the
  underlying transport connection is lost.
  """
  @spec void_tunnel_interface(binary()) :: :ok
  def void_tunnel_interface(tunnel_id) do
    case Transport.get_tunnel_entry(tunnel_id) do
      nil ->
        :ok

      entry ->
        Logger.debug("Voiding tunnel interface for #{Base.encode16(tunnel_id)}")
        Transport.put_tunnel_entry(tunnel_id, %{entry | interface: nil})
        :ok
    end
  end

  # ── Private Helpers ───────────────────────────────────────────────

  defp restore_tunnel_paths(tunnel_id, paths, interface) do
    now = System.system_time(:second)

    deprecated_paths =
      Enum.reduce(paths, [], fn {destination_hash, path_entry}, deprecated ->
        received_from = path_entry.next_hop
        announce_hops = path_entry.hops
        expires = path_entry.expires
        random_blobs = Enum.uniq(path_entry.random_blobs || [])
        packet_hash = path_entry.packet_hash

        should_add =
          case Transport.get_path_entry(destination_hash) do
            nil ->
              # No existing path — add if not expired
              now < expires

            old_entry ->
              # Existing path — add only if fewer/equal hops or expired
              announce_hops <= old_entry.hops or now > old_entry.expires
          end

        if should_add do
          new_entry = %Transport.PathEntry{
            timestamp: now,
            next_hop: received_from,
            hops: announce_hops,
            expires: expires,
            random_blobs: random_blobs,
            interface: interface,
            packet_hash: packet_hash
          }

          Transport.put_path_entry(destination_hash, new_entry)

          Logger.debug(
            "Restored path to #{Base.encode16(destination_hash)} — " <>
              "#{announce_hops} hops away via #{Base.encode16(received_from || <<>>)}"
          )

          deprecated
        else
          Logger.debug(
            "Did not restore path to #{Base.encode16(destination_hash)} from tunnel #{Base.encode16(tunnel_id)}"
          )

          [destination_hash | deprecated]
        end
      end)

    # Remove deprecated paths from the tunnel entry
    if deprecated_paths != [] do
      case Transport.get_tunnel_entry(tunnel_id) do
        nil ->
          :ok

        entry ->
          updated_paths = Map.drop(entry.paths, deprecated_paths)
          Transport.put_tunnel_entry(tunnel_id, %{entry | paths: updated_paths})
      end
    end
  end
end
