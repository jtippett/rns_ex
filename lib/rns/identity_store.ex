defmodule RNS.IdentityStore do
  @moduledoc """
  ETS-backed GenServer for storing known destinations and ratchets.

  Backs `RNS.Identity.remember/4`, `RNS.Identity.recall/2`,
  `RNS.Identity.recall_app_data/1`, and ratchet operations.

  Matches the class-level storage in `python/RNS/Identity.py`.
  """

  use GenServer

  @destinations_table :rns_known_destinations
  @ratchets_table :rns_known_ratchets

  # --- Client API ---

  @doc "Starts the IdentityStore GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
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
    :ets.new(@destinations_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@ratchets_table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
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
