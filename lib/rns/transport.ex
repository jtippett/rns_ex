defmodule RNS.Transport do
  @moduledoc """
  The Transport module handles routing, path management, and packet forwarding
  for the Reticulum Network Stack. It maintains routing tables backed by ETS
  for concurrent read access and provides path discovery and management.
  """
  use GenServer
  require Logger

  import Bitwise

  alias RNS.Identity
  alias RNS.Packet
  alias RNS.Transport.AnnounceHandler
  alias RNS.Transport.CacheManagement
  alias RNS.Transport.PathManagement
  alias RNS.Transport.Routing

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
  @discovery_pr_tags_table :rns_discovery_pr_tags
  @discovery_path_requests_table :rns_discovery_path_requests
  @pending_local_path_requests_table :rns_pending_local_path_requests

  # ── Packet/Destination constants (avoid cross-module compile dependency) ─
  @packet_data 0x00
  @packet_announce 0x01
  @packet_linkrequest 0x02
  @packet_proof 0x03

  @header_1 0x00
  @header_2 0x01

  @dest_single 0x00
  @dest_group 0x01
  @dest_plain 0x02
  @dest_link 0x03

  @context_resource 0x01
  @context_resource_req 0x03
  @context_resource_prf 0x05
  @context_cache_request 0x08
  @context_path_response 0x0B
  @context_channel 0x0E
  @context_keepalive 0xFA
  @context_lrproof 0xFF

  @truncated_hashlength 128

  # ── Passthrough contexts (always allowed through filter) ──────────────
  @passthrough_contexts [
    @context_keepalive,
    @context_resource_req,
    @context_resource_prf,
    @context_resource,
    @context_cache_request,
    @context_channel
  ]

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

  # ── LinkEntry struct ──────────────────────────────────────────────────

  defmodule LinkEntry do
    @moduledoc """
    A single entry in the link table, used for routing packets through
    multi-hop links.

    Corresponds to the Python link table 9-element list:
      [timestamp, next_hop, next_hop_interface, remaining_hops,
       received_on_interface, taken_hops, destination_hash, validated, proof_timeout]
    """
    @type t :: %__MODULE__{
            timestamp: number(),
            next_hop: binary(),
            next_hop_interface: map() | nil,
            remaining_hops: non_neg_integer(),
            received_on_interface: map() | nil,
            taken_hops: non_neg_integer(),
            destination_hash: binary(),
            validated: boolean(),
            proof_timeout: number()
          }

    defstruct [
      :timestamp,
      :next_hop,
      :next_hop_interface,
      :remaining_hops,
      :received_on_interface,
      :taken_hops,
      :destination_hash,
      :validated,
      :proof_timeout
    ]
  end

  # ── ReverseEntry struct ───────────────────────────────────────────────

  defmodule ReverseEntry do
    @moduledoc """
    A single entry in the reverse table, used for routing proofs back
    to their origin through the transport network.

    Corresponds to the Python reverse table 3-element list:
      [received_on_interface, outbound_interface, timestamp]
    """
    @type t :: %__MODULE__{
            received_on_interface: map() | nil,
            outbound_interface: map() | nil,
            timestamp: number()
          }

    defstruct [:received_on_interface, :outbound_interface, :timestamp]
  end

  # ── TunnelEntry struct ────────────────────────────────────────────────

  defmodule TunnelEntry do
    @moduledoc """
    A single entry in the tunnel table.

    Corresponds to the Python tunnel table 4-element list:
      [tunnel_id, interface, paths, expires]
    """
    @type t :: %__MODULE__{
            tunnel_id: binary(),
            interface: map() | nil,
            paths: map(),
            expires: number()
          }

    defstruct [:tunnel_id, :interface, :expires, paths: %{}]
  end

  # ── GenServer Client API ──────────────────────────────────────────────

  @doc "Starts the Transport GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Configures Transport with runtime settings from Reticulum.

  Called by Reticulum after config is loaded. Accepts a keyword list with:
  - `:storage_path` — path for persisting path table, hashlist, tunnel table
  - `:cachepath` — path for packet cache
  - `:transport_enabled` — whether transport mode is active
  """
  @spec configure(keyword()) :: :ok
  def configure(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  # ── Destination Registration ──────────────────────────────────────────

  @doc "Registers a destination with the Transport system."
  @spec register_destination(map()) :: :ok | {:error, :already_registered}
  def register_destination(destination) do
    GenServer.call(__MODULE__, {:register_destination, destination})
  end

  @doc "Updates a previously registered destination in the Transport system."
  @spec update_destination(map()) :: :ok
  def update_destination(destination) do
    :ets.insert(@destinations_table, {destination.hash, destination})
    :ok
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

  # ── Announce Handler Registration ──────────────────────────────────────

  @doc """
  Registers an announce handler.

  The handler must be a map/struct with an `aspect_filter` field and a
  `received_announce` function field (3-arity: destination_hash, announced_identity, app_data).
  """
  @spec register_announce_handler(map()) :: :ok
  def register_announce_handler(handler) do
    GenServer.call(__MODULE__, {:register_announce_handler, handler})
  end

  @doc "Deregisters an announce handler."
  @spec deregister_announce_handler(map()) :: :ok
  def deregister_announce_handler(handler) do
    GenServer.call(__MODULE__, {:deregister_announce_handler, handler})
  end

  # ── PubSub Event Subscriptions ─────────────────────────────────────────

  @valid_topics [:announces]

  @doc """
  Subscribes the calling process to Transport events.

  ## Topics

    * `:announces` — receive `{:rns_announce, dest_hash, identity, app_data}` messages

  ## Examples

      RNS.Transport.subscribe(:announces)

      # In a GenServer handle_info:
      def handle_info({:rns_announce, dest_hash, identity, app_data}, state) do
        # handle announce
        {:noreply, state}
      end
  """
  @spec subscribe(atom()) :: :ok | {:error, :invalid_topic}
  def subscribe(topic) when topic in @valid_topics do
    case Registry.register(RNS.Transport.Registry, topic, []) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  def subscribe(_topic), do: {:error, :invalid_topic}

  @doc "Unsubscribes the calling process from a Transport event topic."
  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(topic) do
    Registry.unregister(RNS.Transport.Registry, topic)
    :ok
  end

  @doc """
  Notifies all subscribers of a Transport event.

  Called internally by Transport when events occur.
  """
  @spec notify_subscribers(atom(), tuple()) :: :ok
  def notify_subscribers(:announces, {dest_hash, identity, app_data}) do
    Registry.dispatch(RNS.Transport.Registry, :announces, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:rns_announce, dest_hash, identity, app_data})
      end
    end)

    :ok
  end

  @doc "Returns all registered announce handlers."
  @spec get_announce_handlers() :: [map()]
  def get_announce_handlers do
    GenServer.call(__MODULE__, :get_announce_handlers)
  end

  @doc "Returns the Transport's persistent identity, or nil if not yet configured."
  @spec identity() :: RNS.Identity.t() | nil
  def identity do
    GenServer.call(__MODULE__, :identity)
  end

  @doc "Returns whether a network identity is configured on Transport."
  @spec has_network_identity?() :: boolean()
  def has_network_identity? do
    GenServer.call(__MODULE__, :has_network_identity?)
  end

  @doc "Returns the Transport network identity."
  @spec network_identity() :: term()
  def network_identity do
    GenServer.call(__MODULE__, :network_identity)
  end

  @doc """
  Persists all Transport state (packet hashlist, path table, tunnel table) to disk.

  Defense-in-depth: called from Transport.terminate/2 and also from
  Reticulum.persist_data/0 during normal shutdown.
  """
  @spec persist_data() :: :ok
  def persist_data do
    GenServer.call(__MODULE__, :persist_data)
  end

  # ── Control & Management Destinations ────────────────────────────────

  @doc """
  Creates control and management destinations for the Transport system.

  Called by Reticulum after shared-instance detection, so conditional flags
  are known. Control destinations (path_request, tunnel_synthesize) are
  always created. Management destinations are conditional.

  ## Options

    * `:probe_enabled` — create probe destination (default: false)
    * `:remote_management_enabled` — create remote management destination (default: false)
    * `:publish_blackhole` — create blackhole destination (default: false)
    * `:is_connected_to_shared_instance` — skip mgmt destinations if true (default: false)
    * `:network_identity` — if set, create instance/network destinations
    * `:remote_management_allowed` — list of allowed identity hashes (default: [])
  """
  @spec create_destinations(keyword()) :: :ok
  def create_destinations(opts) do
    GenServer.call(__MODULE__, {:create_destinations, opts})
  end

  @doc "Returns the path_request control destination, or nil."
  @spec path_request_destination() :: RNS.Destination.t() | nil
  def path_request_destination do
    GenServer.call(__MODULE__, :path_request_destination)
  end

  @doc "Returns the tunnel_synthesize control destination, or nil."
  @spec tunnel_synthesize_destination() :: RNS.Destination.t() | nil
  def tunnel_synthesize_destination do
    GenServer.call(__MODULE__, :tunnel_synthesize_destination)
  end

  @doc "Returns the probe destination, or nil if not enabled."
  @spec probe_destination() :: RNS.Destination.t() | nil
  def probe_destination do
    GenServer.call(__MODULE__, :probe_destination)
  end

  @doc "Returns the remote management destination, or nil."
  @spec remote_management_destination() :: RNS.Destination.t() | nil
  def remote_management_destination do
    GenServer.call(__MODULE__, :remote_management_destination)
  end

  @doc "Returns the blackhole destination, or nil."
  @spec blackhole_destination() :: RNS.Destination.t() | nil
  def blackhole_destination do
    GenServer.call(__MODULE__, :blackhole_destination)
  end

  @doc "Returns the instance destination, or nil."
  @spec instance_destination() :: RNS.Destination.t() | nil
  def instance_destination do
    GenServer.call(__MODULE__, :instance_destination)
  end

  @doc "Returns the network destination, or nil."
  @spec network_destination() :: RNS.Destination.t() | nil
  def network_destination do
    GenServer.call(__MODULE__, :network_destination)
  end

  @doc "Returns the hashes of control destinations (path_request, tunnel_synthesize)."
  @spec control_hashes() :: [binary()]
  def control_hashes do
    GenServer.call(__MODULE__, :control_hashes)
  end

  @doc "Returns the hashes of management destinations (probe, remote_mgmt, blackhole, instance, network)."
  @spec mgmt_hashes() :: [binary()]
  def mgmt_hashes do
    GenServer.call(__MODULE__, :mgmt_hashes)
  end

  # ── Link Registration ─────────────────────────────────────────────────

  @doc """
  Registers a link with the Transport system.

  If the link is an initiator, it is added to the pending links table.
  Otherwise it is added to the active links table.
  """
  @spec register_link(map()) :: :ok
  def register_link(link) do
    if Map.get(link, :initiator, false) do
      :ets.insert(@pending_links_table, {link.link_id, link})
    else
      :ets.insert(@active_links_table, {link.link_id, link})
    end

    :ok
  end

  @doc """
  Updates a previously registered link in the Transport system.

  Writes to the active links table (used after receive_packet updates link state).
  """
  @spec update_link(map()) :: :ok
  def update_link(link) do
    :ets.insert(@active_links_table, {link.link_id, link})
    :ok
  end

  @doc """
  Activates a pending link by moving it to the active links table.

  Returns `{:error, :not_pending}` if the link is not in the pending table,
  or `{:error, :invalid_status}` if the link does not have an active status.
  """
  @spec activate_link(map()) :: :ok | {:error, :not_pending | :invalid_status}
  def activate_link(link) do
    case :ets.lookup(@pending_links_table, link.link_id) do
      [{_, _pending}] ->
        if Map.get(link, :status) != RNS.Link.active() do
          {:error, :invalid_status}
        else
          :ets.delete(@pending_links_table, link.link_id)
          :ets.insert(@active_links_table, {link.link_id, link})
          :ok
        end

      [] ->
        {:error, :not_pending}
    end
  end

  @doc """
  Finds a pending link matching the given link request packet's destination hash.
  """
  @spec find_link_for_request_packet(map()) :: map() | nil
  def find_link_for_request_packet(packet) do
    case :ets.lookup(@pending_links_table, packet.destination_hash) do
      [{_, link}] -> link
      [] -> nil
    end
  end

  @doc """
  Finds an active link matching the given destination hash (link_id).
  """
  @spec find_best_link(binary()) :: map() | nil
  def find_best_link(destination_hash) do
    case :ets.lookup(@active_links_table, destination_hash) do
      [{_, link}] -> link
      [] -> nil
    end
  end

  @doc "Returns all pending links."
  @spec get_pending_links() :: [map()]
  def get_pending_links do
    :ets.tab2list(@pending_links_table) |> Enum.map(fn {_id, link} -> link end)
  end

  @doc "Returns all active links."
  @spec get_active_links() :: [map()]
  def get_active_links do
    :ets.tab2list(@active_links_table) |> Enum.map(fn {_id, link} -> link end)
  end

  @doc "Removes a pending link by link_id."
  @spec remove_pending_link(binary()) :: true
  def remove_pending_link(link_id) do
    :ets.delete(@pending_links_table, link_id)
  end

  @doc "Removes an active link by link_id."
  @spec remove_active_link(binary()) :: true
  def remove_active_link(link_id) do
    :ets.delete(@active_links_table, link_id)
  end

  # ── Path Request ──────────────────────────────────────────────────────

  @doc """
  Requests a path to the specified destination hash.

  Broadcasts a path request packet to all registered interfaces.
  This is asynchronous — the path may not be available immediately.
  """
  @spec request_path(binary(), map() | nil, keyword()) :: :ok
  def request_path(destination_hash, on_interface \\ nil, opts \\ []) do
    GenServer.cast(__MODULE__, {:request_path, destination_hash, on_interface, opts})
  end

  @doc "Sets the owner (Reticulum) pid for callbacks."
  @spec set_owner(pid()) :: :ok
  def set_owner(pid) do
    GenServer.call(__MODULE__, {:set_owner, pid})
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

  # ── Local Client Helpers ─────────────────────────────────────────────

  @doc "Returns true if the packet was received from a local client interface."
  @spec from_local_client?(map()) :: boolean()
  def from_local_client?(packet) do
    case Map.get(packet, :receiving_interface) do
      nil -> false
      iface -> local_client_interface?(iface)
    end
  end

  @doc "Returns true if the interface is a local shared instance client."
  @spec local_client_interface?(map()) :: boolean()
  def local_client_interface?(interface) do
    case Map.get(interface, :parent_interface) do
      nil -> false
      parent -> Map.get(parent, :is_local_shared_instance, false) == true
    end
  end

  # ── Stats Accessors (for Reticulum stats functions) ──────────────────

  @doc "Returns total received bytes."
  @spec traffic_rxb() :: non_neg_integer()
  def traffic_rxb, do: GenServer.call(__MODULE__, :traffic_rxb)

  @doc "Returns total transmitted bytes."
  @spec traffic_txb() :: non_neg_integer()
  def traffic_txb, do: GenServer.call(__MODULE__, :traffic_txb)

  @doc "Returns the Transport start time."
  @spec start_time() :: non_neg_integer()
  def start_time, do: GenServer.call(__MODULE__, :start_time)

  @doc "Returns the Transport identity hash, or nil."
  @spec identity_hash() :: binary() | nil
  def identity_hash do
    case GenServer.call(__MODULE__, :identity) do
      nil -> nil
      id -> id.hash
    end
  end

  @doc "Returns the number of entries in the link table."
  @spec link_table_size() :: non_neg_integer()
  def link_table_size, do: :ets.info(@link_table, :size)

  @doc "Returns all path table entries as {hash, entry} tuples."
  @spec get_all_path_entries() :: [{binary(), PathEntry.t()}]
  def get_all_path_entries, do: :ets.tab2list(@path_table)

  @doc "Returns all announce rate table entries."
  @spec get_all_rate_entries() :: [{binary(), map()}]
  def get_all_rate_entries, do: :ets.tab2list(@announce_rate_table)

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

  # ── Reverse Table Operations ──────────────────────────────────────────

  @doc "Returns a reverse table entry, or nil."
  @spec get_reverse_entry(binary()) :: ReverseEntry.t() | nil
  def get_reverse_entry(packet_hash) do
    case :ets.lookup(@reverse_table, packet_hash) do
      [{^packet_hash, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts or updates a reverse table entry."
  @spec put_reverse_entry(binary(), ReverseEntry.t()) :: true
  def put_reverse_entry(hash, %ReverseEntry{} = entry) do
    :ets.insert(@reverse_table, {hash, entry})
  end

  @doc "Deletes a reverse table entry."
  @spec delete_reverse_entry(binary()) :: true
  def delete_reverse_entry(hash) do
    :ets.delete(@reverse_table, hash)
  end

  @doc "Deletes and returns a reverse table entry, or nil."
  @spec pop_reverse_entry(binary()) :: ReverseEntry.t() | nil
  def pop_reverse_entry(hash) do
    case :ets.lookup(@reverse_table, hash) do
      [{^hash, entry}] ->
        :ets.delete(@reverse_table, hash)
        entry

      [] ->
        nil
    end
  end

  # ── Link Table Operations ─────────────────────────────────────────────

  @doc "Returns a link table entry, or nil."
  @spec get_link_entry(binary()) :: LinkEntry.t() | nil
  def get_link_entry(link_id) do
    case :ets.lookup(@link_table, link_id) do
      [{^link_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts or updates a link table entry."
  @spec put_link_entry(binary(), LinkEntry.t()) :: true
  def put_link_entry(link_id, %LinkEntry{} = entry) do
    :ets.insert(@link_table, {link_id, entry})
  end

  @doc "Deletes a link table entry."
  @spec delete_link_entry(binary()) :: true
  def delete_link_entry(link_id) do
    :ets.delete(@link_table, link_id)
  end

  # ── Tunnel Table Operations ───────────────────────────────────────────

  @doc "Returns a tunnel table entry, or nil."
  @spec get_tunnel_entry(binary()) :: TunnelEntry.t() | nil
  def get_tunnel_entry(tunnel_id) do
    case :ets.lookup(@tunnel_table, tunnel_id) do
      [{^tunnel_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts or updates a tunnel table entry."
  @spec put_tunnel_entry(binary(), TunnelEntry.t()) :: true
  def put_tunnel_entry(tunnel_id, %TunnelEntry{} = entry) do
    :ets.insert(@tunnel_table, {tunnel_id, entry})
  end

  @doc "Deletes a tunnel table entry."
  @spec delete_tunnel_entry(binary()) :: true
  def delete_tunnel_entry(tunnel_id) do
    :ets.delete(@tunnel_table, tunnel_id)
  end

  @doc "Returns all tunnel entries."
  @spec get_all_tunnels() :: [{binary(), TunnelEntry.t()}]
  def get_all_tunnels do
    :ets.tab2list(@tunnel_table)
  end

  # ── Receipt Management ────────────────────────────────────────────────

  @doc "Registers a packet receipt for proof tracking."
  @spec register_receipt(map()) :: true
  def register_receipt(receipt) do
    :ets.insert(@receipts_table, {receipt.hash, receipt})
  end

  @doc "Returns a receipt by hash, or nil."
  @spec get_receipt(binary()) :: map() | nil
  def get_receipt(hash) do
    case :ets.lookup(@receipts_table, hash) do
      [{^hash, receipt}] -> receipt
      [] -> nil
    end
  end

  @doc "Removes a receipt by hash."
  @spec remove_receipt(binary()) :: true
  def remove_receipt(hash) do
    :ets.delete(@receipts_table, hash)
  end

  @doc "Returns all receipts."
  @spec get_all_receipts() :: [map()]
  def get_all_receipts do
    :ets.tab2list(@receipts_table) |> Enum.map(fn {_h, r} -> r end)
  end

  @doc "Returns the count of active receipts."
  @spec receipt_count() :: non_neg_integer()
  def receipt_count do
    :ets.info(@receipts_table, :size)
  end

  # ── Path Request Tracking ─────────────────────────────────────────────

  @doc "Records the timestamp of a path request for the given destination."
  @spec record_path_request(binary()) :: true
  def record_path_request(destination_hash) do
    :ets.insert(@path_requests_table, {destination_hash, System.system_time(:second)})
  end

  @doc "Returns the timestamp of the last path request, or 0."
  @spec last_path_request(binary()) :: non_neg_integer()
  def last_path_request(destination_hash) do
    case :ets.lookup(@path_requests_table, destination_hash) do
      [{^destination_hash, timestamp}] -> timestamp
      [] -> 0
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

  # ── Caching and Persistence ────────────────────────────────────────────

  @doc "Determines whether a packet should be cached."
  @spec should_cache(map()) :: boolean()
  defdelegate should_cache(packet), to: CacheManagement

  @doc "Caches a packet to disk storage."
  @spec cache(map(), keyword()) :: :ok | {:error, term()}
  def cache(packet, opts \\ []), do: CacheManagement.cache(packet, opts)

  @doc "Retrieves a cached packet from disk."
  @spec get_cached_packet(binary(), keyword()) :: map() | nil
  def get_cached_packet(packet_hash, opts \\ []),
    do: CacheManagement.get_cached_packet(packet_hash, opts)

  @doc "Handles a cache request packet."
  @spec cache_request_packet(map()) :: boolean()
  defdelegate cache_request_packet(packet), to: CacheManagement

  @doc "Requests a cached packet by hash."
  @spec cache_request(binary(), map()) :: :ok
  defdelegate cache_request(packet_hash, destination), to: CacheManagement

  @doc "Cleans the packet cache."
  @spec clean_cache(String.t()) :: :ok
  defdelegate clean_cache(cachepath), to: CacheManagement

  @doc "Cleans the announce cache directory."
  @spec clean_announce_cache(String.t()) :: :ok
  defdelegate clean_announce_cache(cachepath), to: CacheManagement

  @doc "Saves the packet hashlist to disk."
  @spec save_packet_hashlist(String.t()) :: :ok | {:error, term()}
  defdelegate save_packet_hashlist(file_path), to: CacheManagement

  @doc "Loads the packet hashlist from disk."
  @spec load_packet_hashlist(String.t()) :: :ok | {:error, term()}
  defdelegate load_packet_hashlist(file_path), to: CacheManagement

  @doc "Saves the tunnel table to disk."
  @spec save_tunnel_table(String.t()) :: :ok | {:error, term()}
  defdelegate save_tunnel_table(file_path), to: CacheManagement

  @doc "Loads the tunnel table from disk."
  @spec load_tunnel_table(String.t()) :: :ok | {:error, term()}
  defdelegate load_tunnel_table(file_path), to: CacheManagement

  @doc "Persists all transport data to disk."
  @spec persist_data(String.t()) :: :ok
  defdelegate persist_data(storage_path), to: CacheManagement

  # ── Packet Filter ─────────────────────────────────────────────────────

  @doc """
  Determines whether an inbound packet should be accepted for processing.

  Implements the packet_filter logic from Python Transport.py:
  - Allows packets from shared instance connections
  - Filters packets intended for other transport instances
  - Allows passthrough contexts (keepalive, resource, cache, channel)
  - Filters PLAIN/GROUP packets with too many hops
  - Rejects duplicate packets (by hash) unless they are SINGLE announces

  ## Options
    * `:transport_identity_hash` - hash of this transport instance's identity
    * `:is_shared_instance` - whether connected to shared instance (default: false)
  """
  @spec packet_filter(map(), keyword()) :: boolean()
  def packet_filter(packet, opts \\ []) do
    transport_identity_hash = opts[:transport_identity_hash]
    is_shared_instance = Keyword.get(opts, :is_shared_instance, false)

    cond do
      # If connected to a shared instance, accept everything
      is_shared_instance ->
        true

      # Filter packets intended for other transport instances
      packet.transport_id != nil and packet.packet_type != @packet_announce and
          packet.transport_id != transport_identity_hash ->
        false

      # Allow passthrough contexts
      packet.context in @passthrough_contexts ->
        true

      # PLAIN destination handling
      packet.destination_type == @dest_plain ->
        if packet.packet_type != @packet_announce do
          packet.hops <= 1
        else
          # PLAIN announces are invalid
          false
        end

      # GROUP destination handling
      packet.destination_type == @dest_group ->
        if packet.packet_type != @packet_announce do
          packet.hops <= 1
        else
          # GROUP announces are invalid
          false
        end

      # Check packet hashlist for duplicates
      not packet_hash_known?(packet.packet_hash) ->
        true

      # Allow SINGLE announces through even if hash is known (for path updates)
      packet.packet_type == @packet_announce and packet.destination_type == @dest_single ->
        true

      # Default: drop duplicate
      true ->
        false
    end
  end

  # ── Transmit ──────────────────────────────────────────────────────────

  @doc """
  Transmits raw packet data on the specified interface.

  Handles IFAC (Interface Access Code) masking if the interface has
  an `ifac_identity` configured. Otherwise sends the raw data directly.

  The interface must implement a `process_outgoing/1` function (or be a
  map with a `:process_outgoing` callback function).
  """
  @spec transmit(map(), binary()) :: :ok | {:error, term()}
  def transmit(interface, raw) do
    if Map.get(interface, :ifac_identity) != nil do
      transmit_with_ifac(interface, raw)
    else
      call_process_outgoing(interface, raw)
    end
  rescue
    e ->
      Logger.error("Error while transmitting on #{inspect(interface)}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp transmit_with_ifac(interface, raw) do
    ifac_size = interface.ifac_size
    ifac_identity = interface.ifac_identity

    # Calculate packet access code
    signature = Identity.sign(ifac_identity, raw)
    ifac_start = byte_size(signature) - ifac_size
    <<_::binary-size(ifac_start), ifac::binary-size(ifac_size)>> = signature

    # Generate mask using HKDF
    mask =
      RNS.Cryptography.HKDF.derive_key(
        ifac,
        byte_size(raw) + ifac_size,
        interface.ifac_key,
        nil
      )

    # Set IFAC flag in first header byte and build new payload
    <<first_byte, second_byte, rest::binary>> = raw
    new_header = <<first_byte ||| 0x80, second_byte>>
    new_raw = new_header <> ifac <> rest

    # Mask payload (preserve IFAC bytes unmasked)
    masked_raw = mask_ifac_payload(new_raw, mask, ifac_size)

    call_process_outgoing(interface, masked_raw)
  end

  defp mask_ifac_payload(payload, mask, ifac_size),
    do: Routing.mask_ifac_payload(payload, mask, ifac_size)

  defp call_process_outgoing(interface, raw) do
    cond do
      is_function(Map.get(interface, :process_outgoing), 1) ->
        interface.process_outgoing.(raw)
        :ok

      is_pid(Map.get(interface, :pid)) ->
        send(interface.pid, {:process_outgoing, raw})
        :ok

      true ->
        Logger.warning("Interface #{inspect(interface)} has no process_outgoing handler")
        {:error, :no_handler}
    end
  end

  # ── Outbound ──────────────────────────────────────────────────────────

  @doc """
  Handles outgoing packet transmission.

  Routes the packet based on the path table:
  - If a path is known with hops > 1, inserts into transport (HEADER_2)
  - If path is known with hops == 1, transmits directly on path interface
  - If no path is known, broadcasts on all outgoing interfaces

  Returns `true` if the packet was sent, `false` otherwise.

  ## Options
    * `:transport_identity` - this transport instance's identity (for HEADER_2)
    * `:is_shared_instance` - whether connected to shared instance
  """
  @spec outbound(map(), keyword()) :: boolean()
  def outbound(packet, opts \\ []) do
    transport_identity = opts[:transport_identity]
    is_shared_instance = Keyword.get(opts, :is_shared_instance, false)

    sent =
      if should_use_path_table?(packet) and has_path(packet.destination_hash) do
        outbound_via_path(packet, transport_identity, is_shared_instance)
      else
        outbound_broadcast(packet)
      end

    # Generate receipt for qualifying packets
    if sent and should_generate_receipt?(packet) do
      receipt = RNS.PacketReceipt.new(packet)
      register_receipt(receipt)
    end

    sent
  end

  defp should_use_path_table?(packet), do: Routing.should_use_path_table?(packet)
  defp should_generate_receipt?(packet), do: Routing.should_generate_receipt?(packet)

  defp outbound_via_path(packet, transport_identity, is_shared_instance) do
    path_entry = get_path_entry(packet.destination_hash)
    outbound_interface = path_entry.interface

    cond do
      # Multi-hop: insert into transport
      path_entry.hops > 1 and packet.header_type == @header_1 ->
        _transport_id_hash =
          if transport_identity, do: transport_identity.hash, else: :crypto.strong_rand_bytes(16)

        new_flags = @header_2 <<< 6 ||| @transport <<< 4 ||| (packet.flags &&& 0x0F)
        next_hop_hash = path_entry.next_hop

        <<_flags::8, hops::8, rest::binary>> = packet.raw

        new_raw = <<new_flags::8, hops::8>> <> next_hop_hash <> rest

        transmit(outbound_interface, new_raw)
        update_path_timestamp(packet.destination_hash)
        true

      # Single hop via shared instance: also needs transport headers
      path_entry.hops == 1 and is_shared_instance and packet.header_type == @header_1 ->
        _transport_id_hash =
          if transport_identity, do: transport_identity.hash, else: :crypto.strong_rand_bytes(16)

        new_flags = @header_2 <<< 6 ||| @transport <<< 4 ||| (packet.flags &&& 0x0F)
        next_hop_hash = path_entry.next_hop

        <<_flags::8, hops::8, rest::binary>> = packet.raw

        new_raw = <<new_flags::8, hops::8>> <> next_hop_hash <> rest

        transmit(outbound_interface, new_raw)
        update_path_timestamp(packet.destination_hash)
        true

      # Direct: transmit directly
      true ->
        transmit(outbound_interface, packet.raw)
        true
    end
  end

  defp outbound_broadcast(packet) do
    interfaces = get_interfaces()
    stored_hash = false

    {sent, _stored} =
      Enum.reduce(interfaces, {false, stored_hash}, fn interface, {sent_acc, hash_stored} ->
        if Map.get(interface, :out, true) and should_transmit_on_interface?(packet, interface) do
          hash_stored =
            if hash_stored do
              hash_stored
            else
              mark_packet_hash(packet.packet_hash)
              true
            end

          transmit(interface, packet.raw)
          {true, hash_stored}
        else
          {sent_acc, hash_stored}
        end
      end)

    sent
  end

  defp should_transmit_on_interface?(packet, interface) do
    cond do
      # Link destination: must match attached interface
      packet.destination_type == @dest_link ->
        Map.get(packet, :attached_interface) == nil or
          Map.get(packet, :attached_interface) == interface

      # Attached interface constraint
      Map.get(packet, :attached_interface) != nil and
          Map.get(packet, :attached_interface) != interface ->
        false

      # Announce packets have special mode-based rules
      packet.packet_type == @packet_announce ->
        should_transmit_announce?(packet, interface)

      true ->
        true
    end
  end

  defp should_transmit_announce?(packet, interface) do
    cond do
      # If packet has attached_interface, allow
      Map.get(packet, :attached_interface) != nil ->
        true

      # Access point mode blocks outgoing announces
      Map.get(interface, :mode) == :mode_access_point ->
        false

      # Roaming mode: only allow local destinations or check from_interface
      Map.get(interface, :mode) == :mode_roaming ->
        local_dest =
          Enum.any?(get_destinations(), fn d -> d.hash == packet.destination_hash end)

        if local_dest do
          true
        else
          from_interface = next_hop_interface(packet.destination_hash)

          from_interface != nil and Map.has_key?(from_interface, :mode) and
            from_interface.mode not in [:mode_roaming, :mode_boundary]
        end

      # Boundary mode: similar to roaming
      Map.get(interface, :mode) == :mode_boundary ->
        local_dest =
          Enum.any?(get_destinations(), fn d -> d.hash == packet.destination_hash end)

        if local_dest do
          true
        else
          from_interface = next_hop_interface(packet.destination_hash)

          from_interface != nil and Map.has_key?(from_interface, :mode) and
            from_interface.mode != :mode_roaming
        end

      # Default mode: allow (with potential rate limiting for non-local)
      true ->
        true
    end
  end

  defp update_path_timestamp(destination_hash) do
    case get_path_entry(destination_hash) do
      nil ->
        :ok

      entry ->
        put_path_entry(destination_hash, %{entry | timestamp: System.system_time(:second)})
    end
  end

  # ── Inbound ───────────────────────────────────────────────────────────

  @doc """
  Processes an inbound raw packet from an interface.

  Handles:
  - IFAC (Interface Access Code) validation
  - Packet unpacking and hop count increment
  - Packet filtering
  - Transport routing (forwarding packets to next hop)
  - Link transport handling
  - Announce processing
  - Local data delivery
  - Proof routing

  ## Options
    * `:transport_identity` - this transport instance's identity
    * `:transport_enabled` - whether this instance has transport enabled
    * `:is_shared_instance` - whether connected to shared instance
  """
  @spec inbound(binary(), map() | nil, keyword()) :: :ok | :dropped
  def inbound(raw, interface, opts \\ []) do
    # Validate minimum packet length
    if byte_size(raw) <= 2 do
      :dropped
    else
      case validate_ifac(raw, interface) do
        {:ok, validated_raw} ->
          process_inbound(validated_raw, interface, opts)

        :drop ->
          :dropped
      end
    end
  end

  defp validate_ifac(raw, interface) do
    has_ifac = Map.get(interface || %{}, :ifac_identity) != nil
    ifac_flag_set = (:binary.at(raw, 0) &&& 0x80) == 0x80

    cond do
      # Interface has IFAC: validate
      has_ifac and ifac_flag_set ->
        ifac_size = interface.ifac_size

        if byte_size(raw) > 2 + ifac_size do
          <<_::binary-size(2), ifac::binary-size(ifac_size), _::binary>> = raw

          # Generate mask
          mask =
            RNS.Cryptography.HKDF.derive_key(
              ifac,
              byte_size(raw),
              interface.ifac_key,
              nil
            )

          # Unmask payload
          unmasked = unmask_ifac_payload(raw, mask, ifac_size)

          # Unset IFAC flag and reassemble
          <<first_byte, second_byte, _ifac::binary-size(ifac_size), rest::binary>> = unmasked
          new_raw = <<first_byte &&& 0x7F, second_byte>> <> rest

          # Calculate expected IFAC
          expected_signature = Identity.sign(interface.ifac_identity, new_raw)

          expected_ifac_start = byte_size(expected_signature) - ifac_size

          <<_::binary-size(expected_ifac_start), expected_ifac::binary-size(ifac_size)>> =
            expected_signature

          if ifac == expected_ifac, do: {:ok, new_raw}, else: :drop
        else
          :drop
        end

      # Interface has IFAC but flag not set: drop
      has_ifac and not ifac_flag_set ->
        :drop

      # No IFAC on interface but flag is set: drop
      not has_ifac and ifac_flag_set ->
        :drop

      # No IFAC, no flag: pass through
      true ->
        {:ok, raw}
    end
  end

  defp unmask_ifac_payload(payload, mask, ifac_size),
    do: Routing.unmask_ifac_payload(payload, mask, ifac_size)

  defp process_inbound(raw, interface, opts) do
    transport_identity = opts[:transport_identity]
    _transport_enabled = Keyword.get(opts, :transport_enabled, false)
    transport_identity_hash = if transport_identity, do: transport_identity.hash, else: nil

    # Unpack the packet
    packet = Packet.new(nil, raw)

    case Packet.unpack(packet) do
      %Packet{} = packet ->
        # Set receiving interface and increment hop count
        packet = %{packet | receiving_interface: interface, hops: packet.hops + 1}

        # Apply packet filter
        filter_opts = [
          transport_identity_hash: transport_identity_hash,
          is_shared_instance: Keyword.get(opts, :is_shared_instance, false)
        ]

        if packet_filter(packet, filter_opts) do
          # Determine whether to remember packet hash
          remember_hash =
            packet.destination_hash not in link_table_keys() and
              not (packet.packet_type == @packet_proof and packet.context == @context_lrproof)

          if remember_hash, do: mark_packet_hash(packet.packet_hash)

          # Route the packet
          internal_inbound(packet, opts)
        else
          :dropped
        end

      false ->
        :dropped
    end
  end

  defp link_table_keys do
    :ets.tab2list(@link_table) |> Enum.map(fn {key, _} -> key end)
  end

  # ── Internal Inbound Processing ───────────────────────────────────────

  @doc """
  Processes a validated, unpacked inbound packet.

  Handles transport routing, announce processing, link requests,
  data delivery, and proof routing.

  ## Options
    * `:transport_identity` - this transport instance's identity
    * `:transport_enabled` - whether transport is enabled
  """
  @spec internal_inbound(map(), keyword()) :: :ok
  def internal_inbound(packet, opts \\ []) do
    transport_identity = opts[:transport_identity]
    transport_enabled = Keyword.get(opts, :transport_enabled, false)
    transport_identity_hash = if transport_identity, do: transport_identity.hash, else: nil

    # Transport routing for packets addressed to us as transport node
    if transport_enabled do
      handle_transport_routing(packet, transport_identity_hash)
      handle_link_transport(packet)
    end

    # Process by packet type
    case packet.packet_type do
      @packet_announce ->
        handle_inbound_announce(packet, opts)

      @packet_linkrequest ->
        handle_inbound_link_request(packet, transport_identity_hash)

      @packet_data ->
        handle_inbound_data(packet)

      @packet_proof ->
        handle_inbound_proof(packet, opts)

      _ ->
        :ok
    end

    :ok
  end

  # ── Transport Routing (forwarding through transport network) ──────────

  defp handle_transport_routing(packet, transport_identity_hash) do
    # Only process non-announce packets that are addressed to us as transport
    if packet.transport_id != nil and packet.packet_type != @packet_announce and
         packet.transport_id == transport_identity_hash do
      forward(packet, transport_identity_hash)
    end
  end

  @doc """
  Forwards a packet through the transport network to its next hop.

  Looks up the destination in the path table and either:
  - Forwards with updated hop count (remaining_hops > 1)
  - Strips transport headers (remaining_hops == 1)
  - Passes through directly (remaining_hops == 0)

  Also records link table entries for LINKREQUEST packets and
  reverse table entries for other packet types (for proof routing).
  """
  @spec forward(map(), binary() | nil) :: :ok | :no_path
  def forward(packet, _transport_identity_hash \\ nil) do
    case get_path_entry(packet.destination_hash) do
      nil ->
        Logger.debug(
          "Got packet in transport, but no path to #{Base.encode16(packet.destination_hash)}. Dropping."
        )

        :no_path

      path_entry ->
        next_hop_addr = path_entry.next_hop
        remaining_hops = path_entry.hops
        outbound_interface = path_entry.interface
        hash_len = div(@truncated_hashlength, 8)

        <<flags::8, _hops::8, rest::binary>> = packet.raw

        new_raw =
          cond do
            remaining_hops > 1 ->
              # Forward with updated hop count and next hop address
              <<_transport_id::binary-size(hash_len), payload::binary>> = rest
              <<flags::8, packet.hops::8>> <> next_hop_addr <> payload

            remaining_hops == 1 ->
              # Strip transport headers, convert back to HEADER_1
              new_flags = @header_1 <<< 6 ||| @broadcast <<< 4 ||| (packet.flags &&& 0x0F)
              <<_transport_id::binary-size(hash_len), payload::binary>> = rest
              <<new_flags::8, packet.hops::8>> <> payload

            true ->
              # remaining_hops == 0, just update hop count
              <<flags::8, packet.hops::8>> <> rest
          end

        # Record link table entry for link requests, reverse entry for others
        if packet.packet_type == @packet_linkrequest do
          record_link_table_entry(packet, next_hop_addr, outbound_interface, remaining_hops)
        else
          record_reverse_entry(packet, outbound_interface)
        end

        transmit(outbound_interface, new_raw)
        update_path_timestamp(packet.destination_hash)
        :ok
    end
  end

  defp record_link_table_entry(packet, next_hop, outbound_interface, remaining_hops) do
    now = System.system_time(:second)
    # Default proof timeout: current time + establishment timeout per hop * remaining hops
    proof_timeout = now + Packet.timeout_per_hop() * max(1, remaining_hops)

    # Derive link_id from the link request packet data (first 32 bytes of X25519 public key)
    link_id =
      if byte_size(packet.data) >= 32 do
        <<first_32::binary-size(32), _::binary>> = packet.data
        Identity.truncated_hash(first_32)
      else
        packet.destination_hash
      end

    entry = %LinkEntry{
      timestamp: now,
      next_hop: next_hop,
      next_hop_interface: outbound_interface,
      remaining_hops: remaining_hops,
      received_on_interface: packet.receiving_interface,
      taken_hops: packet.hops,
      destination_hash: packet.destination_hash,
      validated: false,
      proof_timeout: proof_timeout
    }

    put_link_entry(link_id, entry)
  end

  defp record_reverse_entry(packet, outbound_interface) do
    truncated_hash = Packet.truncated_hash(packet)

    entry = %ReverseEntry{
      received_on_interface: packet.receiving_interface,
      outbound_interface: outbound_interface,
      timestamp: System.system_time(:second)
    }

    put_reverse_entry(truncated_hash, entry)
  end

  # ── Link Transport Handling ───────────────────────────────────────────

  defp handle_link_transport(packet) do
    # Don't handle announces, link requests, or LR proofs through link table
    if packet.packet_type != @packet_announce and
         packet.packet_type != @packet_linkrequest and
         packet.context != @context_lrproof do
      case get_link_entry(packet.destination_hash) do
        nil ->
          :ok

        link_entry ->
          outbound_interface = determine_link_outbound_interface(packet, link_entry)

          if outbound_interface != nil do
            mark_packet_hash(packet.packet_hash)

            <<flags::8, _hops::8, rest::binary>> = packet.raw
            new_raw = <<flags::8, packet.hops::8>> <> rest

            transmit(outbound_interface, new_raw)

            # Update link table timestamp
            put_link_entry(packet.destination_hash, %{
              link_entry
              | timestamp: System.system_time(:second)
            })
          end
      end
    end
  end

  defp determine_link_outbound_interface(packet, link_entry),
    do: Routing.determine_link_outbound_interface(packet, link_entry)

  # ── Announce Handling ─────────────────────────────────────────────────

  defp handle_inbound_announce(packet, opts) do
    transport_enabled = Keyword.get(opts, :transport_enabled, false)

    # Validate announce signature
    if Identity.validate_announce(packet) do
      received_from =
        if packet.transport_id != nil do
          # Track rebroadcasts from other transport nodes
          if transport_enabled do
            case get_announce_entry(packet.destination_hash) do
              nil ->
                :ok

              entry ->
                AnnounceHandler.handle_rebroadcast_tracking(
                  packet.destination_hash,
                  packet.hops,
                  entry
                )
            end
          end

          packet.transport_id
        else
          packet.destination_hash
        end

      random_blob = AnnounceHandler.extract_random_blob(packet)

      if AnnounceHandler.should_add_path?(packet.destination_hash, packet, random_blob) do
        # Check rate limiting
        interface = packet.receiving_interface || %{}

        {rate_blocked, _rate_entry} =
          if packet.context != @context_path_response do
            AnnounceHandler.check_announce_rate(packet.destination_hash, interface)
          else
            {false, nil}
          end

        now = System.system_time(:second)
        expires = AnnounceHandler.calculate_path_expiry(interface)

        # Update random blobs
        existing_blobs =
          case get_path_entry(packet.destination_hash) do
            nil -> []
            pe -> pe.random_blobs || []
          end

        random_blobs = AnnounceHandler.update_random_blobs(existing_blobs, random_blob)

        # Insert into announce table for retransmission (if transport enabled and not rate blocked)
        if transport_enabled and packet.context != @context_path_response and not rate_blocked do
          retransmit_timeout = now + :rand.uniform() * @pathfinder_rw

          announce_entry = %AnnounceHandler.AnnounceEntry{
            timestamp: now,
            retransmit_timeout: retransmit_timeout,
            retries: 0,
            received_from: received_from,
            hops: packet.hops,
            packet: packet,
            local_rebroadcasts: 0,
            block_rebroadcasts: false,
            attached_interface: nil
          }

          put_announce_entry(packet.destination_hash, announce_entry)
        end

        # Update path table
        path_entry = %PathEntry{
          timestamp: now,
          next_hop: received_from,
          hops: packet.hops,
          expires: expires,
          random_blobs: random_blobs,
          interface: packet.receiving_interface,
          packet_hash: packet.packet_hash
        }

        put_path_entry(packet.destination_hash, path_entry)

        # Call externally registered announce handler callbacks
        call_announce_handlers(packet)
      end
    end

    :ok
  end

  defp call_announce_handlers(packet) do
    handlers = get_announce_handlers()
    announce_identity = Identity.recall(packet.destination_hash)
    app_data = Identity.recall_app_data(packet.destination_hash)
    is_path_response = packet.context == @context_path_response

    # Call registered callback handlers
    if handlers != [] do
      Enum.each(handlers, fn handler ->
        try do
          execute_callback =
            cond do
              # nil aspect_filter means match all announces
              handler.aspect_filter == nil ->
                true

              announce_identity != nil ->
                handler_expected_hash =
                  RNS.Destination.hash_from_name_and_identity(
                    handler.aspect_filter,
                    announce_identity
                  )

                packet.destination_hash == handler_expected_hash

              true ->
                false
            end

          # Path responses are only delivered to handlers that opt in
          execute_callback =
            if execute_callback and is_path_response do
              Map.get(handler, :receive_path_responses, false) == true
            else
              execute_callback
            end

          if execute_callback do
            callback = handler.received_announce
            arity = :erlang.fun_info(callback)[:arity]

            case arity do
              3 ->
                Task.Supervisor.start_child(RNS.TaskSupervisor, fn ->
                  callback.(packet.destination_hash, announce_identity, app_data)
                end)

              4 ->
                Task.Supervisor.start_child(RNS.TaskSupervisor, fn ->
                  callback.(
                    packet.destination_hash,
                    announce_identity,
                    app_data,
                    packet.packet_hash
                  )
                end)

              5 ->
                Task.Supervisor.start_child(RNS.TaskSupervisor, fn ->
                  callback.(
                    packet.destination_hash,
                    announce_identity,
                    app_data,
                    packet.packet_hash,
                    is_path_response
                  )
                end)

              _ ->
                Logger.error("Invalid arity #{arity} for announce handler callback")
            end
          end
        rescue
          e ->
            Logger.error(
              "Error while processing external announce callback: #{inspect(e)}"
            )
        end
      end)
    end

    # Notify pub/sub subscribers
    notify_subscribers(:announces, {packet.destination_hash, announce_identity, app_data})
  end

  # ── Link Request Handling ─────────────────────────────────────────────

  defp handle_inbound_link_request(packet, transport_identity_hash) do
    # Only process if addressed to us (or no transport_id)
    if packet.transport_id == nil or packet.transport_id == transport_identity_hash do
      destinations = get_destinations()

      Enum.each(destinations, fn destination ->
        if destination.hash == packet.destination_hash and
             destination.type == packet.destination_type do
          # Deliver to destination via module function
          {_success, updated_dest} = RNS.Destination.receive_packet(destination, packet)
          update_destination(updated_dest)
        end
      end)
    end

    :ok
  end

  # ── Data Packet Handling ──────────────────────────────────────────────

  defp handle_inbound_data(packet) do
    if packet.destination_type == @dest_link do
      # Route to active link
      case find_best_link(packet.destination_hash) do
        nil ->
          :ok

        link ->
          if Map.get(link, :attached_interface) == packet.receiving_interface do
            case RNS.Link.receive_packet(link, packet) do
              {:ok, updated_link, actions} ->
                update_link(updated_link)
                execute_link_actions(actions)

              {:ignored, updated_link} ->
                update_link(updated_link)
            end
          end
      end
    else
      # Route to local destination
      destinations = get_destinations()

      Enum.each(destinations, fn destination ->
        if destination.hash == packet.destination_hash and
             destination.type == packet.destination_type do
          {delivered, updated_dest} = RNS.Destination.receive_packet(destination, packet)
          update_destination(updated_dest)

          if delivered do
            handle_proof_strategy(packet, updated_dest)
          end
        end
      end)
    end

    :ok
  end

  defp execute_link_actions(actions) do
    Enum.each(actions, fn
      {:callback, fun, args} when is_function(fun) ->
        try do
          apply(fun, args)
        rescue
          e ->
            require Logger
            Logger.error("Error executing link callback: #{inspect(e)}")
        end

      {:send_proof, _proof_data} ->
        # Proof sending is handled by the link's own packet infrastructure
        :ok

      {:send_keepalive_response, _data} ->
        # Keepalive responses are handled by the link's own packet infrastructure
        :ok

      {:channel_receive, _plaintext} ->
        # Channel data delivery is handled within the link
        :ok

      _ ->
        :ok
    end)
  end

  defp handle_proof_strategy(packet, destination) do
    prove_all = 0x23
    prove_app = 0x22

    cond do
      Map.get(destination, :proof_strategy) == prove_all ->
        RNS.Packet.prove(packet)

      Map.get(destination, :proof_strategy) == prove_app ->
        callback = get_in(destination, [:callbacks, :proof_requested])

        if is_function(callback, 1) do
          try do
            if callback.(packet), do: RNS.Packet.prove(packet)
          rescue
            e ->
              Logger.error("Error in proof request callback: #{Exception.message(e)}")
          end
        end

      true ->
        :ok
    end
  end

  # ── Proof Handling ────────────────────────────────────────────────────

  defp handle_inbound_proof(packet, opts) do
    transport_enabled = Keyword.get(opts, :transport_enabled, false)

    if packet.context == @context_lrproof do
      handle_link_request_proof(packet, opts)
    else
      # Route proofs through reverse table
      if transport_enabled do
        case pop_reverse_entry(packet.destination_hash) do
          nil ->
            :ok

          reverse_entry ->
            if packet.receiving_interface == reverse_entry.outbound_interface do
              <<flags::8, _hops::8, rest::binary>> = packet.raw
              new_raw = <<flags::8, packet.hops::8>> <> rest

              transmit(reverse_entry.received_on_interface, new_raw)
            end
        end
      end

      # Match with receipts
      match_receipt(packet)
    end

    :ok
  end

  defp handle_link_request_proof(packet, opts) do
    transport_enabled = Keyword.get(opts, :transport_enabled, false)

    if transport_enabled do
      case get_link_entry(packet.destination_hash) do
        nil ->
          :ok

        link_entry ->
          if packet.hops == link_entry.remaining_hops and
               packet.receiving_interface == link_entry.next_hop_interface do
            # Validate and forward the link proof
            <<flags::8, _hops::8, rest::binary>> = packet.raw
            new_raw = <<flags::8, packet.hops::8>> <> rest

            # Mark link as validated
            put_link_entry(packet.destination_hash, %{link_entry | validated: true})
            transmit(link_entry.received_on_interface, new_raw)
          end
      end
    end

    # Check if this is for a local pending link
    case find_link_for_request_packet(packet) do
      nil ->
        :ok

      link ->
        expected_hops =
          get_in(link, [Access.key(:stats), Access.key(:expected_hops)]) || @pathfinder_m

        if packet.hops == expected_hops or expected_hops == @pathfinder_m do
          mark_packet_hash(packet.packet_hash)

          case RNS.Link.validate_proof(link, packet) do
            {:ok, updated_link} ->
              update_link(updated_link)

            {:error, _reason} ->
              :ok
          end
        end
    end

    :ok
  end

  defp match_receipt(packet) do
    # Determine proof hash for explicit proofs
    hashlength_bytes = div(256, 8)
    siglength_bytes = div(512, 8)
    _expl_length = hashlength_bytes + siglength_bytes

    proof_hash =
      case packet.data do
        <<hash::binary-size(hashlength_bytes), _::binary-size(siglength_bytes)>> -> hash
        _ -> nil
      end

    receipts = get_all_receipts()

    Enum.each(receipts, fn receipt ->
      validated =
        if proof_hash != nil do
          # Explicit proof: only check if hash matches
          receipt.hash == proof_hash
        else
          # Implicit proof: check every receipt
          true
        end

      if validated do
        if RNS.PacketReceipt.validate_proof_packet(receipt, packet) do
          remove_receipt(receipt.hash)
        end
      end
    end)
  end

  # ── Periodic Jobs ─────────────────────────────────────────────────────

  @doc """
  Starts the periodic job scheduler. Called after transport is fully initialized.
  """
  @spec start_jobs() :: :ok
  def start_jobs do
    GenServer.cast(__MODULE__, :start_jobs)
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────

  @impl true
  def init(opts) do
    create_ets_tables()

    now = System.system_time(:second)

    state = %{
      start_time: now,
      identity: nil,
      owner: nil,
      jobs_running: false,
      transport_enabled: Keyword.get(opts, :transport_enabled, false),
      storage_path: Keyword.get(opts, :storage_path, nil),
      cachepath: Keyword.get(opts, :cachepath, nil),
      traffic_rxb: 0,
      traffic_txb: 0,
      speed_rx: 0,
      speed_tx: 0,
      links_last_checked: 0,
      receipts_last_checked: 0,
      announces_last_checked: 0,
      tables_last_culled: 0,
      cache_last_cleaned: now + 60,
      jobs_started: false,
      announce_handlers: [],
      network_identity: nil,
      blackholed_identities: %{},
      # Control & management destinations
      path_request_destination: nil,
      tunnel_synthesize_destination: nil,
      probe_destination: nil,
      remote_management_destination: nil,
      blackhole_destination: nil,
      instance_destination: nil,
      network_destination: nil,
      control_hashes: [],
      mgmt_hashes: [],
      local_client_interfaces: []
    }

    update_transport_config(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, state) do
    storage_path = Keyword.get(opts, :storage_path, state.storage_path)
    cachepath = Keyword.get(opts, :cachepath, state.cachepath)
    transport_enabled = Keyword.get(opts, :transport_enabled, state.transport_enabled)

    # Create or load the persistent transport identity
    identity =
      if storage_path do
        load_or_create_identity(storage_path)
      else
        state.identity
      end

    state = %{
      state
      | storage_path: storage_path,
        cachepath: cachepath,
        transport_enabled: transport_enabled,
        identity: identity
    }

    # Load persisted data from disk if storage path is available
    if storage_path do
      load_persisted_data(storage_path)
    end

    update_transport_config(state)
    {:reply, :ok, state}
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
  def handle_call({:register_announce_handler, handler}, _from, state) do
    handlers = [handler | state.announce_handlers]
    {:reply, :ok, %{state | announce_handlers: handlers}}
  end

  @impl true
  def handle_call({:deregister_announce_handler, handler}, _from, state) do
    handlers = Enum.reject(state.announce_handlers, &(&1 == handler))
    {:reply, :ok, %{state | announce_handlers: handlers}}
  end

  @impl true
  def handle_call(:get_announce_handlers, _from, state) do
    {:reply, state.announce_handlers, state}
  end

  @impl true
  def handle_call(:identity, _from, state) do
    {:reply, state.identity, state}
  end

  @impl true
  def handle_call(:has_network_identity?, _from, state) do
    {:reply, state.network_identity != nil, state}
  end

  @impl true
  def handle_call(:network_identity, _from, state) do
    {:reply, state.network_identity, state}
  end

  @impl true
  def handle_call(:persist_data, _from, state) do
    if state.storage_path do
      File.mkdir_p(state.storage_path)
      CacheManagement.persist_data(state.storage_path)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:create_destinations, opts}, _from, state) do
    state = do_create_destinations(state, opts)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:path_request_destination, _from, state),
    do: {:reply, state.path_request_destination, state}

  @impl true
  def handle_call(:tunnel_synthesize_destination, _from, state),
    do: {:reply, state.tunnel_synthesize_destination, state}

  @impl true
  def handle_call(:probe_destination, _from, state),
    do: {:reply, state.probe_destination, state}

  @impl true
  def handle_call(:remote_management_destination, _from, state),
    do: {:reply, state.remote_management_destination, state}

  @impl true
  def handle_call(:blackhole_destination, _from, state),
    do: {:reply, state.blackhole_destination, state}

  @impl true
  def handle_call(:instance_destination, _from, state),
    do: {:reply, state.instance_destination, state}

  @impl true
  def handle_call(:network_destination, _from, state),
    do: {:reply, state.network_destination, state}

  @impl true
  def handle_call(:control_hashes, _from, state),
    do: {:reply, state.control_hashes, state}

  @impl true
  def handle_call(:mgmt_hashes, _from, state),
    do: {:reply, state.mgmt_hashes, state}

  @impl true
  def handle_call(:blackholed_identities, _from, state),
    do: {:reply, state.blackholed_identities, state}

  @impl true
  def handle_call(:transport_enabled?, _from, state),
    do: {:reply, state.transport_enabled, state}

  @impl true
  def handle_call(:local_client_interfaces, _from, state),
    do: {:reply, state.local_client_interfaces, state}

  @impl true
  def handle_call({:set_owner, pid}, _from, state),
    do: {:reply, :ok, %{state | owner: pid}}

  @impl true
  def handle_call(:traffic_rxb, _from, state), do: {:reply, state.traffic_rxb, state}

  @impl true
  def handle_call(:traffic_txb, _from, state), do: {:reply, state.traffic_txb, state}

  @impl true
  def handle_call(:start_time, _from, state), do: {:reply, state.start_time, state}


  @impl true
  def handle_cast({:request_path, destination_hash, on_interface, opts}, state) do
    tag = Keyword.get(opts, :tag) || RNS.Identity.random_hash()
    recursive = Keyword.get(opts, :recursive, false)

    path_request_data =
      if state.transport_enabled and state.identity do
        destination_hash <> state.identity.hash <> tag
      else
        destination_hash <> tag
      end

    path_request_dest =
      build_destination(nil, RNS.Destination.plain(), @app_name, ["path", "request"])

    packet =
      RNS.Packet.new(path_request_dest, path_request_data,
        packet_type: @packet_data,
        transport_type: @broadcast,
        header_type: @header_1,
        attached_interface: on_interface
      )

    should_send =
      if on_interface != nil and recursive do
        _announce_cap = Map.get(on_interface, :announce_cap, RNS.Interfaces.Interface.default_announce_cap())
        announce_allowed_at = Map.get(on_interface, :announce_allowed_at, 0)
        announce_queue = Map.get(on_interface, :announce_queue, [])

        cond do
          length(announce_queue) > 0 ->
            Logger.debug("Blocking recursive path request on #{on_interface} due to queued announces")
            false

          System.system_time(:second) < announce_allowed_at ->
            Logger.debug("Blocking recursive path request on #{on_interface} due to active announce cap")
            false

          true ->
            true
        end
      else
        true
      end

    if should_send do
      RNS.Packet.send(packet)
      :ets.insert(@path_requests_table, {destination_hash, System.system_time(:second)})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:start_jobs, state) do
    if state.jobs_started do
      {:noreply, state}
    else
      schedule_job(:jobs_tick, @job_interval)
      {:noreply, %{state | jobs_started: true}}
    end
  end

  @impl true
  def handle_info(:jobs_tick, state) do
    now_ms = System.monotonic_time(:millisecond)
    now = System.system_time(:second)

    state = run_periodic_jobs(state, now, now_ms)

    schedule_job(:jobs_tick, @job_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.storage_path do
      File.mkdir_p(state.storage_path)

      try do
        CacheManagement.persist_data(state.storage_path)
      rescue
        e -> Logger.debug("Transport terminate: could not persist data: #{Exception.message(e)}")
      end
    end

    :ok
  end

  # ── Persisted Data Loading ──────────────────────────────────────────

  defp load_persisted_data(storage_path) do
    CacheManagement.load_packet_hashlist(Path.join(storage_path, "packet_hashlist"))
    PathManagement.load_path_table(Path.join(storage_path, "destination_table"))
    CacheManagement.load_tunnel_table(Path.join(storage_path, "tunnels"))
    :ok
  end

  # Loads an existing transport identity from disk, or creates and persists a new one.
  # Matches Python's Transport.start() identity lifecycle.
  defp load_or_create_identity(storage_path) do
    identity_path = Path.join(storage_path, "transport_identity")

    identity =
      if File.exists?(identity_path) do
        RNS.Identity.from_file(identity_path)
      else
        nil
      end

    case identity do
      nil ->
        RNS.Log.log("No valid Transport Identity in storage, creating...", :verbose)
        new_identity = RNS.Identity.new()
        RNS.Identity.to_file(new_identity, identity_path)
        new_identity

      loaded ->
        RNS.Log.log("Loaded Transport Identity from storage", :verbose)
        loaded
    end
  end

  # ── Control & Management Destination Creation ─────────────────────────

  # Creates all control and management destinations. Matches Python's
  # Transport.start() destination setup.
  defp do_create_destinations(state, opts) do
    is_connected = Keyword.get(opts, :is_connected_to_shared_instance, false)
    identity = state.identity

    # -- Always create control destinations --
    # We build destinations manually (using Destination struct construction
    # helpers) instead of Destination.new/5 because new/5 auto-calls
    # Transport.register_destination via GenServer.call, which would deadlock
    # since we're already inside a Transport GenServer callback.
    path_req = build_path_request_destination()
    tunnel_synth = build_tunnel_synthesize_destination()

    control_hashes = [path_req.hash, tunnel_synth.hash]

    # -- Conditionally create management destinations --
    mgmt_hashes = []

    # Probe destination
    probe_enabled = Keyword.get(opts, :probe_enabled, false)

    {probe_dest, mgmt_hashes} =
      if probe_enabled and identity != nil do
        dest =
          build_destination(identity, RNS.Destination.single(), @app_name, ["probe"])
          |> RNS.Destination.set_accepts_links(false)
          |> RNS.Destination.set_proof_strategy(RNS.Destination.prove_all())

        {dest, [dest.hash | mgmt_hashes]}
      else
        {nil, mgmt_hashes}
      end

    # Remote management destination
    remote_mgmt_enabled = Keyword.get(opts, :remote_management_enabled, false)
    remote_mgmt_allowed = Keyword.get(opts, :remote_management_allowed, [])

    {remote_mgmt_dest, mgmt_hashes} =
      if remote_mgmt_enabled and not is_connected and identity != nil do
        dest =
          build_destination(identity, RNS.Destination.single(), @app_name, ["remote", "management"])
          |> RNS.Destination.register_request_handler("/status",
            response_generator: &remote_status_handler/2,
            allow: RNS.Destination.allow_list(),
            allowed_list: remote_mgmt_allowed
          )
          |> RNS.Destination.register_request_handler("/path",
            response_generator: &remote_path_handler/2,
            allow: RNS.Destination.allow_list(),
            allowed_list: remote_mgmt_allowed
          )

        {dest, [dest.hash | mgmt_hashes]}
      else
        {nil, mgmt_hashes}
      end

    # Blackhole destination
    publish_blackhole = Keyword.get(opts, :publish_blackhole, false)

    {blackhole_dest, mgmt_hashes} =
      if publish_blackhole and not is_connected and identity != nil do
        dest =
          build_destination(identity, RNS.Destination.single(), @app_name, ["info", "blackhole"])
          |> RNS.Destination.register_request_handler("/list",
            response_generator: &blackhole_list_handler/2,
            allow: RNS.Destination.allow_all()
          )

        {dest, [dest.hash | mgmt_hashes]}
      else
        {nil, mgmt_hashes}
      end

    # Network destinations
    net_identity = Keyword.get(opts, :network_identity, nil)

    {instance_dest, network_dest, mgmt_hashes} =
      if net_identity != nil and not is_connected do
        hexhash = Base.encode16(net_identity.hash, case: :lower)

        inst = build_destination(net_identity, RNS.Destination.single(), @app_name, ["network", "instance", hexhash])
        net = build_destination(net_identity, RNS.Destination.single(), @app_name, ["network"])

        {inst, net, [net.hash, inst.hash | mgmt_hashes]}
      else
        {nil, nil, mgmt_hashes}
      end

    # Register all created destinations directly in ETS (bypassing GenServer.call)
    all_dests = [path_req, tunnel_synth, probe_dest, remote_mgmt_dest, blackhole_dest, instance_dest, network_dest]

    Enum.each(all_dests, fn
      nil -> :ok
      dest -> :ets.insert(@destinations_table, {dest.hash, dest})
    end)

    %{
      state
      | path_request_destination: path_req,
        tunnel_synthesize_destination: tunnel_synth,
        probe_destination: probe_dest,
        remote_management_destination: remote_mgmt_dest,
        blackhole_destination: blackhole_dest,
        instance_destination: instance_dest,
        network_destination: network_dest,
        control_hashes: control_hashes,
        mgmt_hashes: mgmt_hashes
    }
  end

  # Builds a Destination struct directly (without auto-registration via GenServer.call).
  # Used by do_create_destinations to avoid deadlocking when called from within
  # a Transport GenServer callback.
  defp build_destination(identity, type, app_name, aspects) do
    RNS.Destination.build(identity, RNS.Destination.direction_in(), type, app_name, aspects)
  end

  defp build_path_request_destination do
    dest = build_destination(nil, RNS.Destination.plain(), @app_name, ["path", "request"])
    RNS.Destination.set_packet_callback(dest, &path_request_handler/2)
  end

  defp build_tunnel_synthesize_destination do
    dest = build_destination(nil, RNS.Destination.plain(), @app_name, ["tunnel", "synthesize"])
    RNS.Destination.set_packet_callback(dest, &RNS.Transport.TunnelManagement.tunnel_synthesize_handler/2)
  end

  # ── Path Request Processing ─────────────────────────────────────────

  # Core path request routing logic. Called within the GenServer process
  # from path_request_handler. Matches Python's Transport.path_request().
  @doc false
  def transport_enabled? do
    case :ets.lookup(@path_states_table, :_transport_config) do
      [{:_transport_config, config}] -> Map.get(config, :transport_enabled, false)
      [] -> false
    end
  end

  @doc false
  def local_client_interfaces do
    case :ets.lookup(@path_states_table, :_transport_config) do
      [{:_transport_config, config}] -> Map.get(config, :local_client_interfaces, [])
      [] -> []
    end
  end

  defp update_transport_config(state) do
    config = %{
      transport_enabled: state.transport_enabled,
      local_client_interfaces: state.local_client_interfaces
    }

    :ets.insert(@path_states_table, {:_transport_config, config})
  end

  defp do_path_request(destination_hash, is_from_local_client, attached_interface, requestor_transport_id, tag) do
    transport_enabled = transport_enabled?()
    local_client_ifaces = local_client_interfaces()
    interface_str = if attached_interface, do: " on #{attached_interface}", else: ""

    Logger.debug("Path request for #{RNS.prettyhexrep(destination_hash)}#{interface_str}")

    # Check if destination exists on a local client
    if length(local_client_ifaces) > 0 do
      case get_path_entry(destination_hash) do
        %{interface: iface} when iface != nil ->
          if local_client_interface?(iface) do
            :ets.insert(@pending_local_path_requests_table, {destination_hash, attached_interface})
          end

        _ ->
          :ok
      end
    end

    # Find local destination
    local_destination =
      get_destinations()
      |> Enum.find(fn dest -> dest.hash == destination_hash end)

    cond do
      # Branch 1: Local destination — respond with announce
      local_destination != nil ->
        RNS.Destination.announce(local_destination,
          path_response: true,
          tag: tag,
          attached_interface: attached_interface
        )

        Logger.debug(
          "Answering path request for #{RNS.prettyhexrep(destination_hash)}#{interface_str}, destination is local"
        )

      # Branch 2: Known path in table
      (transport_enabled or is_from_local_client) and has_path(destination_hash) ->
        handle_known_path_request(
          destination_hash,
          is_from_local_client,
          attached_interface,
          requestor_transport_id,
          interface_str
        )

      # Branch 3: From local client, no known path — forward to all interfaces
      is_from_local_client ->
        Logger.debug(
          "Forwarding path request from local client for #{RNS.prettyhexrep(destination_hash)}#{interface_str}"
        )

        request_tag = RNS.Identity.random_hash()
        interfaces = get_interfaces()

        Enum.each(interfaces, fn iface ->
          if iface != attached_interface do
            request_path(destination_hash, iface, tag: request_tag)
          end
        end)

      # Branch 4: Should search for unknown (transport + discoverable mode)
      transport_enabled and attached_interface != nil and
          Map.get(attached_interface, :mode) in RNS.Interfaces.Interface.discover_paths_for() ->
        if :ets.member(@discovery_path_requests_table, destination_hash) do
          Logger.debug(
            "Already waiting for path to #{RNS.prettyhexrep(destination_hash)}#{interface_str}"
          )
        else
          Logger.debug(
            "Discovering unknown path to #{RNS.prettyhexrep(destination_hash)}#{interface_str}"
          )

          pr_entry = %{
            timeout: System.system_time(:second) + @path_request_timeout,
            requesting_interface: attached_interface
          }

          :ets.insert(@discovery_path_requests_table, {destination_hash, pr_entry})

          interfaces = get_interfaces()

          Enum.each(interfaces, fn iface ->
            if iface != attached_interface do
              request_path(destination_hash, iface, tag: tag, recursive: true)
            end
          end)
        end

      # Branch 5: Not from local client, but local clients exist — forward to them
      not is_from_local_client and length(local_client_ifaces) > 0 ->
        Logger.debug(
          "Forwarding path request for #{RNS.prettyhexrep(destination_hash)}#{interface_str} to local clients"
        )

        Enum.each(local_client_ifaces, fn iface ->
          request_path(destination_hash, iface)
        end)

      # No path known
      true ->
        Logger.debug(
          "Ignoring path request for #{RNS.prettyhexrep(destination_hash)}#{interface_str}, no path known"
        )
    end
  end

  # Branch 2 helper: handle path request when we have a known path
  defp handle_known_path_request(destination_hash, is_from_local_client, attached_interface, requestor_transport_id, interface_str) do
    path_entry = get_path_entry(destination_hash)
    packet = get_cached_packet(path_entry.packet_hash, packet_type: "announce")
    next_hop = path_entry.next_hop
    received_from = path_entry.interface

    cond do
      packet == nil ->
        Logger.error(
          "Could not retrieve cached announce for path request #{RNS.prettyhexrep(destination_hash)}"
        )

      attached_interface != nil and
        Map.get(attached_interface, :mode) == RNS.Interfaces.Interface.mode_roaming() and
          attached_interface == received_from ->
        Logger.debug(
          "Not answering path request on roaming-mode interface, next hop is on same interface"
        )

      requestor_transport_id != nil and next_hop == requestor_transport_id ->
        Logger.debug(
          "Not answering path request for #{RNS.prettyhexrep(destination_hash)}#{interface_str}, next hop is requestor"
        )

      true ->
        Logger.debug(
          "Answering path request for #{RNS.prettyhexrep(destination_hash)}#{interface_str}, path is known"
        )

        now = System.system_time(:second)
        retries = @pathfinder_r
        local_rebroadcasts = 0
        block_rebroadcasts = true
        announce_hops = path_entry.hops

        unpacked = RNS.Packet.unpack(packet)
        unpacked = %{unpacked | hops: announce_hops}

        retransmit_timeout =
          cond do
            is_from_local_client ->
              now

            local_client_interface?(next_hop_interface(destination_hash)) ->
              now

            true ->
              base = now + @path_request_grace

              if attached_interface != nil and
                   Map.get(attached_interface, :mode) == RNS.Interfaces.Interface.mode_roaming() do
                base + @path_request_rg
              else
                base
              end
          end

        # Handle held-announces edge case
        case get_announce_entry(destination_hash) do
          nil ->
            :ok

          existing_entry ->
            :ets.insert(@held_announces_table, {destination_hash, existing_entry})
        end

        announce_entry = %AnnounceHandler.AnnounceEntry{
          timestamp: now,
          retransmit_timeout: retransmit_timeout,
          retries: retries,
          received_from: received_from,
          hops: announce_hops,
          packet: unpacked,
          local_rebroadcasts: local_rebroadcasts,
          block_rebroadcasts: block_rebroadcasts,
          attached_interface: attached_interface
        }

        AnnounceHandler.put_announce_entry(destination_hash, announce_entry)
    end
  end

  # Path request handler callback — processes incoming path request packets.
  # Matches Python's Transport.path_request_handler.
  defp path_request_handler(data, packet) do
    truncated_bytes = div(@truncated_hashlength, 8)

    try do
      if byte_size(data) >= truncated_bytes do
        destination_hash = binary_part(data, 0, truncated_bytes)

        requesting_transport_instance =
          if byte_size(data) > truncated_bytes * 2 do
            binary_part(data, truncated_bytes, truncated_bytes)
          else
            nil
          end

        tag_bytes =
          cond do
            byte_size(data) > truncated_bytes * 2 ->
              binary_part(data, truncated_bytes * 2, byte_size(data) - truncated_bytes * 2)

            byte_size(data) > truncated_bytes ->
              binary_part(data, truncated_bytes, byte_size(data) - truncated_bytes)

            true ->
              nil
          end

        if tag_bytes != nil do
          tag_bytes =
            if byte_size(tag_bytes) > truncated_bytes do
              binary_part(tag_bytes, 0, truncated_bytes)
            else
              tag_bytes
            end

          unique_tag = destination_hash <> tag_bytes

          if :ets.member(@discovery_pr_tags_table, unique_tag) do
            Logger.debug(
              "Ignoring duplicate path request for #{RNS.prettyhexrep(destination_hash)}"
            )
          else
            :ets.insert(@discovery_pr_tags_table, {unique_tag, System.system_time(:second)})

            do_path_request(
              destination_hash,
              from_local_client?(packet),
              Map.get(packet, :receiving_interface),
              requesting_transport_instance,
              tag_bytes
            )
          end
        else
          Logger.debug(
            "Ignoring tagless path request for #{RNS.prettyhexrep(destination_hash)}"
          )
        end
      end
    rescue
      e ->
        Logger.error("Error while handling path request: #{Exception.message(e)}")
    end
  end

  # Remote status handler — returns interface stats and optionally link counts.
  # Matches Python's Transport.remote_status_handler.
  defp remote_status_handler(data, %{remote_identity: remote_identity}) do
    if remote_identity != nil do
      Logger.debug("Remote status request received")

      try do
        response = [RNS.Reticulum.get_interface_stats()]

        if is_list(data) and length(data) > 0 and hd(data) == true do
          response ++ [RNS.Reticulum.get_link_count()]
        else
          response
        end
      rescue
        e ->
          Logger.error("Error processing remote status request: #{Exception.message(e)}")
          nil
      end
    end
  end

  # Remote path handler — returns filtered path table or rate table.
  # Matches Python's Transport.remote_path_handler.
  defp remote_path_handler(data, %{remote_identity: remote_identity}) do
    if remote_identity != nil do
      Logger.debug("Remote path request received")

      try do
        if is_list(data) and length(data) > 0 do
          command = hd(data)
          destination_hash = if length(data) > 1, do: Enum.at(data, 1)
          max_hops = if length(data) > 2, do: Enum.at(data, 2)

          table =
            case command do
              "table" -> RNS.Reticulum.get_path_table(max_hops)
              "rates" -> RNS.Reticulum.get_rate_table()
              _ -> []
            end

          if destination_hash do
            Enum.filter(table, fn entry -> entry.hash == destination_hash end)
          else
            table
          end
        end
      rescue
        e ->
          Logger.error("Error processing remote path request: #{Exception.message(e)}")
          nil
      end
    end
  end

  # Blackhole list handler — returns the current blackhole list.
  # Matches Python's Transport.blackhole_list_handler.
  defp blackhole_list_handler(_data, _context) do
    GenServer.call(__MODULE__, :blackholed_identities)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # ── Periodic Job Logic ────────────────────────────────────────────────

  defp run_periodic_jobs(state, now, _now_ms) do
    state
    |> maybe_check_links(now)
    |> maybe_check_receipts(now)
    |> maybe_check_announces(now)
    |> maybe_cull_tables(now)
    |> maybe_rotate_hashlist()
    |> maybe_clean_cache(now)
  end

  defp maybe_check_links(state, now) do
    if now > state.links_last_checked + div(@links_check_interval, 1000) do
      # Remove closed pending links
      pending = :ets.tab2list(@pending_links_table)

      Enum.each(pending, fn {link_id, link} ->
        if Map.get(link, :status) == RNS.Link.closed() do
          :ets.delete(@pending_links_table, link_id)

          # Expire path and potentially rediscover
          if Map.get(link, :destination) do
            expire_path(link.destination.hash)
          end
        end
      end)

      # Remove closed active links
      active = :ets.tab2list(@active_links_table)

      Enum.each(active, fn {link_id, link} ->
        if Map.get(link, :status) == RNS.Link.closed() do
          :ets.delete(@active_links_table, link_id)
        end
      end)

      %{state | links_last_checked: now}
    else
      state
    end
  end

  defp maybe_check_receipts(state, now) do
    if now > state.receipts_last_checked + div(@receipts_check_interval, 1000) do
      # Cull excess receipts
      receipts = get_all_receipts()

      if length(receipts) > @max_receipts do
        # Sort by sent_at and remove oldest
        sorted = Enum.sort_by(receipts, & &1.sent_at)
        excess = length(sorted) - @max_receipts

        sorted
        |> Enum.take(excess)
        |> Enum.each(fn receipt ->
          remove_receipt(receipt.hash)
        end)
      end

      # Check timeouts on remaining receipts
      :ets.tab2list(@receipts_table)
      |> Enum.each(fn {hash, receipt} ->
        timeout = Map.get(receipt, :timeout, 0)
        sent_at = Map.get(receipt, :sent_at, 0)

        if timeout > 0 and sent_at > 0 and
             System.system_time(:second) > sent_at + timeout do
          # Timeout callback
          if is_function(get_in(receipt, [:callbacks, :timeout]), 1) do
            try do
              receipt.callbacks.timeout.(receipt)
            rescue
              _ -> :ok
            end
          end

          remove_receipt(hash)
        end
      end)

      %{state | receipts_last_checked: now}
    else
      state
    end
  end

  defp maybe_check_announces(state, now) do
    if now > state.announces_last_checked + div(@announces_check_interval, 1000) do
      {_outgoing, _completed} = AnnounceHandler.process_announce_queue()

      # Check for held announces to reinsert
      :ets.tab2list(@held_announces_table)
      |> Enum.each(fn {dest_hash, held_entry} ->
        if get_announce_entry(dest_hash) == nil do
          put_announce_entry(dest_hash, held_entry)
          :ets.delete(@held_announces_table, dest_hash)
        end
      end)

      %{state | announces_last_checked: now}
    else
      state
    end
  end

  defp maybe_cull_tables(state, now) do
    if now > state.tables_last_culled + div(@tables_cull_interval, 1000) do
      cull_path_states()
      cull_reverse_table(now)
      cull_link_table(now)
      cull_tunnel_table(now)
      cull_discovery_pr_tags()
      cull_discovery_path_requests(now)

      %{state | tables_last_culled: now}
    else
      state
    end
  end

  defp maybe_rotate_hashlist(state) do
    hashlist_size = :ets.info(@packet_hashlist_table, :size)

    if hashlist_size > div(@hashlist_maxsize, 2) do
      # In Python, this swaps to a prev hashlist. In our ETS approach,
      # we just delete the oldest half of entries.
      # Since ETS doesn't maintain insertion order, we clear the table.
      :ets.delete_all_objects(@packet_hashlist_table)
    end

    state
  end

  defp maybe_clean_cache(state, now) do
    if state.cachepath != nil and
         now > state.cache_last_cleaned + div(@cache_clean_interval, 1000) do
      CacheManagement.clean_cache(state.cachepath)
      %{state | cache_last_cleaned: now}
    else
      state
    end
  end

  # ── Table Culling Functions ───────────────────────────────────────────

  @doc "Removes path state entries for destinations no longer in the path table."
  @spec cull_path_states() :: :ok
  def cull_path_states do
    :ets.tab2list(@path_states_table)
    |> Enum.each(fn {dest_hash, _state} ->
      unless has_path(dest_hash) do
        :ets.delete(@path_states_table, dest_hash)
      end
    end)

    :ok
  end

  @doc "Removes expired reverse table entries."
  @spec cull_reverse_table(non_neg_integer()) :: :ok
  def cull_reverse_table(now) do
    interfaces = get_interfaces()
    interface_set = MapSet.new(interfaces)

    :ets.tab2list(@reverse_table)
    |> Enum.each(fn {hash, entry} ->
      stale =
        now > entry.timestamp + @reverse_timeout or
          entry.outbound_interface not in interface_set or
          entry.received_on_interface not in interface_set

      if stale, do: :ets.delete(@reverse_table, hash)
    end)

    :ok
  end

  @doc "Removes expired or invalid link table entries."
  @spec cull_link_table(non_neg_integer()) :: :ok
  def cull_link_table(now) do
    interfaces = get_interfaces()
    interface_set = MapSet.new(interfaces)

    :ets.tab2list(@link_table)
    |> Enum.each(fn {link_id, entry} ->
      stale =
        if entry.validated do
          now > entry.timestamp + @link_timeout or
            entry.next_hop_interface not in interface_set or
            entry.received_on_interface not in interface_set
        else
          now > entry.proof_timeout
        end

      if stale, do: :ets.delete(@link_table, link_id)
    end)

    :ok
  end

  @doc "Removes expired tunnel table entries."
  @spec cull_tunnel_table(non_neg_integer()) :: :ok
  def cull_tunnel_table(now) do
    :ets.tab2list(@tunnel_table)
    |> Enum.each(fn {tunnel_id, entry} ->
      if now > entry.expires do
        :ets.delete(@tunnel_table, tunnel_id)
      end
    end)

    :ok
  end

  @doc "Removes discovery path request tags when the table exceeds max size."
  @spec cull_discovery_pr_tags() :: :ok
  def cull_discovery_pr_tags do
    size = :ets.info(@discovery_pr_tags_table, :size)

    if size > @max_pr_tags do
      # Find the timestamp threshold: keep only the newest @max_pr_tags entries
      timestamps =
        :ets.tab2list(@discovery_pr_tags_table)
        |> Enum.map(fn {_tag, ts} -> ts end)
        |> Enum.sort(:desc)

      cutoff = Enum.at(timestamps, @max_pr_tags - 1, 0)

      :ets.select_delete(@discovery_pr_tags_table, [
        {{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
      ])
    end

    :ok
  end

  @doc "Removes expired discovery path requests."
  @spec cull_discovery_path_requests(non_neg_integer()) :: :ok
  def cull_discovery_path_requests(now) do
    :ets.tab2list(@discovery_path_requests_table)
    |> Enum.each(fn {dest_hash, entry} ->
      if now > entry.timeout do
        :ets.delete(@discovery_path_requests_table, dest_hash)
      end
    end)

    :ok
  end

  # ── Private Functions ─────────────────────────────────────────────────

  defp schedule_job(msg, interval) do
    Process.send_after(self(), msg, interval)
  end

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

    # Path request deduplication and discovery
    safe_create_table(@discovery_pr_tags_table, ets_opts)
    safe_create_table(@discovery_path_requests_table, ets_opts)
    safe_create_table(@pending_local_path_requests_table, ets_opts)
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
end
