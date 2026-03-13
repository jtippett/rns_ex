defmodule RNS.Reticulum.Config do
  @moduledoc """
  Pure configuration parsing and application for Reticulum.

  All functions in this module are pure data transformations — no GenServer
  calls, no ETS access, no process messaging. This allows config parsing
  and application logic to be tested without starting the supervision tree.

  The one exception is `determine_configdir/1` (nil clause), which probes
  the filesystem to auto-detect the config directory. All other functions
  operate solely on their inputs.
  """

  require Logger

  alias RNS.Interfaces.Interface
  alias RNS.Vendor.ConfigObj.Section

  # ── Protocol Constants ─────────────────────────────────────────────────
  # Duplicated from RNS.Reticulum for self-containment (these are protocol
  # constants that must match Python exactly and never change).

  @ifac_min_size 1
  @ifac_salt Base.decode16!(
               "ADF54D882C9A9B80771EB4995D702D4A3E733391B2A0F53F416D9F907E55CFF8",
               case: :upper
             )
  @minimum_bitrate 5
  @announce_cap 2
  @truncated_hashlength 128
  @link_mtu_discovery true
  @default_local_interface_port 37_428
  @default_local_control_port 37_429

  # ── Config Key Mappings ────────────────────────────────────────────────

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

  # ── Path Computation ───────────────────────────────────────────────────

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

  # ── Config Application ─────────────────────────────────────────────────

  @doc """
  Applies configuration from a parsed config Section.

  Returns a map of configuration values. Does NOT apply network identity
  (which requires File IO) — the caller must handle that separately.
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
      network_identity: nil,
      loglevel: 4
    }

    state = apply_logging_config(config, state, requested_loglevel, requested_verbosity)
    apply_reticulum_config(config, state)
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
      # NOTE: apply_network_identity is NOT called here — it requires File IO.
      # The caller (RNS.Reticulum) applies it separately.
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

  # ── Interface Config Extraction ────────────────────────────────────────

  @doc """
  Extracts interface parameters from a config section.

  Returns a map of interface configuration values including mode, IFAC settings,
  bitrate, announce rate limiting, ingress control, and discovery parameters.
  """
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

  @doc """
  Extracts discovery parameters from a config section.

  Returns `{discoverable, discovery_params, interface_mode}`.
  """
  def extract_discovery_params(c, interface_mode, name) do
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
        if interface_mode in [Interface.mode_gateway(), Interface.mode_access_point()] do
          interface_mode
        else
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
        end

      {true, params, interface_mode}
    else
      {false, %{}, interface_mode}
    end
  end

  @doc """
  Checks if a config section specifies an interface mode.
  """
  def has_interface_mode_config?(c) do
    Section.has_key?(c, "interface_mode") or Section.has_key?(c, "mode")
  end

  @doc """
  Parses the interface mode from a config section.
  """
  def parse_interface_mode(c) do
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

  # ── Config Section to Opts ─────────────────────────────────────────────

  @doc """
  Converts a config section into a keyword list of interface options.
  """
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

  @doc """
  Coerces a config value to the appropriate type based on the key.
  """
  def coerce_config_value(key, value) when is_binary(value) do
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

  def coerce_config_value(_key, value), do: value

  @doc """
  Maps config file string keys to keyword option atoms for interface constructors.
  Returns nil for unrecognized keys.
  """
  def config_key_to_atom(key) do
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

  # ── Post-Init Updates ──────────────────────────────────────────────────

  @doc """
  Builds the map of post-init updates to apply to an interface after startup.

  These updates include mode, outgoing flag, IFAC settings, announce rate
  limiting, ingress control, and discovery parameters.
  """
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

  # ── Config Extraction Helpers ──────────────────────────────────────────

  @doc "Reads an optional boolean from a config section, returning `default` if absent."
  def get_optional_bool(c, key, default) do
    if Section.has_key?(c, key), do: Section.as_bool(c, key), else: default
  end

  @doc "Reads an optional integer from a config section, passing through `validator`."
  def get_optional_int(c, key, validator) do
    if Section.has_key?(c, key) do
      v = Section.as_int(c, key)
      validator.(v)
    else
      nil
    end
  end

  @doc "Reads an optional integer from a config section, returning nil if absent."
  def get_optional_int_raw(c, key) do
    if Section.has_key?(c, key), do: Section.as_int(c, key), else: nil
  end

  @doc "Reads an optional float from a config section, returning nil if absent."
  def get_optional_float_raw(c, key) do
    if Section.has_key?(c, key), do: Section.as_float(c, key), else: nil
  end

  @doc "Reads an optional string from a config section, returning nil if absent."
  def get_optional_string(c, key) do
    if Section.has_key?(c, key), do: Section.get(c, key), else: nil
  end

  @doc "Reads a non-empty string from a config section, returning nil if absent or empty."
  def get_nonempty_string(c, key) do
    if Section.has_key?(c, key) do
      v = Section.get(c, key)
      if is_binary(v) and v != "", do: v, else: nil
    else
      nil
    end
  end

  @doc "Puts a value into a map only if the value is not nil."
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Apply Config Helpers ───────────────────────────────────────────────

  @doc false
  def apply_bool_option(state, section, key, field) do
    if Section.has_key?(section, key) do
      Map.put(state, field, Section.as_bool(section, key))
    else
      state
    end
  end

  @doc false
  def apply_bool_option_true_only(state, section, key, field) do
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

  @doc false
  def apply_int_option(state, section, key, field) do
    if Section.has_key?(section, key) do
      Map.put(state, field, Section.as_int(section, key))
    else
      state
    end
  end

  @doc false
  def apply_socket_path_option(state, section) do
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

  @doc false
  def apply_shared_instance_type(state, section) do
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

  @doc false
  def apply_rpc_key(state, section) do
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

  @doc false
  def apply_remote_management_allowed(state, section) do
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

  @doc false
  def apply_force_shared_instance_bitrate(state, section) do
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

  @doc false
  def apply_required_discovery_value(state, section) do
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

  @doc false
  def apply_hash_list_option(state, section, key, field) do
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

  @doc false
  def apply_autoconnect_discovered(state, section) do
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
end
