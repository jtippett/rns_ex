defmodule RNS.Transport do
  @moduledoc """
  The Transport module handles routing, path management, and packet forwarding
  for the Reticulum Network Stack. It maintains routing tables backed by ETS
  for concurrent read access and provides path discovery and management.

  Ported from `python/RNS/Transport.py`.
  """
  use GenServer
  require Logger

  alias RNS.Transport.PathManagement
  alias RNS.Transport.AnnounceHandler

  # ── Transport Type Constants ──────────────────────────────────────────
  @broadcast 0x00
  @transport 0x01
  @relay 0x02
  @tunnel 0x03
  @types [@broadcast, @transport, @relay, @tunnel]

  # ── Reachability Constants ────────────────────────────────────────────
  @reachability_unreachable 0x00
  @reachability_direct 0x01
  @reachability_transport 0x02

  # ── App Name ──────────────────────────────────────────────────────────
  @app_name "rnstransport"

  # ── Pathfinder Parameters ─────────────────────────────────────────────
  @pathfinder_m 128
  @pathfinder_r 1
  @pathfinder_g 5
  @pathfinder_rw 0.5
  @pathfinder_e 60 * 60 * 24 * 7

  # ── Path Time Expirations ─────────────────────────────────────────────
  @ap_path_time 60 * 60 * 24
  @roaming_path_time 60 * 60 * 6

  # ── Announce Parameters ───────────────────────────────────────────────
  @local_rebroadcasts_max 2
  @path_request_timeout 15
  @path_request_grace 0.4
  @path_request_rg 1.5
  @path_request_mi 20

  # ── Path State Constants ──────────────────────────────────────────────
  @state_unknown 0x00
  @state_unresponsive 0x01
  @state_responsive 0x02

  # ── Timeout Constants ─────────────────────────────────────────────────
  # STALE_TIME = STALE_FACTOR(2) * KEEPALIVE(360) = 720
  @link_timeout trunc(720 * 1.25)
  @reverse_timeout 8 * 60
  @destination_timeout 60 * 60 * 24 * 7

  # ── Storage/Memory Limits ─────────────────────────────────────────────
  @max_receipts 1024
  @max_rate_timestamps 16
  @persist_random_blobs 32
  @max_random_blobs 64
  @local_client_cache_maxsize 512
  @max_pr_tags 32_000
  @hashlist_maxsize 1_000_000

  # ── Job Intervals (milliseconds for Process.send_after) ───────────────
  @job_interval 250
  @links_check_interval 1_000
  @receipts_check_interval 1_000
  @announces_check_interval 1_000
  @tables_cull_interval 5_000
  @interface_jobs_interval 5_000
  @cache_clean_interval 300_000

  # ── ETS Table Names ───────────────────────────────────────────────────
  @destinations_table :rns_destinations
  @interfaces_table :rns_interfaces
  @pending_links_table :rns_pending_links
  @active_links_table :rns_active_links
  @packet_hashlist_table :rns_packet_hashlist
  @receipts_table :rns_receipts
  @announce_table :rns_announce_table
  @path_table :rns_path_table
  @reverse_table :rns_reverse_table
  @link_table :rns_link_table
  @held_announces_table :rns_held_announces
  @tunnel_table :rns_tunnel_table
  @announce_rate_table :rns_announce_rate_table
  @path_requests_table :rns_path_requests
  @path_states_table :rns_path_states

  # ── Public Constant Accessors ─────────────────────────────────────────

  @doc "Transport type: BROADCAST (0x00)"
  @spec broadcast() :: 0x00
  def broadcast, do: @broadcast

  @doc "Transport type: TRANSPORT (0x01)"
  @spec transport() :: 0x01
  def transport, do: @transport

  @doc "Transport type: RELAY (0x02)"
  @spec relay() :: 0x02
  def relay, do: @relay

  @doc "Transport type: TUNNEL (0x03)"
  @spec tunnel() :: 0x03
  def tunnel, do: @tunnel

  @doc "All valid transport types"
  @spec types() :: [non_neg_integer()]
  def types, do: @types

  @spec reachability_unreachable() :: 0x00
  def reachability_unreachable, do: @reachability_unreachable

  @spec reachability_direct() :: 0x01
  def reachability_direct, do: @reachability_direct

  @spec reachability_transport() :: 0x02
  def reachability_transport, do: @reachability_transport

  @spec app_name() :: String.t()
  def app_name, do: @app_name

  @spec pathfinder_m() :: 128
  def pathfinder_m, do: @pathfinder_m

  @spec pathfinder_r() :: 1
  def pathfinder_r, do: @pathfinder_r

  @spec pathfinder_g() :: 5
  def pathfinder_g, do: @pathfinder_g

  @spec pathfinder_rw() :: float()
  def pathfinder_rw, do: @pathfinder_rw

  @spec pathfinder_e() :: non_neg_integer()
  def pathfinder_e, do: @pathfinder_e

  @spec ap_path_time() :: non_neg_integer()
  def ap_path_time, do: @ap_path_time

  @spec roaming_path_time() :: non_neg_integer()
  def roaming_path_time, do: @roaming_path_time

  @spec local_rebroadcasts_max() :: 2
  def local_rebroadcasts_max, do: @local_rebroadcasts_max

  @spec path_request_timeout() :: 15
  def path_request_timeout, do: @path_request_timeout

  @spec path_request_grace() :: float()
  def path_request_grace, do: @path_request_grace

  @spec path_request_rg() :: float()
  def path_request_rg, do: @path_request_rg

  @spec path_request_mi() :: 20
  def path_request_mi, do: @path_request_mi

  @spec state_unknown() :: 0x00
  def state_unknown, do: @state_unknown

  @spec state_unresponsive() :: 0x01
  def state_unresponsive, do: @state_unresponsive

  @spec state_responsive() :: 0x02
  def state_responsive, do: @state_responsive

  @spec link_timeout() :: non_neg_integer()
  def link_timeout, do: @link_timeout

  @spec reverse_timeout() :: non_neg_integer()
  def reverse_timeout, do: @reverse_timeout

  @spec destination_timeout() :: non_neg_integer()
  def destination_timeout, do: @destination_timeout

  @spec max_receipts() :: 1024
  def max_receipts, do: @max_receipts

  @spec max_rate_timestamps() :: 16
  def max_rate_timestamps, do: @max_rate_timestamps

  @spec persist_random_blobs() :: 32
  def persist_random_blobs, do: @persist_random_blobs

  @spec max_random_blobs() :: 64
  def max_random_blobs, do: @max_random_blobs

  @spec local_client_cache_maxsize() :: 512
  def local_client_cache_maxsize, do: @local_client_cache_maxsize

  @spec max_pr_tags() :: 32_000
  def max_pr_tags, do: @max_pr_tags

  @spec hashlist_maxsize() :: 1_000_000
  def hashlist_maxsize, do: @hashlist_maxsize

  @spec job_interval() :: 250
  def job_interval, do: @job_interval

  @spec links_check_interval() :: 1_000
  def links_check_interval, do: @links_check_interval

  @spec receipts_check_interval() :: 1_000
  def receipts_check_interval, do: @receipts_check_interval

  @spec announces_check_interval() :: 1_000
  def announces_check_interval, do: @announces_check_interval

  @spec tables_cull_interval() :: 5_000
  def tables_cull_interval, do: @tables_cull_interval

  @spec interface_jobs_interval() :: 5_000
  def interface_jobs_interval, do: @interface_jobs_interval

  @spec cache_clean_interval() :: 300_000
  def cache_clean_interval, do: @cache_clean_interval

  # ── PathEntry struct ──────────────────────────────────────────────────

  defmodule PathEntry do
    @moduledoc """
    A single entry in the path table.

    Corresponds to the Python path table 7-element list:
      [timestamp, next_hop, hops, expires, random_blobs, interface, packet_hash]
    """
    @type t :: %__MODULE__{
            timestamp: non_neg_integer(),
            next_hop: binary(),
            hops: non_neg_integer(),
            expires: non_neg_integer(),
            random_blobs: [binary()],
            interface: map() | nil,
            packet_hash: binary()
          }

    defstruct [:timestamp, :next_hop, :hops, :expires, :random_blobs, :interface, :packet_hash]
  end

  # ── GenServer Client API ──────────────────────────────────────────────

  @doc "Starts the Transport GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── Destination Registration ──────────────────────────────────────────

  @doc "Registers a destination with the Transport system."
  @spec register_destination(map()) :: :ok | {:error, :already_registered}
  def register_destination(destination) do
    GenServer.call(__MODULE__, {:register_destination, destination})
  end

  @doc "Deregisters a destination from the Transport system."
  @spec deregister_destination(map()) :: :ok
  def deregister_destination(destination) do
    GenServer.call(__MODULE__, {:deregister_destination, destination})
  end

  @doc "Checks if a destination with the given hash is registered."
  @spec destination_registered?(binary()) :: boolean()
  def destination_registered?(hash) do
    :ets.member(@destinations_table, hash)
  end

  @doc "Returns all registered destinations."
  @spec get_destinations() :: [map()]
  def get_destinations do
    :ets.tab2list(@destinations_table) |> Enum.map(fn {_hash, dest} -> dest end)
  end

  # ── Interface Registration ────────────────────────────────────────────

  @doc "Registers an interface with the Transport system."
  @spec register_interface(map()) :: :ok
  def register_interface(interface) do
    GenServer.call(__MODULE__, {:register_interface, interface})
  end

  @doc "Deregisters an interface from the Transport system."
  @spec deregister_interface(map()) :: :ok
  def deregister_interface(interface) do
    GenServer.call(__MODULE__, {:deregister_interface, interface})
  end

  @doc "Checks if an interface with the given hash is registered."
  @spec interface_registered?(binary()) :: boolean()
  def interface_registered?(hash) do
    :ets.member(@interfaces_table, hash)
  end

  @doc "Returns all registered interfaces."
  @spec get_interfaces() :: [map()]
  def get_interfaces do
    :ets.tab2list(@interfaces_table) |> Enum.map(fn {_hash, iface} -> iface end)
  end

  @doc "Finds an interface by its hash."
  @spec find_interface_from_hash(binary()) :: map() | nil
  def find_interface_from_hash(hash) do
    case :ets.lookup(@interfaces_table, hash) do
      [{^hash, interface}] -> interface
      [] -> nil
    end
  end

  # ── Path Table Queries (direct ETS reads for concurrency) ─────────────

  @doc "Returns true if a path to the destination is known."
  @spec has_path(binary()) :: boolean()
  def has_path(destination_hash) do
    :ets.member(@path_table, destination_hash)
  end

  @doc """
  Returns the number of hops to the specified destination,
  or `PATHFINDER_M` (128) if the number of hops is unknown.
  """
  @spec hops_to(binary()) :: non_neg_integer()
  def hops_to(destination_hash) do
    case :ets.lookup(@path_table, destination_hash) do
      [{^destination_hash, entry}] -> entry.hops
      [] -> @pathfinder_m
    end
  end

  @doc """
  Returns the destination hash for the next hop to the specified
  destination, or nil if the next hop is unknown.
  """
  @spec next_hop(binary()) :: binary() | nil
  def next_hop(destination_hash) do
    case :ets.lookup(@path_table, destination_hash) do
      [{^destination_hash, entry}] -> entry.next_hop
      [] -> nil
    end
  end

  @doc """
  Returns the interface for the next hop to the specified
  destination, or nil if the interface is unknown.
  """
  @spec next_hop_interface(binary()) :: map() | nil
  def next_hop_interface(destination_hash) do
    case :ets.lookup(@path_table, destination_hash) do
      [{^destination_hash, entry}] -> entry.interface
      [] -> nil
    end
  end

  @doc "Returns a path entry for the given destination hash, or nil."
  @spec get_path_entry(binary()) :: PathEntry.t() | nil
  def get_path_entry(destination_hash) do
    case :ets.lookup(@path_table, destination_hash) do
      [{^destination_hash, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts or updates a path entry in the path table."
  @spec put_path_entry(binary(), PathEntry.t()) :: true
  def put_path_entry(destination_hash, %PathEntry{} = entry) do
    :ets.insert(@path_table, {destination_hash, entry})
  end

  @doc """
  Expires a path by setting its timestamp to 0.
  Returns true if the path existed, false otherwise.
  """
  @spec expire_path(binary()) :: boolean()
  def expire_path(destination_hash) do
    case :ets.lookup(@path_table, destination_hash) do
      [{^destination_hash, entry}] ->
        :ets.insert(@path_table, {destination_hash, %{entry | timestamp: 0}})
        true

      [] ->
        false
    end
  end

  # ── Path State Management ────────────────────────────────────────────

  @doc "Marks a path as unresponsive. Returns true if path exists."
  @spec mark_path_unresponsive(binary()) :: boolean()
  def mark_path_unresponsive(destination_hash) do
    if has_path(destination_hash) do
      :ets.insert(@path_states_table, {destination_hash, @state_unresponsive})
      true
    else
      false
    end
  end

  @doc "Marks a path as responsive. Returns true if path exists."
  @spec mark_path_responsive(binary()) :: boolean()
  def mark_path_responsive(destination_hash) do
    if has_path(destination_hash) do
      :ets.insert(@path_states_table, {destination_hash, @state_responsive})
      true
    else
      false
    end
  end

  @doc "Resets a path state to unknown. Returns true if path exists."
  @spec mark_path_unknown_state(binary()) :: boolean()
  def mark_path_unknown_state(destination_hash) do
    if has_path(destination_hash) do
      :ets.insert(@path_states_table, {destination_hash, @state_unknown})
      true
    else
      false
    end
  end

  @doc "Returns true if the path is in unresponsive state."
  @spec path_is_unresponsive(binary()) :: boolean()
  def path_is_unresponsive(destination_hash) do
    case :ets.lookup(@path_states_table, destination_hash) do
      [{^destination_hash, @state_unresponsive}] -> true
      _ -> false
    end
  end

  # ── Packet Hashlist ───────────────────────────────────────────────────

  @doc "Checks if a packet hash is already known (for duplicate detection)."
  @spec packet_hash_known?(binary()) :: boolean()
  def packet_hash_known?(hash) do
    :ets.member(@packet_hashlist_table, hash)
  end

  @doc "Marks a packet hash as known."
  @spec mark_packet_hash(binary()) :: true
  def mark_packet_hash(hash) do
    :ets.insert(@packet_hashlist_table, {hash, true})
  end

  # ── Table Entry Accessors ─────────────────────────────────────────────

  @doc "Returns an announce table entry, or nil."
  @spec get_announce_entry(binary()) :: AnnounceHandler.AnnounceEntry.t() | nil
  def get_announce_entry(destination_hash) do
    case :ets.lookup(@announce_table, destination_hash) do
      [{^destination_hash, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts or updates an announce entry. Delegates to AnnounceHandler."
  @spec put_announce_entry(binary(), AnnounceHandler.AnnounceEntry.t()) :: true
  def put_announce_entry(destination_hash, entry) do
    AnnounceHandler.put_announce_entry(destination_hash, entry)
  end

  @doc "Deletes an announce entry. Delegates to AnnounceHandler."
  @spec delete_announce_entry(binary()) :: true
  def delete_announce_entry(destination_hash) do
    AnnounceHandler.delete_announce_entry(destination_hash)
  end

  @doc "Returns a held announces table entry, or nil."
  @spec get_held_announce(binary()) :: map() | nil
  def get_held_announce(destination_hash) do
    case :ets.lookup(@held_announces_table, destination_hash) do
      [{^destination_hash, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts a held announce entry."
  @spec put_held_announce(binary(), map()) :: true
  def put_held_announce(destination_hash, entry) do
    :ets.insert(@held_announces_table, {destination_hash, entry})
  end

  @doc "Deletes and returns a held announce entry, or nil."
  @spec pop_held_announce(binary()) :: map() | nil
  def pop_held_announce(destination_hash) do
    case :ets.lookup(@held_announces_table, destination_hash) do
      [{^destination_hash, entry}] ->
        :ets.delete(@held_announces_table, destination_hash)
        entry

      [] ->
        nil
    end
  end

  @doc "Returns a reverse table entry, or nil."
  @spec get_reverse_entry(binary()) :: map() | nil
  def get_reverse_entry(packet_hash) do
    case :ets.lookup(@reverse_table, packet_hash) do
      [{^packet_hash, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Returns a link table entry, or nil."
  @spec get_link_entry(binary()) :: map() | nil
  def get_link_entry(link_id) do
    case :ets.lookup(@link_table, link_id) do
      [{^link_id, entry}] -> entry
      [] -> nil
    end
  end

  # ── Path Table Persistence ────────────────────────────────────────────

  @doc "Saves the path table to disk at the given file path."
  @spec save_path_table(String.t()) :: :ok | {:error, term()}
  def save_path_table(file_path) do
    PathManagement.save_path_table(file_path)
  end

  @doc "Loads the path table from disk at the given file path."
  @spec load_path_table(String.t()) :: :ok | {:error, term()}
  def load_path_table(file_path) do
    PathManagement.load_path_table(file_path)
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────

  @impl true
  def init(_opts) do
    create_ets_tables()

    state = %{
      start_time: System.system_time(:second),
      identity: nil,
      owner: nil,
      jobs_running: false,
      traffic_rxb: 0,
      traffic_txb: 0,
      speed_rx: 0,
      speed_tx: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_destination, destination}, _from, state) do
    direction_in = 0x11

    result =
      if destination.direction == direction_in do
        case :ets.lookup(@destinations_table, destination.hash) do
          [{_, _}] ->
            {:error, :already_registered}

          [] ->
            :ets.insert(@destinations_table, {destination.hash, destination})
            :ok
        end
      else
        :ets.insert(@destinations_table, {destination.hash, destination})
        :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:deregister_destination, destination}, _from, state) do
    :ets.delete(@destinations_table, destination.hash)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_interface, interface}, _from, state) do
    :ets.insert(@interfaces_table, {interface.hash, interface})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:deregister_interface, interface}, _from, state) do
    :ets.delete(@interfaces_table, interface.hash)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # ── Private Functions ─────────────────────────────────────────────────

  defp create_ets_tables do
    ets_opts = [:set, :public, :named_table, read_concurrency: true]

    # Core tables
    safe_create_table(@destinations_table, ets_opts)
    safe_create_table(@interfaces_table, ets_opts)
    safe_create_table(@pending_links_table, ets_opts)
    safe_create_table(@active_links_table, ets_opts)
    safe_create_table(@packet_hashlist_table, ets_opts)
    safe_create_table(@receipts_table, ets_opts)

    # Routing tables
    safe_create_table(@announce_table, ets_opts)
    safe_create_table(@path_table, ets_opts)
    safe_create_table(@reverse_table, ets_opts)
    safe_create_table(@link_table, ets_opts)
    safe_create_table(@held_announces_table, ets_opts)
    safe_create_table(@tunnel_table, ets_opts)

    # Rate and state tracking
    safe_create_table(@announce_rate_table, ets_opts)
    safe_create_table(@path_requests_table, ets_opts)
    safe_create_table(@path_states_table, ets_opts)
  end

  defp safe_create_table(name, opts) do
    case :ets.info(name) do
      :undefined -> :ets.new(name, opts)
      _ ->
        :ets.delete_all_objects(name)
        name
    end
  end
end
