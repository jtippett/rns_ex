defmodule RNS.Reticulum do
  @moduledoc """
  Main Reticulum system class — initialization, configuration, interface
  instantiation, and lifecycle management.

  This GenServer manages the lifecycle of a Reticulum instance, including
  configuration loading, directory management, interface instantiation from
  config, shared instance mode, and coordinating the startup and shutdown
  of Transport and Identity subsystems. Effectively a singleton per node.
  """

  use GenServer
  require Logger

  alias RNS.Reticulum.Config
  alias RNS.Vendor.ConfigObj
  alias RNS.Vendor.ConfigObj.Section

  # ── Protocol Constants ─────────────────────────────────────────────────

  @mtu 500
  @link_mtu_discovery true
  @max_queued_announces 16_384
  @queued_announce_life 60 * 60 * 24
  @announce_cap 2
  @minimum_bitrate 5
  @default_per_hop_timeout 6
  @truncated_hashlength 128

  @header_minsize 2 + 1 + div(@truncated_hashlength, 8)
  @header_maxsize 2 + 1 + div(@truncated_hashlength, 8) * 2
  @ifac_min_size 1
  @ifac_salt Base.decode16!(
               "ADF54D882C9A9B80771EB4995D702D4A3E733391B2A0F53F416D9F907E55CFF8",
               case: :upper
             )
  @mdu @mtu - @header_maxsize - @ifac_min_size

  # ── Timing Constants ───────────────────────────────────────────────────

  @resource_cache 24 * 60 * 60
  @job_interval 5 * 60
  @clean_interval 15 * 60
  @persist_interval 60 * 60 * 12
  @gracious_persist_interval 60 * 5

  # ── Constant Accessors ─────────────────────────────────────────────────

  @doc "The MTU that Reticulum adheres to. Default: 500 bytes."
  @spec mtu() :: non_neg_integer()
  def mtu, do: @mtu

  @doc "Whether automatic link MTU discovery is enabled by default."
  @spec link_mtu_discovery_default() :: boolean()
  def link_mtu_discovery_default, do: @link_mtu_discovery

  @doc "Maximum number of queued announces."
  @spec max_queued_announces() :: non_neg_integer()
  def max_queued_announces, do: @max_queued_announces

  @doc "Lifetime for queued announces in seconds (24 hours)."
  @spec queued_announce_life() :: non_neg_integer()
  def queued_announce_life, do: @queued_announce_life

  @doc "Maximum percentage of interface bandwidth for announce propagation."
  @spec announce_cap() :: non_neg_integer()
  def announce_cap, do: @announce_cap

  @doc "Minimum bitrate required for link establishment (5 bps)."
  @spec minimum_bitrate() :: non_neg_integer()
  def minimum_bitrate, do: @minimum_bitrate

  @doc "Default per-hop timeout in seconds."
  @spec default_per_hop_timeout() :: non_neg_integer()
  def default_per_hop_timeout, do: @default_per_hop_timeout

  @doc "Truncated hash length in bits."
  @spec truncated_hashlength() :: non_neg_integer()
  def truncated_hashlength, do: @truncated_hashlength

  @doc "Minimum header size in bytes."
  @spec header_minsize() :: non_neg_integer()
  def header_minsize, do: @header_minsize

  @doc "Maximum header size in bytes."
  @spec header_maxsize() :: non_neg_integer()
  def header_maxsize, do: @header_maxsize

  @doc "Minimum IFAC size in bytes."
  @spec ifac_min_size() :: non_neg_integer()
  def ifac_min_size, do: @ifac_min_size

  @doc "IFAC salt for HKDF derivation."
  @spec ifac_salt() :: binary()
  def ifac_salt, do: @ifac_salt

  @doc "Maximum data unit size."
  @spec mdu() :: non_neg_integer()
  def mdu, do: @mdu

  @doc "Resource cache lifetime in seconds (24 hours)."
  @spec resource_cache() :: non_neg_integer()
  def resource_cache, do: @resource_cache

  @doc "Job interval in seconds (5 minutes)."
  @spec job_interval() :: non_neg_integer()
  def job_interval, do: @job_interval

  @doc "Cache cleaning interval in seconds (15 minutes)."
  @spec clean_interval() :: non_neg_integer()
  def clean_interval, do: @clean_interval

  @doc "Data persistence interval in seconds (12 hours)."
  @spec persist_interval() :: non_neg_integer()
  def persist_interval, do: @persist_interval

  @doc "Gracious persistence interval in seconds (5 minutes)."
  @spec gracious_persist_interval() :: non_neg_integer()
  def gracious_persist_interval, do: @gracious_persist_interval

  # ── GenServer Client API ───────────────────────────────────────────────

  @doc """
  Starts the Reticulum GenServer.

  ## Options

    * `:configdir` - Custom configuration directory path. If not given,
      auto-detects from `/etc/reticulum`, `~/.config/reticulum`, or `~/.reticulum`.
    * `:loglevel` - Override log level (0-7).
    * `:verbosity` - Additional verbosity added to config loglevel.
    * `:server_name` - GenServer registration name (default: `RNS.Reticulum`).
    * `:skip_start` - If true, skip starting Transport/IdentityStore (for testing).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :server_name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current Reticulum instance's state."
  @spec get_state(GenServer.server()) :: map()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc "Returns the configuration directory path."
  @spec configdir(GenServer.server()) :: String.t() | nil
  def configdir(server \\ __MODULE__), do: GenServer.call(server, :configdir)

  @doc "Returns the configuration file path."
  @spec configpath(GenServer.server()) :: String.t() | nil
  def configpath(server \\ __MODULE__), do: GenServer.call(server, :configpath)

  @doc "Returns the storage directory path."
  @spec storagepath(GenServer.server()) :: String.t() | nil
  def storagepath(server \\ __MODULE__), do: GenServer.call(server, :storagepath)

  @doc "Returns the cache directory path."
  @spec cachepath(GenServer.server()) :: String.t() | nil
  def cachepath(server \\ __MODULE__), do: GenServer.call(server, :cachepath)

  @doc "Returns the resource storage path."
  @spec resourcepath(GenServer.server()) :: String.t() | nil
  def resourcepath(server \\ __MODULE__), do: GenServer.call(server, :resourcepath)

  @doc "Returns the identity storage path."
  @spec identitypath(GenServer.server()) :: String.t() | nil
  def identitypath(server \\ __MODULE__), do: GenServer.call(server, :identitypath)

  @doc "Returns the blackhole storage path."
  @spec blackholepath(GenServer.server()) :: String.t() | nil
  def blackholepath(server \\ __MODULE__), do: GenServer.call(server, :blackholepath)

  @doc "Returns the interface modules path."
  @spec interfacepath(GenServer.server()) :: String.t() | nil
  def interfacepath(server \\ __MODULE__), do: GenServer.call(server, :interfacepath)

  @doc "Returns whether transport is enabled."
  @spec transport_enabled?(GenServer.server()) :: boolean()
  def transport_enabled?(server \\ __MODULE__), do: GenServer.call(server, :transport_enabled?)

  @doc "Returns whether implicit proofs should be used."
  @spec should_use_implicit_proof?(GenServer.server()) :: boolean()
  def should_use_implicit_proof?(server \\ __MODULE__),
    do: GenServer.call(server, :should_use_implicit_proof?)

  @doc "Returns whether link MTU discovery is enabled."
  @spec link_mtu_discovery?(GenServer.server()) :: boolean()
  def link_mtu_discovery?(server \\ __MODULE__), do: GenServer.call(server, :link_mtu_discovery?)

  @doc "Returns whether remote management is enabled."
  @spec remote_management_enabled?(GenServer.server()) :: boolean()
  def remote_management_enabled?(server \\ __MODULE__),
    do: GenServer.call(server, :remote_management_enabled?)

  @doc "Returns whether probe destinations are enabled."
  @spec probe_destination_enabled?(GenServer.server()) :: boolean()
  def probe_destination_enabled?(server \\ __MODULE__),
    do: GenServer.call(server, :probe_destination_enabled?)

  @doc "Returns the required discovery value."
  @spec required_discovery_value(GenServer.server()) :: non_neg_integer() | nil
  def required_discovery_value(server \\ __MODULE__),
    do: GenServer.call(server, :required_discovery_value)

  @doc "Returns whether blackhole publishing is enabled."
  @spec publish_blackhole_enabled?(GenServer.server()) :: boolean()
  def publish_blackhole_enabled?(server \\ __MODULE__),
    do: GenServer.call(server, :publish_blackhole_enabled?)

  @doc "Returns the list of blackhole source identity hashes."
  @spec blackhole_sources(GenServer.server()) :: [binary()]
  def blackhole_sources(server \\ __MODULE__), do: GenServer.call(server, :blackhole_sources)

  @doc "Returns the list of interface discovery source identity hashes."
  @spec interface_discovery_sources(GenServer.server()) :: [binary()]
  def interface_discovery_sources(server \\ __MODULE__),
    do: GenServer.call(server, :interface_discovery_sources)

  @doc "Returns whether interface discovery is enabled."
  @spec discover_interfaces?(GenServer.server()) :: boolean()
  def discover_interfaces?(server \\ __MODULE__),
    do: GenServer.call(server, :discover_interfaces?)

  @doc "Returns the parsed config (Section struct)."
  @spec get_config(GenServer.server()) :: Section.t() | nil
  def get_config(server \\ __MODULE__), do: GenServer.call(server, :get_config)

  @doc "Returns whether this instance is a shared instance."
  @spec is_shared_instance?(GenServer.server()) :: boolean()
  def is_shared_instance?(server \\ __MODULE__),
    do: GenServer.call(server, :is_shared_instance?)

  @doc "Returns whether this instance is standalone."
  @spec is_standalone_instance?(GenServer.server()) :: boolean()
  def is_standalone_instance?(server \\ __MODULE__),
    do: GenServer.call(server, :is_standalone_instance?)

  @doc "Returns whether connected to a shared instance."
  @spec is_connected_to_shared_instance?(GenServer.server()) :: boolean()
  def is_connected_to_shared_instance?(server \\ __MODULE__),
    do: GenServer.call(server, :is_connected_to_shared_instance?)

  @doc "Returns whether auto-connecting discovered interfaces is enabled."
  @spec should_autoconnect_discovered_interfaces?(GenServer.server()) :: boolean()
  def should_autoconnect_discovered_interfaces?(server \\ __MODULE__) do
    GenServer.call(server, :should_autoconnect_discovered_interfaces?)
  end

  @doc "Returns the maximum number of auto-connected interfaces (0 if disabled)."
  @spec max_autoconnected_interfaces(GenServer.server()) :: non_neg_integer()
  def max_autoconnected_interfaces(server \\ __MODULE__) do
    GenServer.call(server, :max_autoconnected_interfaces)
  end

  @doc "Returns whether a network identity is configured."
  @spec has_network_identity?(GenServer.server()) :: boolean()
  def has_network_identity?(server \\ __MODULE__),
    do: GenServer.call(server, :has_network_identity?)

  @doc "Returns the network identity if configured."
  @spec network_identity(GenServer.server()) :: RNS.Identity.t() | nil
  def network_identity(server \\ __MODULE__), do: GenServer.call(server, :network_identity)

  @doc "Returns the identity used for this instance."
  @spec identity(GenServer.server()) :: RNS.Identity.t() | nil
  def identity(server \\ __MODULE__), do: GenServer.call(server, :identity)

  # ── Stats Functions (read ETS directly, no GenServer call needed) ────

  @doc "Returns interface statistics for all registered interfaces."
  @spec get_interface_stats() :: map()
  def get_interface_stats do
    interfaces =
      RNS.Transport.get_interfaces()
      |> Enum.map(fn iface ->
        %{
          name: to_string(Map.get(iface, :name, "unknown")),
          hash: Map.get(iface, :hash),
          type: interface_type_name(iface),
          rxb: Map.get(iface, :rxb, 0),
          txb: Map.get(iface, :txb, 0),
          status: Map.get(iface, :online, false),
          mode: Map.get(iface, :mode),
          bitrate: Map.get(iface, :bitrate),
          peers: get_peer_count(iface)
        }
      end)

    stats = %{
      interfaces: interfaces,
      rxb: RNS.Transport.traffic_rxb(),
      txb: RNS.Transport.traffic_txb()
    }

    if RNS.Transport.transport_enabled?() do
      Map.merge(stats, %{
        transport_id: RNS.Transport.identity_hash(),
        transport_uptime: System.system_time(:second) - RNS.Transport.start_time()
      })
    else
      stats
    end
  end

  defp interface_type_name(iface) do
    case Map.get(iface, :__struct__) do
      nil -> "unknown"
      mod -> mod |> Module.split() |> List.last()
    end
  end

  defp get_peer_count(iface) do
    case Map.get(iface, :peers) do
      peers when is_map(peers) -> map_size(peers)
      _ -> nil
    end
  end

  @doc "Returns the number of active links."
  @spec get_link_count() :: non_neg_integer()
  def get_link_count do
    RNS.Transport.link_table_size()
  end

  @doc "Returns the path table, optionally filtered by max hops."
  @spec get_path_table(non_neg_integer() | nil) :: [map()]
  def get_path_table(max_hops \\ nil) do
    RNS.Transport.get_all_path_entries()
    |> Enum.filter(fn {_hash, entry} ->
      max_hops == nil or entry.hops <= max_hops
    end)
    |> Enum.map(fn {hash, entry} ->
      %{
        hash: hash,
        timestamp: entry.timestamp,
        via: entry.next_hop,
        hops: entry.hops,
        expires: entry.expires,
        interface: if(entry.interface, do: to_string(entry.interface), else: nil)
      }
    end)
  end

  @doc "Returns the announce rate table."
  @spec get_rate_table() :: [map()]
  def get_rate_table do
    RNS.Transport.get_all_rate_entries()
    |> Enum.map(fn {hash, entry} ->
      %{
        hash: hash,
        last: Map.get(entry, :last),
        rate_violations: Map.get(entry, :rate_violations, 0),
        blocked_until: Map.get(entry, :blocked_until),
        timestamps: Map.get(entry, :timestamps, [])
      }
    end)
  end

  @doc """
  Persists all state to disk (known destinations, packet hashlist, path table, tunnels).

  Skips persistence when connected to a shared instance (the daemon owns the data).
  Called during shutdown and periodically during runtime.
  """
  @spec persist_data(GenServer.server()) :: :ok
  def persist_data(server \\ __MODULE__), do: GenServer.call(server, :persist_data)

  @doc "Triggers gracious persistence if enough time has elapsed."
  @spec should_persist_data(GenServer.server()) :: :ok
  def should_persist_data(server \\ __MODULE__),
    do: GenServer.cast(server, :should_persist_data)

  @doc "Adds a running interface process at runtime with the given options."
  @spec add_interface(GenServer.server(), pid(), keyword()) :: :ok | {:error, term()}
  def add_interface(server \\ __MODULE__, interface_pid, opts \\ []) do
    GenServer.call(server, {:add_interface, interface_pid, opts})
  end

  # ── Pure Functions (delegated to RNS.Reticulum.Config) ────────────────

  defdelegate determine_configdir(configdir), to: Config
  defdelegate compute_paths(configdir), to: Config

  @doc """
  Ensures all required directories exist.
  """
  @spec ensure_directories(map()) :: :ok
  def ensure_directories(paths) do
    dirs = [
      paths.storagepath,
      paths.cachepath,
      paths.resourcepath,
      paths.identitypath,
      paths.blackholepath,
      paths.interfacepath,
      Path.join(paths.cachepath, "announces")
    ]

    for dir <- dirs do
      File.mkdir_p!(dir)
    end

    :ok
  end

  @doc """
  Returns the default configuration as a string.
  """
  @spec default_config() :: String.t()
  def default_config do
    """
    # This is the default Reticulum config file.
    # You should probably edit it to include any additional,
    # interfaces and settings you might need.

    # Only the most basic options are included in this default
    # configuration. To see a more verbose, and much longer,
    # configuration example, you can run the command:
    # rnsd --exampleconfig


    [reticulum]

    # If you enable Transport, your system will route traffic
    # for other peers, pass announces and serve path requests.
    # This should only be done for systems that are suited to
    # act as transport nodes, ie. if they are stationary and
    # always-on. This directive is optional and can be removed
    # for brevity.

    enable_transport = False


    # By default, the first program to launch the Reticulum
    # Network Stack will create a shared instance, that other
    # programs can communicate with. Only the shared instance
    # opens all the configured interfaces directly, and other
    # local programs communicate with the shared instance over
    # a local socket. This is completely transparent to the
    # user, and should generally be turned on. This directive
    # is optional and can be removed for brevity.

    share_instance = Yes


    # If you want to run multiple *different* shared instances
    # on the same system, you will need to specify different
    # instance names for each. On platforms supporting domain
    # sockets, this can be done with the instance_name option:

    instance_name = default


    # Some platforms don't support domain sockets, and if that
    # is the case, you can isolate different instances by
    # specifying a unique set of ports for each:

    # shared_instance_port = 37428
    # instance_control_port = 37429


    # If you want to explicitly use TCP for shared instance
    # communication, instead of domain sockets, this is also
    # possible, by using the following option:

    # shared_instance_type = tcp


    # You can configure whether Reticulum should discover
    # available interfaces from other Transport Instances over
    # the network. If this option is enabled, Reticulum will
    # collect interface information discovered from the network.

    # discover_interfaces = No


    # You can configure Reticulum to panic and forcibly close
    # if an unrecoverable interface error occurs, such as the
    # hardware device for an interface disappearing. This is
    # an optional directive, and can be left out for brevity.
    # This behaviour is disabled by default.

    # panic_on_interface_error = No


    # If you're connecting to a large external network, you
    # can use one or more external blackhole list to block
    # spammy and excessive announces onto your network. This
    # funtionality is especially useful if you're hosting public
    # entrypoints or gateways. The list source below provides a
    # functional example, but better, more timely maintained
    # lists probably exist in the community.

    # blackhole_sources = 521c87a83afb8f29e4455e77930b973b


    [logging]
    # Valid log levels are 0 through 7:
    #   0: Log only critical information
    #   1: Log errors and lower log levels
    #   2: Log warnings and lower log levels
    #   3: Log notices and lower log levels
    #   4: Log info and lower (this is the default)
    #   5: Verbose logging
    #   6: Debug logging
    #   7: Extreme logging

    loglevel = 4


    # The interfaces section defines the physical and virtual
    # interfaces Reticulum will use to communicate on. This
    # section will contain examples for a variety of interface
    # types. You can modify these or use them as a basis for
    # your own config, or simply remove the unused ones.

    [interfaces]

      # This interface enables communication with other
      # link-local Reticulum nodes over UDP. It does not
      # need any functional IP infrastructure like routers
      # or DHCP servers, but will require that at least link-
      # local IPv6 is enabled in your operating system, which
      # should be enabled by default in almost any OS. See
      # the Reticulum Manual for more configuration options.

      [[Default Interface]]
        type = AutoInterface
        enabled = Yes
    """
  end

  @doc """
  Creates a default config file at the given path.
  """
  @spec create_default_config(String.t(), String.t()) :: {:ok, Section.t()} | {:error, term()}
  def create_default_config(configdir, configpath) do
    File.mkdir_p!(configdir)

    config_text = default_config()
    File.write!(configpath, config_text)

    ConfigObj.parse(config_text)
  end

  @doc """
  Applies configuration from a parsed config Section.

  Returns a map of configuration values extracted from the config.
  Delegates pure config parsing to `RNS.Reticulum.Config`, then applies
  network identity (which requires File IO) separately.
  """
  @spec apply_config(Section.t(), keyword()) :: map()
  def apply_config(config, opts \\ []) do
    state = Config.apply_config(config, opts)
    apply_network_identity_from_config(state, config)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    skip_start = Keyword.get(opts, :skip_start, false)
    require_shared = Keyword.get(opts, :require_shared_instance, false)
    configdir_opt = Keyword.get(opts, :configdir)

    # Determine config directory
    configdir = determine_configdir(configdir_opt)
    paths = compute_paths(configdir)

    # Ensure directories exist
    ensure_directories(paths)

    # Load or create config
    config =
      if File.regular?(paths.configpath) do
        case ConfigObj.parse_file(paths.configpath) do
          {:ok, config} ->
            config

          {:error, reason} ->
            Logger.error(
              "Could not parse configuration at #{paths.configpath}: #{inspect(reason)}"
            )

            Logger.error("Check your configuration file for errors!")
            raise "Configuration parse error: #{inspect(reason)}"
        end
      else
        Logger.info("Could not load config file, creating default configuration file...")

        case create_default_config(paths.configdir, paths.configpath) do
          {:ok, config} ->
            Logger.info(
              "Default config file created. Make any necessary changes in #{configdir}/config and restart Reticulum if needed."
            )

            config

          {:error, reason} ->
            raise "Could not create default config: #{inspect(reason)}"
        end
      end

    # Apply configuration
    applied = apply_config(config, opts)

    # Determine AF_UNIX usage
    use_af_unix =
      if RNS.Vendor.PlatformUtils.use_af_unix?() do
        applied.shared_instance_type != "tcp"
      else
        false
      end

    local_socket_path =
      cond do
        applied.local_socket_path != nil ->
          if use_af_unix do
            # Abstract Unix socket: null byte prefix + "rns/" + name (matches Python)
            <<0>> <> "rns/" <> applied.local_socket_path
          else
            applied.local_socket_path
          end

        use_af_unix ->
          # Default abstract Unix socket path (matches Python's "default")
          <<0>> <> "rns/default"

        true ->
          nil
      end

    state =
      Map.merge(paths, %{
        config: config,
        transport_enabled: applied.transport_enabled,
        link_mtu_discovery: applied.link_mtu_discovery,
        remote_management_enabled: applied.remote_management_enabled,
        use_implicit_proof: applied.use_implicit_proof,
        allow_probes: applied.allow_probes,
        discovery_enabled: applied.discovery_enabled,
        discover_interfaces: applied.discover_interfaces,
        autoconnect_discovered_interfaces: applied.autoconnect_discovered_interfaces,
        required_discovery_value: applied.required_discovery_value,
        publish_blackhole: applied.publish_blackhole,
        blackhole_sources: applied.blackhole_sources,
        interface_sources: applied.interface_sources,
        panic_on_interface_error: applied.panic_on_interface_error,
        share_instance: applied.share_instance,
        local_interface_port: applied.local_interface_port,
        local_control_port: applied.local_control_port,
        local_socket_path: local_socket_path,
        shared_instance_type: applied.shared_instance_type,
        rpc_key: applied.rpc_key,
        force_shared_instance_bitrate: applied.force_shared_instance_bitrate,
        network_identity: applied.network_identity,
        use_af_unix: use_af_unix,
        require_shared_instance: require_shared,
        is_shared_instance: false,
        is_standalone_instance: false,
        is_connected_to_shared_instance: false,
        shared_instance_interface: nil,
        last_data_persist: System.system_time(:second),
        last_cache_clean: 0,
        jobs_started: false,
        started_interfaces: [],
        blackholed_identities: %{}
      })

    if skip_start do
      {:ok, state}
    else
      # Configure the already-running IdentityStore and Transport with paths/config
      configure_subsystems(state)

      # Start local interface (shared/client/standalone mode)
      state = start_local_interface(state)

      # Create Transport control & management destinations (after shared-instance
      # detection so conditional flags are known)
      RNS.Transport.create_destinations(
        probe_enabled: state.allow_probes,
        remote_management_enabled: state.remote_management_enabled,
        publish_blackhole: state.publish_blackhole,
        is_connected_to_shared_instance: state.is_connected_to_shared_instance,
        network_identity: state.network_identity
      )

      # If a shared instance was required but none was available, abort
      if state.require_shared_instance and not state.is_connected_to_shared_instance do
        {:stop,
         {:shutdown,
          "No shared instance available, but application that started Reticulum required it"}}
      else
        # Start configured interfaces (only if shared or standalone)
        state =
          if state.is_shared_instance or state.is_standalone_instance do
            start_configured_interfaces(state)
          else
            state
          end

        # Start periodic jobs (Reticulum's own persist/clean cycle)
        schedule_job()

        # Start Transport's periodic maintenance jobs (link checks, receipts, etc.)
        RNS.Transport.start_jobs()

        {:ok, %{state | jobs_started: true}}
      end
    end
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:configdir, _from, state), do: {:reply, state.configdir, state}

  @impl true
  def handle_call(:configpath, _from, state), do: {:reply, state.configpath, state}

  @impl true
  def handle_call(:storagepath, _from, state), do: {:reply, state.storagepath, state}

  @impl true
  def handle_call(:cachepath, _from, state), do: {:reply, state.cachepath, state}

  @impl true
  def handle_call(:resourcepath, _from, state), do: {:reply, state.resourcepath, state}

  @impl true
  def handle_call(:identitypath, _from, state), do: {:reply, state.identitypath, state}

  @impl true
  def handle_call(:blackholepath, _from, state), do: {:reply, state.blackholepath, state}

  @impl true
  def handle_call(:interfacepath, _from, state), do: {:reply, state.interfacepath, state}

  @impl true
  def handle_call(:transport_enabled?, _from, state),
    do: {:reply, state.transport_enabled, state}

  @impl true
  def handle_call(:should_use_implicit_proof?, _from, state),
    do: {:reply, state.use_implicit_proof, state}

  @impl true
  def handle_call(:link_mtu_discovery?, _from, state),
    do: {:reply, state.link_mtu_discovery, state}

  @impl true
  def handle_call(:remote_management_enabled?, _from, state),
    do: {:reply, state.remote_management_enabled, state}

  @impl true
  def handle_call(:probe_destination_enabled?, _from, state),
    do: {:reply, state.allow_probes, state}

  @impl true
  def handle_call(:required_discovery_value, _from, state),
    do: {:reply, state.required_discovery_value, state}

  @impl true
  def handle_call(:publish_blackhole_enabled?, _from, state),
    do: {:reply, state.publish_blackhole, state}

  @impl true
  def handle_call(:blackhole_sources, _from, state),
    do: {:reply, state.blackhole_sources, state}

  @impl true
  def handle_call(:interface_discovery_sources, _from, state),
    do: {:reply, state.interface_sources, state}

  @impl true
  def handle_call(:discover_interfaces?, _from, state),
    do: {:reply, state.discover_interfaces, state}

  @impl true
  def handle_call(:get_config, _from, state),
    do: {:reply, state.config, state}

  @impl true
  def handle_call(:is_shared_instance?, _from, state),
    do: {:reply, state.is_shared_instance, state}

  @impl true
  def handle_call(:is_standalone_instance?, _from, state),
    do: {:reply, state.is_standalone_instance, state}

  @impl true
  def handle_call(:is_connected_to_shared_instance?, _from, state),
    do: {:reply, state.is_connected_to_shared_instance, state}

  @impl true
  def handle_call(:should_autoconnect_discovered_interfaces?, _from, state) do
    val = state.autoconnect_discovered_interfaces
    {:reply, is_integer(val) and val > 0, state}
  end

  @impl true
  def handle_call(:max_autoconnected_interfaces, _from, state) do
    val = state.autoconnect_discovered_interfaces
    {:reply, if(is_integer(val) and val > 0, do: val, else: 0), state}
  end

  @impl true
  def handle_call(:has_network_identity?, _from, state),
    do: {:reply, state.network_identity != nil, state}

  @impl true
  def handle_call(:network_identity, _from, state),
    do: {:reply, state.network_identity, state}

  @impl true
  def handle_call(:identity, _from, state),
    do: {:reply, Map.get(state, :identity), state}

  @impl true
  def handle_call({:blackhole_identity, identity_hash, entry}, _from, state) do
    blackholed = Map.put(state.blackholed_identities, identity_hash, entry)
    {:reply, :ok, %{state | blackholed_identities: blackholed}}
  end

  @impl true
  def handle_call({:unblackhole_identity, identity_hash}, _from, state) do
    blackholed = Map.delete(state.blackholed_identities, identity_hash)
    {:reply, :ok, %{state | blackholed_identities: blackholed}}
  end

  @impl true
  def handle_call(:get_blackholed_identities, _from, state) do
    {:reply, state.blackholed_identities, state}
  end

  @impl true
  def handle_call({:add_interface, interface_pid, opts}, _from, state) do
    if state.is_connected_to_shared_instance do
      {:reply, {:error, :connected_to_shared_instance}, state}
    else
      apply_interface_post_init(interface_pid, opts, state)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:persist_data, _from, state) do
    if state.is_connected_to_shared_instance do
      Logger.debug("Skipping state persistence — connected to shared instance")
    else
      do_persist_data(state)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:should_persist_data, state) do
    now = System.system_time(:second)

    state =
      if now > state.last_data_persist + @gracious_persist_interval do
        do_persist_data(state)
        %{state | last_data_persist: now}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:run_jobs, state) do
    now = System.system_time(:second)

    state =
      if now > state.last_cache_clean + @clean_interval do
        clean_caches(state)
        %{state | last_cache_clean: now}
      else
        state
      end

    state =
      if now > state.last_data_persist + @persist_interval do
        do_persist_data(state)
        %{state | last_data_persist: now}
      else
        state
      end

    schedule_job()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Logger.info("Reticulum shutting down...")

    # Detach all interfaces
    detach_all_interfaces(state)

    # Persist state — skip when connected to shared instance (Python parity:
    # Transport.exit_handler only persists if not connected to shared instance)
    if state.is_connected_to_shared_instance do
      Logger.debug("Skipping state persistence — connected to shared instance")
    else
      do_persist_data(state)
    end

    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp configure_subsystems(state) do
    # Tell IdentityStore the storage path so it can load known destinations
    RNS.IdentityStore.configure(state.storagepath)

    # Tell Transport its storage path, cache path, and transport mode
    RNS.Transport.configure(
      storage_path: state.storagepath,
      cachepath: state.cachepath,
      transport_enabled: state.transport_enabled
    )

    # Wire Transport.owner so remote handlers can access stats
    RNS.Transport.set_owner(self())
  end

  defp schedule_job do
    Process.send_after(self(), :run_jobs, @job_interval * 1000)
  end

  defp do_persist_data(_state) do
    # Delegate to each subsystem's own persist API — they know their own
    # storage paths and handle missing dirs gracefully.
    try do
      RNS.IdentityStore.save_known_destinations()
    rescue
      e -> Logger.debug("Could not save known destinations: #{Exception.message(e)}")
    end

    try do
      RNS.Transport.persist_data()
    rescue
      e -> Logger.debug("Could not save transport state: #{Exception.message(e)}")
    end

    :ok
  end

  # ── Interface Lifecycle ──────────────────────────────────────────────

  @doc false
  def start_local_interface(state) do
    if state.share_instance do
      # Try to become the shared instance by starting a LocalServerInterface
      case start_shared_server(state) do
        {:ok, state} ->
          if state.require_shared_instance do
            # We became the server, but the caller requires connecting to
            # an existing shared instance — detach and abort
            Logger.error(
              "Existing shared instance required, but this instance started as shared instance. Aborting startup."
            )

            cleanup_interface(state.shared_instance_interface)

            %{
              state
              | is_shared_instance: false,
                is_standalone_instance: false,
                is_connected_to_shared_instance: false,
                shared_instance_interface: nil,
                started_interfaces: List.delete(state.started_interfaces, state.shared_instance_interface)
            }
          else
            state
          end

        {:error, _reason} ->
          # Server port is in use — try connecting as a client
          case start_shared_client(state) do
            {:ok, state} ->
              state

            {:error, _reason} ->
              # Could not connect either — run standalone
              Logger.warning(
                "Local shared instance appears to be running, but could not be connected"
              )

              %{
                state
                | is_shared_instance: false,
                  is_standalone_instance: true,
                  is_connected_to_shared_instance: false
              }
          end
      end
    else
      # No sharing configured — standalone mode
      %{
        state
        | is_shared_instance: false,
          is_standalone_instance: true,
          is_connected_to_shared_instance: false
      }
    end
  end

  defp detach_interface(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :detach)
  catch
    :exit, _ -> :ok
  end

  # Full cleanup: detach, deregister from Transport, and terminate the process
  defp cleanup_interface(pid) when is_pid(pid) do
    detach_interface(pid)

    # Deregister from Transport
    if Process.alive?(pid) do
      iface_state = GenServer.call(pid, :get_state)
      hash = Map.get(iface_state, :hash) || RNS.Interfaces.Interface.hash(iface_state)

      if Process.whereis(RNS.Transport) do
        RNS.Transport.deregister_interface(%{hash: hash})
      end
    end

    # Terminate the process under DynamicSupervisor
    DynamicSupervisor.terminate_child(RNS.InterfaceSupervisor, pid)
  catch
    :exit, _ -> :ok
  end

  defp start_shared_server(state) do
    opts = [
      name: "Shared Instance",
      bindport: state.local_interface_port,
      socket_path: state.local_socket_path,
      out: true
    ]

    case DynamicSupervisor.start_child(
           RNS.InterfaceSupervisor,
           {RNS.Interfaces.LocalServerInterface, opts}
         ) do
      {:ok, pid} ->
        Logger.debug("Started shared instance interface")

        if state.force_shared_instance_bitrate do
          send(pid, {:set_field, :bitrate, state.force_shared_instance_bitrate})
        end

        # Register the shared server interface with Transport
        register_interface_with_transport(pid)

        {:ok,
         %{
           state
           | is_shared_instance: true,
             is_standalone_instance: false,
             is_connected_to_shared_instance: false,
             shared_instance_interface: pid,
             started_interfaces: [pid | state.started_interfaces]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_shared_client(state) do
    opts = [
      name: "Local shared instance",
      target_port: state.local_interface_port,
      socket_path: state.local_socket_path,
      out: true
    ]

    case DynamicSupervisor.start_child(
           RNS.InterfaceSupervisor,
           {RNS.Interfaces.LocalClientInterface, opts}
         ) do
      {:ok, pid} ->
        Logger.debug("Connected to locally available Reticulum instance")

        if state.force_shared_instance_bitrate do
          send(pid, {:set_field, :bitrate, state.force_shared_instance_bitrate})
        end

        # Register the shared client interface with Transport
        register_interface_with_transport(pid)

        {:ok,
         %{
           state
           | is_shared_instance: false,
             is_standalone_instance: false,
             is_connected_to_shared_instance: true,
             transport_enabled: false,
             remote_management_enabled: false,
             allow_probes: false,
             started_interfaces: [pid | state.started_interfaces]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def start_configured_interfaces(state) do
    if Section.has_key?(state.config, "interfaces") do
      interfaces_section = Section.get(state.config, "interfaces")
      interface_names = Section.section_names(interfaces_section)

      Logger.info("Bringing up system interfaces...")

      {_seen, final_state} =
        Enum.reduce(interface_names, {MapSet.new(), state}, fn name, {seen, acc_state} ->
          if MapSet.member?(seen, name) do
            Logger.error(
              "The interface name \"#{name}\" was already used. Check your configuration file for errors!"
            )

            {seen, acc_state}
          else
            new_state = synthesize_interface(acc_state, Section.get(interfaces_section, name), name)
            {MapSet.put(seen, name), new_state}
          end
        end)

      final_state
    else
      state
    end
  end

  @doc false
  @spec synthesize_interface(map(), Section.t(), String.t()) :: map()
  def synthesize_interface(state, config, name) do
    c = config

    # Check if interface is enabled
    enabled =
      cond do
        Section.has_key?(c, "interface_enabled") -> Section.as_bool(c, "interface_enabled")
        Section.has_key?(c, "enabled") -> Section.as_bool(c, "enabled")
        true -> false
      end

    if enabled do
      # Parse interface mode
      interface_mode = Config.parse_interface_mode(c)

      # Extract common config parameters
      params = extract_interface_params(c, interface_mode, name)

      # Determine interface type and start it
      case start_interface_by_type(c, name, params, state) do
        {:ok, pid, state} ->
          # Apply post-init settings to the running interface process
          apply_interface_post_init(pid, params, state)
          # Register the interface with Transport so it can be used for transmit.
          # Post-init updates are merged into the registration map to ensure
          # Transport has correct values (out, mode, IFAC, etc.)
          post_init_updates = Config.build_post_init_updates(params, state)
          register_interface_with_transport(pid, post_init_updates)
          %{state | started_interfaces: [pid | state.started_interfaces]}

        {:error, reason} ->
          Logger.error(
            "The interface \"#{name}\" could not be created. Check your configuration file for errors!"
          )

          Logger.error("The contained exception was: #{inspect(reason)}")

          if state.panic_on_interface_error do
            raise "Interface creation failed: #{inspect(reason)}"
          end

          state
      end
    else
      Logger.debug("Skipping disabled interface \"#{name}\"")
      state
    end
  rescue
    e ->
      Logger.error("The interface \"#{name}\" could not be created: #{Exception.message(e)}")

      if state.panic_on_interface_error do
        reraise e, __STACKTRACE__
      end

      state
  end

  defdelegate extract_interface_params(c, interface_mode, name), to: Config

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp start_interface_by_type(c, name, params, state) do
    type = Section.get(c, "type")

    # Build base opts from config section for the interface
    opts = Config.config_section_to_opts(c, name, params)

    case type do
      "AutoInterface" ->
        start_interface_child(RNS.Interfaces.AutoInterface, opts)

      "UDPInterface" ->
        start_interface_child(RNS.Interfaces.UDPInterface, opts)

      "TCPServerInterface" ->
        start_interface_child(RNS.Interfaces.TCPServerInterface, opts)

      "TCPClientInterface" ->
        start_interface_child(RNS.Interfaces.TCPClientInterface, opts)

      "BackboneInterface" ->
        if Section.has_key?(c, "target_host") or Section.has_key?(c, "remote") do
          start_interface_child(RNS.Interfaces.BackboneClientInterface, opts)
        else
          start_interface_child(RNS.Interfaces.BackboneInterface, opts)
        end

      "BackboneClientInterface" ->
        start_interface_child(RNS.Interfaces.BackboneClientInterface, opts)

      "I2PInterface" ->
        opts = Keyword.put(opts, :storagepath, state.storagepath)
        start_interface_child(RNS.Interfaces.I2PInterface, opts)

      "SerialInterface" ->
        start_interface_child(RNS.Interfaces.SerialInterface, opts)

      "PipeInterface" ->
        start_interface_child(RNS.Interfaces.PipeInterface, opts)

      "KISSInterface" ->
        start_interface_child(RNS.Interfaces.KISSInterface, opts)

      "AX25KISSInterface" ->
        start_interface_child(RNS.Interfaces.AX25KISSInterface, opts)

      "RNodeInterface" ->
        start_interface_child(RNS.Interfaces.RNodeInterface, opts)

      "RNodeMultiInterface" ->
        start_interface_child(RNS.Interfaces.RNodeMultiInterface, opts)

      "WeaveInterface" ->
        start_interface_child(RNS.Interfaces.WeaveInterface, opts)

      unknown ->
        Logger.error("Unknown interface type: #{unknown}")
        {:error, {:unknown_type, unknown}}
    end
    |> case do
      {:ok, pid} -> {:ok, pid, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_interface_child(module, opts) do
    case DynamicSupervisor.start_child(
           RNS.InterfaceSupervisor,
           {module, opts}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defdelegate config_section_to_opts(c, name, params), to: Config

  defp apply_interface_post_init(pid, params, state) when is_pid(pid) do
    # Build updates to send to the interface process via individual set_field messages
    updates = Config.build_post_init_updates(params, state)

    for {key, value} <- updates do
      send(pid, {:set_field, key, value})
    end

    :ok
  end

  defp apply_interface_post_init(_pid, _params, _state), do: :ok

  @doc false
  @spec register_interface_with_transport(pid(), map()) :: :ok
  def register_interface_with_transport(pid, extra_updates \\ %{}) when is_pid(pid) do
    # Get the interface's current state, merge any post-init updates,
    # add the pid, compute the hash, and register with Transport.
    state =
      if Process.alive?(pid) do
        GenServer.call(pid, :get_state)
      end

    if state do
      registration =
        state
        |> Map.from_struct()
        |> Map.merge(extra_updates)
        |> Map.put(:pid, pid)

      # Ensure hash is set
      registration =
        if registration[:hash] == nil do
          Map.put(
            registration,
            :hash,
            RNS.Interfaces.Interface.hash(registration)
          )
        else
          registration
        end

      RNS.Transport.register_interface(registration)
    else
      Logger.warning("Could not get state from interface #{inspect(pid)} for registration")
      :ok
    end
  end

  defdelegate build_post_init_updates(params, state), to: Config

  defp detach_all_interfaces(state) do
    # Get all interfaces from Transport, detach them, and deregister
    interfaces =
      if Process.whereis(RNS.Transport) do
        RNS.Transport.get_interfaces()
      else
        []
      end

    for interface <- interfaces do
      if Process.whereis(RNS.Transport) do
        RNS.Transport.deregister_interface(interface)
      end

      if is_map(interface) and Map.has_key?(interface, :pid) and is_pid(interface.pid) do
        send(interface.pid, :detach)
      end
    end

    # Also stop any interfaces we directly started
    for pid <- Map.get(state, :started_interfaces, []) do
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(RNS.InterfaceSupervisor, pid)
      end
    end

    :ok
  end

  defp clean_caches(state) do
    Logger.debug("Cleaning resource and packet caches...")
    now = System.system_time(:second)

    hash_filename_len = div(RNS.Identity.hashlength(), 8) * 2

    # Clean resource caches
    clean_cache_directory(state.resourcepath, hash_filename_len, @resource_cache, now)

    # Clean packet caches
    destination_timeout = 60 * 60 * 24 * 7
    clean_cache_directory(state.cachepath, hash_filename_len, destination_timeout, now)

    :ok
  end

  defp clean_cache_directory(path, expected_name_len, max_age, now) do
    case File.ls(path) do
      {:ok, files} ->
        for filename <- files,
            String.length(filename) == expected_name_len do
          filepath = Path.join(path, filename)

          case File.stat(filepath) do
            {:ok, %{mtime: mtime}} ->
              mtime_seconds =
                mtime
                |> NaiveDateTime.from_erl!()
                |> DateTime.from_naive!("Etc/UTC")
                |> DateTime.to_unix()

              age = now - mtime_seconds

              if age > max_age do
                File.rm(filepath)
              end

            _ ->
              :ok
          end
        end

      {:error, _} ->
        :ok
    end
  end

  # ── Delegated Config Functions ────────────────────────────────────────
  # Pure config parsing and application is in RNS.Reticulum.Config.
  # These delegations maintain the existing public API.

  defdelegate apply_logging_config(config, state, requested_loglevel, requested_verbosity),
    to: Config

  defdelegate apply_reticulum_config(config, state), to: Config

  # ── Impure Config Functions (File IO) ──────────────────────────────────

  defp apply_network_identity(state, section) do
    if Section.has_key?(section, "network_identity") and state.network_identity == nil do
      path = Section.get(section, "network_identity")
      identitypath = Path.expand(path)

      network_identity =
        if File.regular?(identitypath) do
          case RNS.Identity.from_file(identitypath) do
            %RNS.Identity{} = identity ->
              Logger.debug("Network identity loaded from #{identitypath}")
              identity

            nil ->
              raise "Could not set network identity from #{path}: load failed"
          end
        else
          identity = RNS.Identity.new()

          if RNS.Identity.to_file(identity, identitypath) do
            Logger.debug("Network identity generated and persisted to #{identitypath}")
            identity
          else
            raise "Could not persist network identity to #{identitypath}"
          end
        end

      Map.put(state, :network_identity, network_identity)
    else
      state
    end
  end

  defp apply_network_identity_from_config(state, config) do
    if Section.has_key?(config, "reticulum") do
      apply_network_identity(state, Section.get(config, "reticulum"))
    else
      state
    end
  end
end
