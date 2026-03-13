defmodule RNS.Transport.CacheManagement do
  @moduledoc """
  Cache management for the RNS Transport system.

  Handles packet caching to disk, cache retrieval, cache cleaning,
  packet hashlist persistence, and tunnel table persistence.

  Ported from caching-related logic in `python/RNS/Transport.py`.
  """

  require Logger

  alias RNS.Transport
  alias RNS.Transport.PathEntry
  alias RNS.Transport.TunnelEntry
  alias RNS.Packet

  @packet_hashlist_table :rns_packet_hashlist
  @path_table :rns_path_table
  @tunnel_table :rns_tunnel_table

  @persist_random_blobs 32

  # ── Should Cache ─────────────────────────────────────────────────

  @doc """
  Determines whether a packet should be cached.

  Currently always returns false — caching is disabled in the
  Python reference implementation as well (TODO: redesign).
  """
  @spec should_cache(map()) :: boolean()
  def should_cache(_packet), do: false

  # ── Cache Packet to Disk ─────────────────────────────────────────

  @doc """
  Caches a packet to disk storage.

  Announce packets are stored in a separate `announces/` subdirectory.
  Other packets are stored directly in the cache directory.

  Packets are stored as MessagePack-serialized `[raw_bytes, interface_reference]`.

  Note: Packets are cached exactly as they arrived — their hop count
  has NOT been incremented yet. Take note when reading from cache.
  """
  @spec cache(map(), keyword()) :: :ok | {:error, term()}
  def cache(packet, opts \\ []) do
    force_cache = Keyword.get(opts, :force_cache, false)
    packet_type = Keyword.get(opts, :packet_type, nil)

    if force_cache or should_cache(packet) do
      try do
        hash = packet.packet_hash || Packet.get_hash(packet)
        packet_hash = Base.encode16(hash, case: :lower)

        interface_reference =
          if packet.receiving_interface != nil do
            inspect(packet.receiving_interface)
          else
            nil
          end

        cachepath = cache_file_path(packet_hash, packet_type)

        # Ensure directory exists
        cachepath |> Path.dirname() |> File.mkdir_p!()

        packed = Msgpax.pack!([packet.raw, interface_reference], iodata: false)
        File.write!(cachepath, packed)
        :ok
      rescue
        e ->
          Logger.error("Error writing packet to cache: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end
    else
      :ok
    end
  end

  # ── Get Cached Packet ────────────────────────────────────────────

  @doc """
  Retrieves a cached packet from disk.

  Returns a reconstructed Packet struct with the receiving_interface
  restored by matching against active interfaces, or nil if not found.
  """
  @spec get_cached_packet(binary(), keyword()) :: map() | nil
  def get_cached_packet(packet_hash, opts \\ []) do
    packet_type = Keyword.get(opts, :packet_type, nil)

    try do
      hex_hash = Base.encode16(packet_hash, case: :lower)
      path = cache_file_path(hex_hash, packet_type)

      if File.exists?(path) do
        data = File.read!(path)
        [raw, interface_reference] = Msgpax.unpack!(data)

        packet = Packet.new(nil, raw)

        # Restore receiving_interface by matching against active interfaces
        packet =
          if interface_reference != nil do
            interfaces = Transport.get_interfaces()

            matched =
              Enum.find(interfaces, fn iface ->
                inspect(iface) == interface_reference
              end)

            if matched do
              %{packet | receiving_interface: matched}
            else
              packet
            end
          else
            packet
          end

        packet
      else
        nil
      end
    rescue
      e ->
        Logger.error("Exception getting cached packet: #{Exception.message(e)}")
        nil
    end
  end

  # ── Cache Request Packet ─────────────────────────────────────────

  @doc """
  Handles a cache request packet.

  If the packet data contains a valid hash (HASHLENGTH/8 bytes),
  retrieves the cached packet and replays it to transport.

  Returns true if the packet was found and replayed, false otherwise.
  """
  @spec cache_request_packet(map()) :: boolean()
  def cache_request_packet(packet) do
    hashlength_bytes = div(256, 8)

    if byte_size(packet.data) == hashlength_bytes do
      cached = get_cached_packet(packet.data)

      if cached != nil do
        Transport.inbound(cached.raw, cached.receiving_interface)
        true
      else
        false
      end
    else
      false
    end
  end

  # ── Cache Request ────────────────────────────────────────────────

  @doc """
  Requests a cached packet by hash.

  First checks local cache. If found, replays to transport.
  If not found, sends a CACHE_REQUEST packet to the network.
  """
  @spec cache_request(binary(), map()) :: :ok
  def cache_request(packet_hash, destination) do
    cached = get_cached_packet(packet_hash)

    if cached do
      Transport.inbound(cached.raw, cached.receiving_interface)
    else
      # Send a CACHE_REQUEST packet to the network
      packet = Packet.new(destination, packet_hash, context: 0x08)

      if is_function(Map.get(packet, :send), 0) do
        packet.send.()
      end
    end

    :ok
  end

  # ── Clean Cache ──────────────────────────────────────────────────

  @doc """
  Cleans the packet cache.

  Removes cached announce packets that are no longer referenced by
  active path table entries or tunnel paths.
  """
  @spec clean_cache(String.t()) :: :ok
  def clean_cache(cachepath) do
    clean_announce_cache(cachepath)
    :ok
  end

  @doc """
  Cleans the announce cache directory.

  Iterates through all files in `cachepath/announces/` and removes
  any cached announces not referenced in the active path_table or
  tunnel paths.
  """
  @spec clean_announce_cache(String.t()) :: :ok
  def clean_announce_cache(cachepath) do
    target_path = Path.join(cachepath, "announces")

    if File.dir?(target_path) do
      # Collect active packet hashes from path table
      active_paths =
        :ets.tab2list(@path_table)
        |> Enum.map(fn {_dest, entry} -> entry.packet_hash end)
        |> MapSet.new()

      # Collect packet hashes from tunnel paths
      tunnel_paths =
        :ets.tab2list(@tunnel_table)
        |> Enum.flat_map(fn {_id, entry} ->
          entry.paths
          |> Map.values()
          |> Enum.map(fn path_entry -> path_entry.packet_hash end)
        end)
        |> MapSet.new()

      all_active = MapSet.union(active_paths, tunnel_paths)

      removed =
        target_path
        |> File.ls!()
        |> Enum.reduce(0, fn filename, count ->
          full_path = Path.join(target_path, filename)

          if File.regular?(full_path) do
            remove =
              try do
                target_hash = Base.decode16!(filename, case: :mixed)
                not MapSet.member?(all_active, target_hash)
              rescue
                _ -> true
              end

            if remove do
              File.rm(full_path)
              count + 1
            else
              count
            end
          else
            count
          end
        end)

      if removed > 0 do
        Logger.debug("Removed #{removed} cached announces")
      end
    end

    :ok
  end

  # ── Packet Hashlist Persistence ──────────────────────────────────

  @doc """
  Saves the packet hashlist to disk using MessagePack serialization.
  """
  @spec save_packet_hashlist(String.t()) :: :ok | {:error, term()}
  def save_packet_hashlist(file_path) do
    try do
      hashlist =
        :ets.tab2list(@packet_hashlist_table)
        |> Enum.map(fn {hash, _} -> hash end)

      packed = Msgpax.pack!(hashlist, iodata: false)
      File.write!(file_path, packed)

      Logger.debug("Saved #{length(hashlist)} packet hashlist entries")
      :ok
    rescue
      e ->
        Logger.error("Could not save packet hashlist: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Loads the packet hashlist from disk.

  Deserializes the hashlist and inserts each hash into the
  packet hashlist ETS table.
  """
  @spec load_packet_hashlist(String.t()) :: :ok | {:error, term()}
  def load_packet_hashlist(file_path) do
    if File.exists?(file_path) do
      try do
        data = File.read!(file_path)
        hashlist = Msgpax.unpack!(data)

        Enum.each(hashlist, fn hash ->
          :ets.insert(@packet_hashlist_table, {hash, true})
        end)

        Logger.debug("Loaded #{length(hashlist)} packet hashlist entries")
        :ok
      rescue
        e ->
          Logger.error("Could not load packet hashlist: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end
    else
      {:error, :enoent}
    end
  end

  # ── Tunnel Table Persistence ─────────────────────────────────────

  @doc """
  Saves the tunnel table to disk using MessagePack serialization.

  Each tunnel entry is serialized as:
    [tunnel_id, interface_hash, [serialized_paths], expires]

  where each serialized path is:
    [destination_hash, timestamp, received_from, hops, expires,
     random_blobs, interface_hash, packet_hash]
  """
  @spec save_tunnel_table(String.t()) :: :ok | {:error, term()}
  def save_tunnel_table(file_path) do
    try do
      serialized_tunnels =
        :ets.tab2list(@tunnel_table)
        |> Enum.map(fn {_tunnel_id, entry} ->
          interface_hash =
            if is_map(entry.interface) do
              entry.interface.hash
            else
              nil
            end

          serialized_paths =
            Enum.map(entry.paths, fn {destination_hash, path_entry} ->
              random_blobs =
                (path_entry.random_blobs || [])
                |> Enum.take(-@persist_random_blobs)

              path_interface_hash =
                if is_map(path_entry.interface) do
                  path_entry.interface.hash
                else
                  interface_hash
                end

              [
                destination_hash,
                path_entry.timestamp,
                path_entry.next_hop,
                path_entry.hops,
                path_entry.expires,
                random_blobs,
                path_interface_hash,
                path_entry.packet_hash
              ]
            end)

          [entry.tunnel_id, interface_hash, serialized_paths, entry.expires]
        end)

      packed = Msgpax.pack!(serialized_tunnels, iodata: false)
      File.write!(file_path, packed)

      Logger.debug("Saved #{length(serialized_tunnels)} tunnel table entries")
      :ok
    rescue
      e ->
        Logger.error("Could not save tunnel table: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Loads the tunnel table from disk.

  Deserializes tunnel entries and reconstructs TunnelEntry structs
  with their associated path entries. Only loads tunnels that have
  at least one valid path.
  """
  @spec load_tunnel_table(String.t()) :: :ok | {:error, term()}
  def load_tunnel_table(file_path) do
    if File.exists?(file_path) do
      try do
        data = File.read!(file_path)
        serialized_tunnels = Msgpax.unpack!(data)

        Enum.each(serialized_tunnels, fn serialized_tunnel ->
          [tunnel_id, _interface_hash, serialized_paths, expires] = serialized_tunnel

          tunnel_paths =
            Enum.reduce(serialized_paths, %{}, fn serialized_entry, paths ->
              [
                destination_hash,
                timestamp,
                received_from,
                hops,
                path_expires,
                random_blobs,
                _path_interface_hash,
                packet_hash
              ] = serialized_entry

              random_blobs = Enum.uniq(random_blobs || [])

              path_entry = %PathEntry{
                timestamp: timestamp,
                next_hop: received_from,
                hops: hops,
                expires: path_expires,
                random_blobs: random_blobs,
                interface: nil,
                packet_hash: packet_hash
              }

              Map.put(paths, destination_hash, path_entry)
            end)

          if map_size(tunnel_paths) > 0 do
            entry = %TunnelEntry{
              tunnel_id: tunnel_id,
              interface: nil,
              paths: tunnel_paths,
              expires: expires
            }

            Transport.put_tunnel_entry(tunnel_id, entry)
          end
        end)

        tunnel_count = :ets.info(@tunnel_table, :size)
        Logger.debug("Loaded #{tunnel_count} tunnel table entries")
        :ok
      rescue
        e ->
          Logger.error("Could not load tunnel table: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end
    else
      {:error, :enoent}
    end
  end

  # ── Persist All Data ─────────────────────────────────────────────

  @doc """
  Persists all transport data to disk.

  Saves the packet hashlist, path table, and tunnel table.
  """
  @spec persist_data(String.t()) :: :ok
  def persist_data(storage_path) do
    save_packet_hashlist(Path.join(storage_path, "packet_hashlist"))
    Transport.save_path_table(Path.join(storage_path, "destination_table"))
    save_tunnel_table(Path.join(storage_path, "tunnels"))
    :ok
  end

  # ── Private Helpers ──────────────────────────────────────────────

  defp cache_file_path(hex_hash, packet_type) do
    cachepath = get_cachepath()

    if packet_type == "announce" do
      Path.join([cachepath, "announces", hex_hash])
    else
      Path.join(cachepath, hex_hash)
    end
  end

  defp get_cachepath do
    # Use Application env if available, otherwise use a default
    Application.get_env(:rns_ex, :cachepath, "/tmp/rns_cache")
  end
end
