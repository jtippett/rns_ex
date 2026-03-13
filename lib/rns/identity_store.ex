defmodule RNS.IdentityStore do
  @moduledoc """
  ETS-backed GenServer for storing known destinations and ratchets.

  Backs `RNS.Identity.remember/4`, `RNS.Identity.recall/2`,
  `RNS.Identity.recall_app_data/1`, and ratchet operations.
  """

  use GenServer
  require Logger

  @destinations_table :rns_known_destinations
  @ratchets_table :rns_known_ratchets

  @truncated_hashlength_bytes div(128, 8)

  # --- Client API ---

  @doc "Starts the IdentityStore GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Configures the IdentityStore with a storage path and loads known
  destinations from disk. Called by Reticulum after config is loaded.
  """
  @spec configure(String.t()) :: :ok
  def configure(storagepath) do
    GenServer.call(__MODULE__, {:configure, storagepath})
  end

  @doc """
  Saves known destinations to disk at the configured storage path.
  """
  @spec save_known_destinations() :: :ok | {:error, term()}
  def save_known_destinations do
    GenServer.call(__MODULE__, :save_known_destinations)
  end

  @doc """
  Returns the configured storage path, or nil if not yet configured.
  """
  @spec storagepath() :: String.t() | nil
  def storagepath do
    GenServer.call(__MODULE__, :storagepath)
  end

  @doc """
  Stores a known destination.

  Entry format: `[timestamp, packet_hash, public_key, app_data]`
  """
  @spec remember(binary(), binary(), binary(), binary() | nil) ::
          :ok | {:error, :invalid_public_key}
  def remember(packet_hash, destination_hash, public_key, app_data \\ nil) do
    keysize_bytes = div(RNS.Identity.keysize(), 8)

    if byte_size(public_key) != keysize_bytes do
      {:error, :invalid_public_key}
    else
      entry = {System.system_time(:second), packet_hash, public_key, app_data}
      :ets.insert(@destinations_table, {destination_hash, entry})
      :ok
    end
  end

  @doc """
  Recalls an identity for a destination hash or identity hash.

  Returns an `RNS.Identity` struct with the public key loaded, or nil.
  """
  @spec recall(binary(), keyword()) :: RNS.Identity.t() | nil
  def recall(target_hash, opts \\ []) do
    from_identity_hash = Keyword.get(opts, :from_identity_hash, false)

    if from_identity_hash do
      recall_by_identity_hash(target_hash)
    else
      recall_by_destination_hash(target_hash)
    end
  end

  @doc """
  Recalls app_data for a known destination hash.

  Returns the app_data binary or nil.
  """
  @spec recall_app_data(binary()) :: binary() | nil
  def recall_app_data(destination_hash) do
    case :ets.lookup(@destinations_table, destination_hash) do
      [{_key, {_ts, _pkt_hash, _pub_key, app_data}}] -> app_data
      [] -> nil
    end
  end

  @doc "Stores a ratchet public key for a destination hash."
  @spec remember_ratchet(binary(), binary()) :: :ok
  def remember_ratchet(destination_hash, ratchet_pub_bytes) do
    :ets.insert(@ratchets_table, {destination_hash, ratchet_pub_bytes})
    :ok
  end

  @doc "Retrieves the ratchet public key for a destination hash."
  @spec get_ratchet(binary()) :: binary() | nil
  def get_ratchet(destination_hash) do
    case :ets.lookup(@ratchets_table, destination_hash) do
      [{_key, ratchet}] -> ratchet
      [] -> nil
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    ets_opts = [:set, :public, :named_table, read_concurrency: true]
    safe_create_table(@destinations_table, ets_opts)
    safe_create_table(@ratchets_table, ets_opts)
    {:ok, %{storagepath: nil}}
  end

  @impl true
  def handle_call({:configure, storagepath}, _from, state) do
    load_known_destinations(storagepath)
    {:reply, :ok, %{state | storagepath: storagepath}}
  end

  @impl true
  def handle_call(:save_known_destinations, _from, state) do
    result = do_save_known_destinations(state.storagepath)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:storagepath, _from, state) do
    {:reply, state.storagepath, state}
  end

  defp safe_create_table(name, opts) do
    case :ets.info(name) do
      :undefined ->
        :ets.new(name, opts)

      _ ->
        :ets.delete_all_objects(name)
        name
    end
  end

  # --- Persistence ---

  defp load_known_destinations(storagepath) do
    file_path = Path.join(storagepath, "known_destinations")

    if File.exists?(file_path) do
      try do
        data = File.read!(file_path)
        loaded = Msgpax.unpack!(data)

        count =
          Enum.reduce(loaded, 0, fn
            {dest_hash, [ts, pkt_hash, pub_key, app_data]}, acc
            when is_binary(dest_hash) and byte_size(dest_hash) == @truncated_hashlength_bytes ->
              entry = {ts, pkt_hash, pub_key, app_data}
              :ets.insert(@destinations_table, {dest_hash, entry})
              acc + 1

            _, acc ->
              acc
          end)

        Logger.info("Loaded #{count} known destinations from storage")
      rescue
        e ->
          Logger.error(
            "Error loading known destinations from disk, " <>
              "file will be recreated on exit: #{Exception.message(e)}"
          )
      end
    else
      Logger.debug("Destinations file does not exist, no known destinations loaded")
    end
  end

  defp do_save_known_destinations(nil) do
    Logger.debug("No storage path configured, skipping known destinations save")
    {:error, :no_storagepath}
  end

  defp do_save_known_destinations(storagepath) do
    file_path = Path.join(storagepath, "known_destinations")

    try do
      destinations =
        :ets.tab2list(@destinations_table)
        |> Map.new(fn {dest_hash, {ts, pkt_hash, pub_key, app_data}} ->
          {dest_hash, [ts, pkt_hash, pub_key, app_data]}
        end)

      packed = Msgpax.pack!(destinations, iodata: false)
      File.write!(file_path, packed)

      Logger.debug("Saved #{map_size(destinations)} known destinations to storage")
      :ok
    rescue
      e ->
        Logger.error("Error saving known destinations to disk: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  # --- Private ---

  defp recall_by_destination_hash(destination_hash) do
    case :ets.lookup(@destinations_table, destination_hash) do
      [{_key, {_ts, _pkt_hash, public_key, app_data}}] ->
        build_identity_from_public_key(public_key, app_data)

      [] ->
        nil
    end
  end

  defp recall_by_identity_hash(target_hash) do
    result =
      :ets.foldl(
        fn {_dest_hash, {_ts, _pkt_hash, public_key, app_data}}, acc ->
          if acc == nil do
            if RNS.Identity.truncated_hash(public_key) == target_hash do
              {public_key, app_data}
            else
              nil
            end
          else
            acc
          end
        end,
        nil,
        @destinations_table
      )

    case result do
      {public_key, app_data} -> build_identity_from_public_key(public_key, app_data)
      nil -> nil
    end
  end

  defp build_identity_from_public_key(public_key, app_data) do
    id = RNS.Identity.new(create_keys: false)
    id = RNS.Identity.load_public_key(id, public_key)
    %{id | app_data: app_data}
  end
end
