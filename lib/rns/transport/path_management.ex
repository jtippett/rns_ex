defmodule RNS.Transport.PathManagement do
  @moduledoc """
  Path table management for the RNS Transport system.

  Handles path table persistence (save/load) and path discovery operations.
  """

  require Logger

  alias RNS.Transport
  alias RNS.Transport.PathEntry

  @path_table :rns_path_table

  @doc """
  Saves the current path table to disk using MessagePack serialization.

  Only entries with active interfaces are persisted. Random blobs are
  truncated to `PERSIST_RANDOM_BLOBS` (32) entries.
  """
  @spec save_path_table(String.t()) :: :ok | {:error, term()}
  def save_path_table(file_path) do
    serialized =
      :ets.tab2list(@path_table)
      |> Enum.reduce([], fn {destination_hash, entry}, acc ->
        interface_hash =
          if is_map(entry.interface) do
            entry.interface.hash
          else
            nil
          end

        # Only persist if the interface is still active
        if interface_hash && Transport.find_interface_from_hash(interface_hash) do
          random_blobs = Enum.take(entry.random_blobs || [], -Transport.persist_random_blobs())

          serialized_entry = [
            destination_hash,
            entry.timestamp,
            entry.next_hop,
            entry.hops,
            entry.expires,
            random_blobs,
            interface_hash,
            entry.packet_hash
          ]

          [serialized_entry | acc]
        else
          acc
        end
      end)

    packed = Msgpax.pack!(serialized, iodata: false)

    case File.write(file_path, packed) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Path table save failed at #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Loads a path table from disk, restoring entries with active interfaces
  and non-expired timestamps.
  """
  @spec load_path_table(String.t()) :: :ok | {:error, term()}
  def load_path_table(file_path) do
    with {:ok, data} <- File.read(file_path),
         {:ok, entries} <- Msgpax.unpack(data) do
      now = System.system_time(:second)

      Enum.each(entries, fn serialized_entry ->
        [
          destination_hash,
          timestamp,
          received_from,
          hops,
          expires,
          random_blobs,
          interface_hash,
          packet_hash
        ] = serialized_entry

        # Only restore if the entry hasn't expired
        if now < expires do
          # Only restore if the interface is still active
          interface = Transport.find_interface_from_hash(interface_hash)

          if interface do
            entry = %PathEntry{
              timestamp: timestamp,
              next_hop: received_from,
              hops: hops,
              expires: expires,
              random_blobs: random_blobs || [],
              interface: interface,
              packet_hash: packet_hash
            }

            # Check if a better path already exists
            case :ets.lookup(@path_table, destination_hash) do
              [{^destination_hash, existing}] ->
                # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                if hops <= existing.hops or now > existing.expires do
                  :ets.insert(@path_table, {destination_hash, entry})
                end

              [] ->
                :ets.insert(@path_table, {destination_hash, entry})
            end
          end
        end
      end)

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
