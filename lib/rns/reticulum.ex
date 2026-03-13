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

  alias RNS.Vendor.ConfigObj
  alias RNS.Vendor.ConfigObj.Section
  alias RNS.Interfaces.Interface

  # ── Protocol Constants ─────────────────────────────────────────────────

  @mtu 500
  @link_mtu_discovery true
  @max_queued_announces 16_384
  @queued_announce_life 60 * 60 * 24
  @announce_cap 2
  @minimum_bitrate 5
  @default_per_hop_timeout 6
  @truncated_hashlength 128

  @header_minsize 2 + 1 + div(@truncated_hashlength, 8) * 1
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

  # ── Default Ports ──────────────────────────────────────────────────────

  @default_local_interface_port 37428
  @default_local_control_port 37429

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
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Returns the configuration directory path."
  @spec configdir() :: String.t() | nil
  def configdir, do: GenServer.call(__MODULE__, :configdir)

  @doc "Returns the configuration file path."
  @spec configpath() :: String.t() | nil
  def configpath, do: GenServer.call(__MODULE__, :configpath)

  @doc "Returns the storage directory path."
  @spec storagepath() :: String.t() | nil
  def storagepath, do: GenServer.call(__MODULE__, :storagepath)

  @doc "Returns the cache directory path."
  @spec cachepath() :: String.t() | nil
  def cachepath, do: GenServer.call(__MODULE__, :cachepath)

  @doc "Returns the resource storage path."
  @spec resourcepath() :: String.t() | nil
  def resourcepath, do: GenServer.call(__MODULE__, :resourcepath)

  @doc "Returns the identity storage path."
  @spec identitypath() :: String.t() | nil
  def identitypath, do: GenServer.call(__MODULE__, :identitypath)

  @doc "Returns the blackhole storage path."
  @spec blackholepath() :: String.t() | nil
  def blackholepath, do: GenServer.call(__MODULE__, :blackholepath)

  @doc "Returns the interface modules path."
  @spec interfacepath() :: String.t() | nil
  def interfacepath, do: GenServer.call(__MODULE__, :interfacepath)

  @doc "Returns whether transport is enabled."
  @spec transport_enabled?() :: boolean()
  def transport_enabled?, do: GenServer.call(__MODULE__, :transport_enabled?)

  @doc "Returns whether implicit proofs should be used."
  @spec should_use_implicit_proof?() :: boolean()
  def should_use_implicit_proof?, do: GenServer.call(__MODULE__, :should_use_implicit_proof?)

  @doc "Returns whether link MTU discovery is enabled."
  @spec link_mtu_discovery?() :: boolean()
  def link_mtu_discovery?, do: GenServer.call(__MODULE__, :link_mtu_discovery?)

  @doc "Returns whether remote management is enabled."
  @spec remote_management_enabled?() :: boolean()
  def remote_management_enabled?, do: GenServer.call(__MODULE__, :remote_management_enabled?)

  @doc "Returns whether probe destinations are enabled."
  @spec probe_destination_enabled?() :: boolean()
  def probe_destination_enabled?, do: GenServer.call(__MODULE__, :probe_destination_enabled?)

  @doc "Returns the required discovery value."
  @spec required_discovery_value() :: non_neg_integer() | nil
  def required_discovery_value, do: GenServer.call(__MODULE__, :required_discovery_value)

  @doc "Returns whether blackhole publishing is enabled."
  @spec publish_blackhole_enabled?() :: boolean()
  def publish_blackhole_enabled?, do: GenServer.call(__MODULE__, :publish_blackhole_enabled?)

  @doc "Returns the list of blackhole source identity hashes."
  @spec blackhole_sources() :: [binary()]
  def blackhole_sources, do: GenServer.call(__MODULE__, :blackhole_sources)

  @doc "Returns the list of interface discovery source identity hashes."
  @spec interface_discovery_sources() :: [binary()]
  def interface_discovery_sources, do: GenServer.call(__MODULE__, :interface_discovery_sources)

  @doc "Returns whether interface discovery is enabled."
  @spec discover_interfaces?() :: boolean()
  def discover_interfaces?, do: GenServer.call(__MODULE__, :discover_interfaces?)

  @doc "Returns the parsed config (Section struct)."
  @spec get_config() :: Section.t() | nil
  def get_config, do: GenServer.call(__MODULE__, :get_config)

  @doc "Returns whether this instance is a shared instance."
  @spec is_shared_instance?() :: boolean()
  def is_shared_instance?, do: GenServer.call(__MODULE__, :is_shared_instance?)

  @doc "Returns whether this instance is standalone."
  @spec is_standalone_instance?() :: boolean()
  def is_standalone_instance?, do: GenServer.call(__MODULE__, :is_standalone_instance?)

  @doc "Returns whether connected to a shared instance."
  @spec is_connected_to_shared_instance?() :: boolean()
  def is_connected_to_shared_instance?,
    do: GenServer.call(__MODULE__, :is_connected_to_shared_instance?)

  @doc "Returns whether auto-connecting discovered interfaces is enabled."
  @spec should_autoconnect_discovered_interfaces?() :: boolean()
  def should_autoconnect_discovered_interfaces? do
    GenServer.call(__MODULE__, :should_autoconnect_discovered_interfaces?)
  end

  @doc "Returns the maximum number of auto-connected interfaces (0 if disabled)."
  @spec max_autoconnected_interfaces() :: non_neg_integer()
  def max_autoconnected_interfaces do
    GenServer.call(__MODULE__, :max_autoconnected_interfaces)
  end

  @doc "Returns whether a network identity is configured."
  @spec has_network_identity?() :: boolean()
  def has_network_identity?, do: GenServer.call(__MODULE__, :has_network_identity?)

  @doc "Returns the network identity if configured."
  @spec network_identity() :: RNS.Identity.t() | nil
  def network_identity, do: GenServer.call(__MODULE__, :network_identity)

  @doc "Returns the identity used for this instance."
  @spec identity() :: RNS.Identity.t() | nil
  def identity, do: GenServer.call(__MODULE__, :identity)

  @doc "Triggers gracious persistence if enough time has elapsed."
  @spec should_persist_data() :: :ok
  def should_persist_data, do: GenServer.cast(__MODULE__, :should_persist_data)

  @doc "Adds a running interface process at runtime with the given options."
  @spec add_interface(pid(), keyword()) :: :ok | {:error, term()}
  def add_interface(interface_pid, opts \\ []) do
    GenServer.call(__MODULE__, {:add_interface, interface_pid, opts})
  end

  # ── Pure Functions ─────────────────────────────────────────────────────

  @doc """
  Determines the configuration directory.

  Checks in order:
  1. Custom `configdir` option
  2. `/etc/reticulum` (if config file exists)
  3. `~/.config/reticulum` (if config file exists)
  4. `~/.reticulum` (default)
  """
  @spec determine_configdir(String.t() | nil) :: String.t()
  def determine_configdir(nil) do
    userdir = System.user_home!()

    cond do
      File.dir?("/etc/reticulum") and File.regular?("/etc/reticulum/config") ->
        "/etc/reticulum"

      File.dir?(Path.join(userdir, ".config/reticulum")) and
          File.regular?(Path.join(userdir, ".config/reticulum/config")) ->
        Path.join(userdir, ".config/reticulum")

      true ->
        Path.join(userdir, ".reticulum")
    end
  end

  def determine_configdir(custom) when is_binary(custom), do: custom

  @doc """
  Computes all storage paths from a config directory.
  """
  @spec compute_paths(String.t()) :: map()
  def compute_paths(configdir) do
    %{
      configdir: configdir,
      configpath: Path.join(configdir, "config"),
      storagepath: Path.join(configdir, "storage"),
      cachepath: Path.join([configdir, "storage", "cache"]),
      resourcepath: Path.join([configdir, "storage", "resources"]),
      identitypath: Path.join([configdir, "storage", "identities"]),
      blackholepath: Path.join([configdir, "storage", "blackhole"]),
      interfacepath: Path.join(configdir, "interfaces")
    }
  end

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
  """
  @spec apply_config(Section.t(), keyword()) :: map()
  def apply_config(config, opts \\ []) do
    requested_loglevel = Keyword.get(opts, :loglevel)
    requested_verbosity = Keyword.get(opts, :verbosity)

    state = %{
      transport_enabled: false,
      link_mtu_discovery: @link_mtu_discovery,
      remote_management_enabled: false,
      use_implicit_proof: true,
      allow_probes: false,
      discovery_enabled: false,
      discover_interfaces: false,
      autoconnect_discovered_interfaces: false,
      required_discovery_value: nil,
      publish_blackhole: false,
      blackhole_sources: [],
      interface_sources: [],
      panic_on_interface_error: false,
      share_instance: true,
      local_interface_port: @default_local_interface_port,
      local_control_port: @default_local_control_port,
      local_socket_path: nil,
      shared_instance_type: nil,
      rpc_key: nil,
      force_shared_instance_bitrate: nil,
      network_identity: nil
    }

    state = apply_logging_config(config, state, requested_loglevel, requested_verbosity)
    apply_reticulum_config(config, state)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    skip_start = Keyword.get(opts, :skip_start, false)
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
        applied.local_socket_path != nil -> applied.local_socket_path
        use_af_unix -> "default"
        true -> nil
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

    unless skip_start do
      # Start local interface (shared/client/standalone mode)
      state = start_local_interface(state)

      # Start configured interfaces (only if shared or standalone)
      state =
        if state.is_shared_instance or state.is_standalone_instance do
          start_configured_interfaces(state)
        else
          state
        end

      # Start periodic jobs
      schedule_job()

      {:ok, state}
    else
      {:ok, state}
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
  def handle_cast(:should_persist_data, state) do
    now = System.system_time(:second)

    state =
      if now > state.last_data_persist + @gracious_persist_interval do
        persist_data(state)
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
        persist_data(state)
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

    # Persist state
    persist_data(state)

    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp schedule_job do
    Process.send_after(self(), :run_jobs, @job_interval * 1000)
  end

  defp persist_data(state) do
    try do
      # Save Transport path table
      path_table_path = Path.join(state.storagepath, "path_table")
      RNS.Transport.save_path_table(path_table_path)
    rescue
      e -> Logger.debug("Could not save path table: #{Exception.message(e)}")
    end

    try do
      # Save packet hashlist
      hashlist_path = Path.join(state.storagepath, "packet_hashlist")
      RNS.Transport.save_packet_hashlist(hashlist_path)
    rescue
      e -> Logger.debug("Could not save packet hashlist: #{Exception.message(e)}")
    end

    try do
      # Save tunnel table
      tunnel_path = Path.join(state.storagepath, "tunnel_table")
      RNS.Transport.save_tunnel_table(tunnel_path)
    rescue
      e -> Logger.debug("Could not save tunnel table: #{Exception.message(e)}")
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
          state

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

  defp start_shared_server(state) do
    opts = [
      name: "Shared Instance",
      listen_port: state.local_interface_port,
      socket_path: state.local_socket_path
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
      socket_path: state.local_socket_path
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

      seen_names = MapSet.new()

      Enum.reduce(interface_names, state, fn name, acc_state ->
        if MapSet.member?(seen_names, name) do
          Logger.error(
            "The interface name \"#{name}\" was already used. Check your configuration file for errors!"
          )

          acc_state
        else
          # seen_names tracking happens across iterations but we don't mutate it
          # since ConfigObj already enforces unique section names
          interface_config = Section.get(interfaces_section, name)
          synthesize_interface(acc_state, interface_config, name)
        end
      end)
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

    unless enabled do
      Logger.debug("Skipping disabled interface \"#{name}\"")
      state
    else
      # Parse interface mode
      interface_mode = parse_interface_mode(c)

      # Extract common config parameters
      params = extract_interface_params(c, interface_mode, name)

      # Determine interface type and start it
      case start_interface_by_type(c, name, params, state) do
        {:ok, pid, state} ->
          # Apply post-init settings to the running interface process
          apply_interface_post_init(pid, params, state)
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
    end
  rescue
    e ->
      Logger.error("The interface \"#{name}\" could not be created: #{Exception.message(e)}")

      if state.panic_on_interface_error do
        reraise e, __STACKTRACE__
      end

      state
  end

  defp has_interface_mode_config?(c) do
    Section.has_key?(c, "interface_mode") or Section.has_key?(c, "mode")
  end

  defp parse_interface_mode(c) do
    mode_key =
      cond do
        Section.has_key?(c, "interface_mode") -> Section.get(c, "interface_mode")
        Section.has_key?(c, "mode") -> Section.get(c, "mode")
        true -> nil
      end

    case mode_key && String.downcase(to_string(mode_key)) do
      nil -> Interface.mode_full()
      "full" -> Interface.mode_full()
      mode when mode in ["access_point", "accesspoint", "ap"] -> Interface.mode_access_point()
      mode when mode in ["pointtopoint", "ptp"] -> Interface.mode_point_to_point()
      "roaming" -> Interface.mode_roaming()
      "boundary" -> Interface.mode_boundary()
      mode when mode in ["gateway", "gw"] -> Interface.mode_gateway()
      _ -> Interface.mode_full()
    end
  end

  @doc false
  def extract_interface_params(c, interface_mode, name) do
    # Parse interface mode from config (overrides passed-in mode if config specifies one)
    interface_mode =
      if has_interface_mode_config?(c), do: parse_interface_mode(c), else: interface_mode

    # IFAC parameters
    ifac_size =
      get_optional_int(c, "ifac_size", fn v -> if v >= @ifac_min_size * 8, do: div(v, 8) end)

    ifac_netname =
      get_nonempty_string(c, "networkname") || get_nonempty_string(c, "network_name")

    ifac_netkey =
      get_nonempty_string(c, "passphrase") || get_nonempty_string(c, "pass_phrase")

    # Ingress control
    ingress_control = get_optional_bool(c, "ingress_control", true)
    ic_max_held_announces = get_optional_int_raw(c, "ic_max_held_announces")
    ic_burst_hold = get_optional_float_raw(c, "ic_burst_hold")
    ic_burst_freq_new = get_optional_float_raw(c, "ic_burst_freq_new")
    ic_burst_freq = get_optional_float_raw(c, "ic_burst_freq")
    ic_new_time = get_optional_float_raw(c, "ic_new_time")
    ic_burst_penalty = get_optional_float_raw(c, "ic_burst_penalty")
    ic_held_release_interval = get_optional_float_raw(c, "ic_held_release_interval")

    # Bitrate
    configured_bitrate =
      get_optional_int(c, "bitrate", fn v -> if v >= @minimum_bitrate, do: v end)

    # Announce rate limiting
    announce_rate_target =
      get_optional_int(c, "announce_rate_target", fn v -> if v > 0, do: v end)

    announce_rate_grace =
      get_optional_int(c, "announce_rate_grace", fn v -> if v >= 0, do: v end)

    announce_rate_penalty =
      get_optional_int(c, "announce_rate_penalty", fn v -> if v >= 0, do: v end)

    # Default grace and penalty when target is set
    announce_rate_grace =
      if announce_rate_target != nil and announce_rate_grace == nil,
        do: 0,
        else: announce_rate_grace

    announce_rate_penalty =
      if announce_rate_target != nil and announce_rate_penalty == nil,
        do: 0,
        else: announce_rate_penalty

    # Announce cap
    announce_cap = @announce_cap / 100.0

    announce_cap =
      if Section.has_key?(c, "announce_cap") do
        v = Section.as_float(c, "announce_cap")
        if v > 0 and v <= 100, do: v / 100.0, else: announce_cap
      else
        announce_cap
      end

    # Bootstrap
    bootstrap_only = get_optional_bool(c, "bootstrap_only", false)

    # Outgoing
    outgoing =
      if Section.has_key?(c, "outgoing"), do: Section.as_bool(c, "outgoing"), else: true

    # Discovery settings
    {discoverable, discovery_params, interface_mode} =
      extract_discovery_params(c, interface_mode, name)

    %{
      interface_mode: interface_mode,
      ifac_size: ifac_size,
      ifac_netname: ifac_netname,
      ifac_netkey: ifac_netkey,
      ingress_control: ingress_control,
      ic_max_held_announces: ic_max_held_announces,
      ic_burst_hold: ic_burst_hold,
      ic_burst_freq_new: ic_burst_freq_new,
      ic_burst_freq: ic_burst_freq,
      ic_new_time: ic_new_time,
      ic_burst_penalty: ic_burst_penalty,
      ic_held_release_interval: ic_held_release_interval,
      configured_bitrate: configured_bitrate,
      announce_rate_target: announce_rate_target,
      announce_rate_grace: announce_rate_grace,
      announce_rate_penalty: announce_rate_penalty,
      announce_cap: announce_cap,
      bootstrap_only: bootstrap_only,
      outgoing: outgoing,
      discoverable: discoverable,
      discovery_params: discovery_params
    }
  end

  defp extract_discovery_params(c, interface_mode, name) do
    discoverable = get_optional_bool(c, "discoverable", false)

    if discoverable do
      announce_interval =
        if Section.has_key?(c, "announce_interval") do
          v = Section.as_int(c, "announce_interval") * 60
          max(v, 5 * 60)
        else
          6 * 60 * 60
        end

      params = %{
        discovery_announce_interval: announce_interval,
        discovery_stamp_value: get_optional_int_raw(c, "discovery_stamp_value"),
        discovery_name: get_optional_string(c, "discovery_name"),
        discovery_encrypt: get_optional_bool(c, "discovery_encrypt", false),
        reachable_on: get_optional_string(c, "reachable_on"),
        publish_ifac: get_optional_bool(c, "publish_ifac", false),
        latitude: get_optional_float_raw(c, "latitude"),
        longitude: get_optional_float_raw(c, "longitude"),
        height: get_optional_float_raw(c, "height"),
        discovery_frequency: get_optional_int_raw(c, "discovery_frequency"),
        discovery_bandwidth: get_optional_int_raw(c, "discovery_bandwidth"),
        discovery_modulation: get_optional_int_raw(c, "discovery_modulation")
      }

      # Auto-configure mode for discoverable interfaces
      interface_mode =
        if interface_mode not in [Interface.mode_gateway(), Interface.mode_access_point()] do
          iface_type = get_optional_string(c, "type")

          if iface_type in ["RNodeInterface", "RNodeMultiInterface"] do
            Logger.notice(
              "Discovery enabled on interface #{name} without gateway or AP mode. Auto-configured to AP mode."
            )

            Interface.mode_access_point()
          else
            Logger.notice(
              "Discovery enabled on interface #{name} without gateway or AP mode. Auto-configured to gateway mode."
            )

            Interface.mode_gateway()
          end
        else
          interface_mode
        end

      {true, params, interface_mode}
    else
      {false, %{}, interface_mode}
    end
  end

  defp start_interface_by_type(c, name, params, state) do
    type = Section.get(c, "type")

    # Build base opts from config section for the interface
    opts = config_section_to_opts(c, name, params)

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

  @doc false
  def config_section_to_opts(c, name, params) do
    # Build keyword list from config section scalars
    opts = [name: name]

    # Add configured_bitrate and interface mode into opts so
    # interfaces that need them can read them
    opts =
      if params.configured_bitrate,
        do: Keyword.put(opts, :configured_bitrate, params.configured_bitrate),
        else: opts

    # Copy all scalar config values as keyword opts
    Section.keys(c)
    |> Enum.reduce(opts, fn key, acc ->
      value = Section.get(c, key)

      # Convert string keys to atoms for known interface config keys
      atom_key = config_key_to_atom(key)

      if atom_key do
        # Coerce known integer fields from strings
        value = coerce_config_value(atom_key, value)
        Keyword.put(acc, atom_key, value)
      else
        acc
      end
    end)
  end

  # Integer config fields that need type coercion from string
  @integer_config_keys MapSet.new([
                         :port,
                         :listen_port,
                         :bind_port,
                         :forward_port,
                         :target_port,
                         :speed,
                         :databits,
                         :stopbits,
                         :data_port,
                         :discovery_port,
                         :connect_timeout,
                         :max_reconnect_tries,
                         :respawn_delay,
                         :frequency,
                         :bandwidth,
                         :txpower,
                         :spreadingfactor,
                         :codingrate,
                         :id_interval,
                         :ifac_size
                       ])

  @bool_config_keys MapSet.new([
                      :kiss_framing,
                      :i2p_tunneled,
                      :prefer_ipv6,
                      :flow_control,
                      :enabled,
                      :interface_enabled
                    ])

  defp coerce_config_value(key, value) when is_binary(value) do
    cond do
      MapSet.member?(@integer_config_keys, key) ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> value
        end

      MapSet.member?(@bool_config_keys, key) ->
        String.downcase(value) in ["yes", "true", "on", "1"]

      true ->
        value
    end
  end

  defp coerce_config_value(_key, value), do: value

  # Maps config file keys to keyword option atoms for interface constructors
  defp config_key_to_atom(key) do
    mapping = %{
      "type" => :type,
      "enabled" => :enabled,
      "interface_enabled" => :interface_enabled,
      "port" => :port,
      "listen_port" => :listen_port,
      "listen_ip" => :listen_ip,
      "bind_ip" => :bind_ip,
      "bind_port" => :bind_port,
      "forward_ip" => :forward_ip,
      "forward_port" => :forward_port,
      "target_host" => :target_host,
      "target_port" => :target_port,
      "remote" => :target_host,
      "listen_on" => :listen_ip,
      "device" => :device,
      "speed" => :speed,
      "databits" => :databits,
      "parity" => :parity,
      "stopbits" => :stopbits,
      "command" => :command,
      "respawn_delay" => :respawn_delay,
      "kiss_framing" => :kiss_framing,
      "i2p_tunneled" => :i2p_tunneled,
      "prefer_ipv6" => :prefer_ipv6,
      "group_id" => :group_id,
      "discovery_scope" => :discovery_scope,
      "discovery_port" => :discovery_port,
      "multicast_address_type" => :multicast_address_type,
      "data_port" => :data_port,
      "allowed_interfaces" => :allowed_interfaces,
      "ignored_interfaces" => :ignored_interfaces,
      "connect_timeout" => :connect_timeout,
      "max_reconnect_tries" => :max_reconnect_tries,
      "frequency" => :frequency,
      "bandwidth" => :bandwidth,
      "txpower" => :txpower,
      "spreadingfactor" => :spreadingfactor,
      "codingrate" => :codingrate,
      "flow_control" => :flow_control,
      "id_callsign" => :id_callsign,
      "id_interval" => :id_interval,
      "storagepath" => :storagepath,
      "ifac_netname" => :ifac_netname,
      "ifac_netkey" => :ifac_netkey,
      "ifac_size" => :ifac_size,
      "networkname" => :networkname,
      "passphrase" => :passphrase
    }

    Map.get(mapping, key)
  end

  defp apply_interface_post_init(pid, params, state) when is_pid(pid) do
    # Build updates to send to the interface process
    updates = build_post_init_updates(params, state)
    send(pid, {:apply_config, updates})
    :ok
  end

  defp apply_interface_post_init(_pid, _params, _state), do: :ok

  @doc false
  def build_post_init_updates(params, _state) do
    updates = %{}

    updates = Map.put(updates, :out, Map.get(params, :outgoing, true))
    updates = Map.put(updates, :mode, Map.get(params, :interface_mode, Interface.mode_full()))
    updates = Map.put(updates, :announce_cap, Map.get(params, :announce_cap))
    updates = Map.put(updates, :bootstrap_only, Map.get(params, :bootstrap_only, false))

    updates =
      if params[:configured_bitrate],
        do: Map.put(updates, :bitrate, params.configured_bitrate),
        else: updates

    # IFAC settings
    updates =
      if params[:ifac_size],
        do: Map.put(updates, :ifac_size, params.ifac_size),
        else: updates

    # Announce rate limiting
    updates =
      updates
      |> maybe_put(:announce_rate_target, params[:announce_rate_target])
      |> maybe_put(:announce_rate_grace, params[:announce_rate_grace])
      |> maybe_put(:announce_rate_penalty, params[:announce_rate_penalty])

    # Ingress control
    updates = Map.put(updates, :ingress_control, Map.get(params, :ingress_control, true))

    updates =
      updates
      |> maybe_put(:ic_max_held_announces, params[:ic_max_held_announces])
      |> maybe_put(:ic_burst_hold, params[:ic_burst_hold])
      |> maybe_put(:ic_burst_freq_new, params[:ic_burst_freq_new])
      |> maybe_put(:ic_burst_freq, params[:ic_burst_freq])
      |> maybe_put(:ic_new_time, params[:ic_new_time])
      |> maybe_put(:ic_burst_penalty, params[:ic_burst_penalty])
      |> maybe_put(:ic_held_release_interval, params[:ic_held_release_interval])

    # Discovery settings
    updates = Map.put(updates, :discoverable, Map.get(params, :discoverable, false))

    updates =
      if params[:discovery_params] do
        dp = params.discovery_params

        updates
        |> maybe_put(:discovery_announce_interval, dp[:discovery_announce_interval])
        |> maybe_put(:discovery_stamp_value, dp[:discovery_stamp_value])
        |> maybe_put(:discovery_name, dp[:discovery_name])
        |> maybe_put(:discovery_encrypt, dp[:discovery_encrypt])
        |> maybe_put(:reachable_on, dp[:reachable_on])
        |> maybe_put(:discovery_publish_ifac, dp[:publish_ifac])
        |> maybe_put(:discovery_latitude, dp[:latitude])
        |> maybe_put(:discovery_longitude, dp[:longitude])
        |> maybe_put(:discovery_height, dp[:height])
        |> maybe_put(:discovery_frequency, dp[:discovery_frequency])
        |> maybe_put(:discovery_bandwidth, dp[:discovery_bandwidth])
        |> maybe_put(:discovery_modulation, dp[:discovery_modulation])
      else
        updates
      end

    # IFAC network identity computation
    ifac_netname = params[:ifac_netname]
    ifac_netkey = params[:ifac_netkey]

    updates = Map.put(updates, :ifac_netname, ifac_netname)
    updates = Map.put(updates, :ifac_netkey, ifac_netkey)

    if ifac_netname != nil or ifac_netkey != nil do
      ifac_origin = <<>>

      ifac_origin =
        if ifac_netname != nil do
          ifac_origin <> RNS.Identity.full_hash(ifac_netname)
        else
          ifac_origin
        end

      ifac_origin =
        if ifac_netkey != nil do
          ifac_origin <> RNS.Identity.full_hash(ifac_netkey)
        else
          ifac_origin
        end

      ifac_origin_hash = RNS.Identity.full_hash(ifac_origin)

      ifac_key =
        RNS.Cryptography.HKDF.derive_key(
          ifac_origin_hash,
          64,
          @ifac_salt,
          nil
        )

      ifac_identity = RNS.Identity.from_bytes(ifac_key)
      ifac_signature = RNS.Identity.sign(ifac_identity, RNS.Identity.full_hash(ifac_key))

      updates
      |> Map.put(:ifac_key, ifac_key)
      |> Map.put(:ifac_identity, ifac_identity)
      |> Map.put(:ifac_signature, ifac_signature)
    else
      updates
    end
  end

  defp detach_all_interfaces(state) do
    # Get all interfaces from Transport and detach them
    interfaces =
      try do
        RNS.Transport.get_interfaces()
      rescue
        _ -> []
      end

    for interface <- interfaces do
      try do
        if is_map(interface) and Map.has_key?(interface, :pid) and is_pid(interface.pid) do
          send(interface.pid, :detach)
        end
      rescue
        _ -> :ok
      end
    end

    # Also stop any interfaces we directly started
    for pid <- Map.get(state, :started_interfaces, []) do
      try do
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(RNS.InterfaceSupervisor, pid)
        end
      rescue
        _ -> :ok
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

  @doc false
  def apply_logging_config(config, state, requested_loglevel, requested_verbosity) do
    if Section.has_key?(config, "logging") do
      logging_section = Section.get(config, "logging")

      if Section.has_key?(logging_section, "loglevel") and requested_loglevel == nil do
        loglevel = Section.as_int(logging_section, "loglevel")

        loglevel =
          if requested_verbosity != nil do
            loglevel + requested_verbosity
          else
            loglevel
          end

        loglevel = max(0, min(7, loglevel))

        # Map RNS log levels to Elixir Logger levels
        _logger_level =
          case loglevel do
            0 -> :emergency
            1 -> :error
            2 -> :warning
            3 -> :notice
            4 -> :info
            5 -> :info
            6 -> :debug
            7 -> :debug
          end

        Map.put(state, :loglevel, loglevel)
      else
        state
      end
    else
      state
    end
  end

  @doc false
  def apply_reticulum_config(config, state) do
    if Section.has_key?(config, "reticulum") do
      ret_section = Section.get(config, "reticulum")

      state
      |> apply_bool_option(ret_section, "share_instance", :share_instance)
      |> apply_socket_path_option(ret_section)
      |> apply_shared_instance_type(ret_section)
      |> apply_int_option(ret_section, "shared_instance_port", :local_interface_port)
      |> apply_int_option(ret_section, "instance_control_port", :local_control_port)
      |> apply_rpc_key(ret_section)
      |> apply_bool_option_true_only(ret_section, "enable_transport", :transport_enabled)
      |> apply_network_identity(ret_section)
      |> apply_bool_option(ret_section, "link_mtu_discovery", :link_mtu_discovery)
      |> apply_bool_option_true_only(
        ret_section,
        "enable_remote_management",
        :remote_management_enabled
      )
      |> apply_remote_management_allowed(ret_section)
      |> apply_bool_option_true_only(ret_section, "respond_to_probes", :allow_probes)
      |> apply_force_shared_instance_bitrate(ret_section)
      |> apply_bool_option_true_only(
        ret_section,
        "panic_on_interface_error",
        :panic_on_interface_error
      )
      |> apply_bool_option(ret_section, "use_implicit_proof", :use_implicit_proof)
      |> apply_bool_option(ret_section, "discover_interfaces", :discover_interfaces)
      |> apply_required_discovery_value(ret_section)
      |> apply_bool_option(ret_section, "publish_blackhole", :publish_blackhole)
      |> apply_hash_list_option(ret_section, "blackhole_sources", :blackhole_sources)
      |> apply_hash_list_option(ret_section, "interface_discovery_sources", :interface_sources)
      |> apply_autoconnect_discovered(ret_section)
    else
      state
    end
  end

  defp apply_bool_option(state, section, key, field) do
    if Section.has_key?(section, key) do
      Map.put(state, field, Section.as_bool(section, key))
    else
      state
    end
  end

  defp apply_bool_option_true_only(state, section, key, field) do
    if Section.has_key?(section, key) do
      if Section.as_bool(section, key) do
        Map.put(state, field, true)
      else
        state
      end
    else
      state
    end
  end

  defp apply_int_option(state, section, key, field) do
    if Section.has_key?(section, key) do
      Map.put(state, field, Section.as_int(section, key))
    else
      state
    end
  end

  defp apply_socket_path_option(state, section) do
    if RNS.Vendor.PlatformUtils.use_af_unix?() do
      if Section.has_key?(section, "instance_name") do
        Map.put(state, :local_socket_path, Section.get(section, "instance_name"))
      else
        state
      end
    else
      state
    end
  end

  defp apply_shared_instance_type(state, section) do
    if Section.has_key?(section, "shared_instance_type") and state.shared_instance_type == nil do
      value = Section.get(section, "shared_instance_type") |> String.downcase()

      if value in ["tcp", "unix"] do
        Map.put(state, :shared_instance_type, value)
      else
        state
      end
    else
      state
    end
  end

  defp apply_rpc_key(state, section) do
    if Section.has_key?(section, "rpc_key") do
      hex_value = Section.get(section, "rpc_key")

      case Base.decode16(hex_value, case: :mixed) do
        {:ok, key_bytes} ->
          Map.put(state, :rpc_key, key_bytes)

        :error ->
          Logger.error("Invalid shared instance RPC key specified, falling back to default key")
          state
      end
    else
      state
    end
  end

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

  defp apply_remote_management_allowed(state, section) do
    if Section.has_key?(section, "remote_management_allowed") do
      hex_list = Section.as_list(section, "remote_management_allowed")
      dest_len = div(@truncated_hashlength, 8) * 2

      hashes =
        for hexhash <- hex_list do
          hexhash = String.trim(hexhash)

          if String.length(hexhash) != dest_len do
            raise "Identity hash length for remote management ACL #{hexhash} is invalid, must be #{dest_len} hexadecimal characters (#{div(dest_len, 2)} bytes)."
          end

          case Base.decode16(hexhash, case: :mixed) do
            {:ok, hash} -> hash
            :error -> raise "Invalid identity hash for remote management ACL: #{hexhash}"
          end
        end

      Map.put(state, :remote_management_allowed, hashes)
    else
      state
    end
  end

  defp apply_force_shared_instance_bitrate(state, section) do
    if Section.has_key?(section, "force_shared_instance_bitrate") do
      Map.put(
        state,
        :force_shared_instance_bitrate,
        Section.as_int(section, "force_shared_instance_bitrate")
      )
    else
      state
    end
  end

  defp apply_required_discovery_value(state, section) do
    if Section.has_key?(section, "required_discovery_value") do
      v = Section.as_int(section, "required_discovery_value")

      if v > 0 do
        Map.put(state, :required_discovery_value, v)
      else
        Map.put(state, :required_discovery_value, nil)
      end
    else
      state
    end
  end

  defp apply_hash_list_option(state, section, key, field) do
    if Section.has_key?(section, key) do
      hex_list = Section.as_list(section, key)
      dest_len = div(@truncated_hashlength, 8) * 2

      hashes =
        for hexhash <- hex_list do
          hexhash = String.trim(hexhash)

          if String.length(hexhash) != dest_len do
            raise "Identity hash length for #{key} #{hexhash} is invalid, must be #{dest_len} hexadecimal characters (#{div(dest_len, 2)} bytes)."
          end

          case Base.decode16(hexhash, case: :mixed) do
            {:ok, hash} -> hash
            :error -> raise "Invalid identity hash for #{key}: #{hexhash}"
          end
        end

      existing = Map.get(state, field, [])
      combined = Enum.uniq(existing ++ hashes)
      Map.put(state, field, combined)
    else
      state
    end
  end

  defp apply_autoconnect_discovered(state, section) do
    if Section.has_key?(section, "autoconnect_discovered_interfaces") do
      v = Section.as_int(section, "autoconnect_discovered_interfaces")

      if v > 0 do
        Map.put(state, :autoconnect_discovered_interfaces, v)
      else
        state
      end
    else
      state
    end
  end

  # ── Config Extraction Helpers ────────────────────────────────────────

  defp get_optional_bool(c, key, default) do
    if Section.has_key?(c, key), do: Section.as_bool(c, key), else: default
  end

  defp get_optional_int(c, key, validator) do
    if Section.has_key?(c, key) do
      v = Section.as_int(c, key)
      validator.(v)
    else
      nil
    end
  end

  defp get_optional_int_raw(c, key) do
    if Section.has_key?(c, key), do: Section.as_int(c, key), else: nil
  end

  defp get_optional_float_raw(c, key) do
    if Section.has_key?(c, key), do: Section.as_float(c, key), else: nil
  end

  defp get_optional_string(c, key) do
    if Section.has_key?(c, key), do: Section.get(c, key), else: nil
  end

  defp get_nonempty_string(c, key) do
    if Section.has_key?(c, key) do
      v = Section.get(c, key)
      if is_binary(v) and v != "", do: v, else: nil
    else
      nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
