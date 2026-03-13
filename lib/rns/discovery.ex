defmodule RNS.Discovery do
  @moduledoc """
  Interface discovery, announce handling, and blackhole management for the
  Reticulum Network Stack.

  This module provides:
  - `InterfaceAnnouncer` — creates and sends discovery announces
  - `InterfaceAnnounceHandler` — receives and processes discovery announces
  - `InterfaceDiscovery` — coordinates discovery across interfaces
  - `BlackholeUpdater` — network blackhole detection and distribution
  """

  # ── Field identifier constants (matching Python's module-level constants) ──

  @name 0xFF
  @transport_id 0xFE
  @interface_type 0x00
  @transport 0x01
  @reachable_on 0x02
  @latitude 0x03
  @longitude 0x04
  @height 0x05
  @port 0x06
  @ifac_netname 0x07
  @ifac_netkey 0x08
  @frequency 0x09
  @bandwidth 0x0A
  @spreading_factor 0x0B
  @coding_rate 0x0C
  @modulation 0x0D
  @channel 0x0E

  @app_name "rnstransport"

  @doc "Field identifier for interface name."
  @spec name_field() :: non_neg_integer()
  def name_field, do: @name

  @doc "Field identifier for transport identity hash."
  @spec transport_id_field() :: non_neg_integer()
  def transport_id_field, do: @transport_id

  @doc "Field identifier for interface type."
  @spec interface_type_field() :: non_neg_integer()
  def interface_type_field, do: @interface_type

  @doc "Field identifier for transport enabled flag."
  @spec transport_field() :: non_neg_integer()
  def transport_field, do: @transport

  @doc "Field identifier for reachable address."
  @spec reachable_on_field() :: non_neg_integer()
  def reachable_on_field, do: @reachable_on

  @doc "Field identifier for latitude."
  @spec latitude_field() :: non_neg_integer()
  def latitude_field, do: @latitude

  @doc "Field identifier for longitude."
  @spec longitude_field() :: non_neg_integer()
  def longitude_field, do: @longitude

  @doc "Field identifier for height."
  @spec height_field() :: non_neg_integer()
  def height_field, do: @height

  @doc "Field identifier for port."
  @spec port_field() :: non_neg_integer()
  def port_field, do: @port

  @doc "Field identifier for IFAC network name."
  @spec ifac_netname_field() :: non_neg_integer()
  def ifac_netname_field, do: @ifac_netname

  @doc "Field identifier for IFAC network key."
  @spec ifac_netkey_field() :: non_neg_integer()
  def ifac_netkey_field, do: @ifac_netkey

  @doc "Field identifier for frequency."
  @spec frequency_field() :: non_neg_integer()
  def frequency_field, do: @frequency

  @doc "Field identifier for bandwidth."
  @spec bandwidth_field() :: non_neg_integer()
  def bandwidth_field, do: @bandwidth

  @doc "Field identifier for spreading factor."
  @spec spreading_factor_field() :: non_neg_integer()
  def spreading_factor_field, do: @spreading_factor

  @doc "Field identifier for coding rate."
  @spec coding_rate_field() :: non_neg_integer()
  def coding_rate_field, do: @coding_rate

  @doc "Field identifier for modulation type."
  @spec modulation_field() :: non_neg_integer()
  def modulation_field, do: @modulation

  @doc "Field identifier for channel."
  @spec channel_field() :: non_neg_integer()
  def channel_field, do: @channel

  @doc "The application name used for discovery destinations."
  @spec app_name() :: String.t()
  def app_name, do: @app_name

  # ── Helper Functions ──────────────────────────────────────────────────

  @doc """
  Returns true if the given string is a valid IP address (IPv4 or IPv6).
  """
  @spec is_ip_address(String.t()) :: boolean()
  def is_ip_address(address_string) do
    case :inet.parse_address(String.to_charlist(address_string)) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Returns true if the given string is a valid hostname.

  Matching Python's `is_hostname`:
  - Strips trailing dot
  - Max 253 characters
  - Last component must not be all digits
  - Each label: 1-63 chars, alphanumeric + hyphen, no leading/trailing hyphen
  """
  @spec is_hostname(String.t()) :: boolean()
  def is_hostname(""), do: false

  def is_hostname(hostname) do
    hostname =
      if String.ends_with?(hostname, "."), do: String.slice(hostname, 0..-2//1), else: hostname

    if String.length(hostname) > 253 do
      false
    else
      components = String.split(hostname, ".")
      last = List.last(components)

      if Regex.match?(~r/^[0-9]+$/, last) do
        false
      else
        allowed = ~r/^(?!-)[a-zA-Z0-9-]{1,63}(?<!-)$/
        Enum.all?(components, &Regex.match?(allowed, &1))
      end
    end
  end

  @doc """
  Sanitizes a string by removing newlines, carriage returns, and trimming whitespace.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(str) do
    str
    |> String.replace("\n", "")
    |> String.replace("\r", "")
    |> String.trim()
  end
end

defmodule RNS.Discovery.InterfaceAnnounceHandler do
  @moduledoc """
  Handles received interface discovery announces.

  Validates stamp proofs, decodes announce data, and generates
  config entries for discovered interfaces.
  """

  alias RNS.Discovery

  @flag_signed 0b00000001
  @flag_encrypted 0b00000010

  # LXStamper stamp size (32 bytes)
  @stamp_size 32

  defstruct [
    :aspect_filter,
    :required_value,
    :callback,
    :stamper
  ]

  @type t :: %__MODULE__{
          aspect_filter: String.t(),
          required_value: non_neg_integer(),
          callback: (map() -> any()) | nil,
          stamper: module() | nil
        }

  @doc "Returns the FLAG_SIGNED constant."
  @spec flag_signed() :: non_neg_integer()
  def flag_signed, do: @flag_signed

  @doc "Returns the FLAG_ENCRYPTED constant."
  @spec flag_encrypted() :: non_neg_integer()
  def flag_encrypted, do: @flag_encrypted

  @doc """
  Creates a new InterfaceAnnounceHandler.

  ## Options
  - `:required_value` — minimum stamp value required (default: 14)
  - `:callback` — function called with interface info on valid announce
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      aspect_filter: Discovery.app_name() <> ".discovery.interface",
      required_value:
        Keyword.get(opts, :required_value, RNS.Discovery.InterfaceAnnouncer.default_stamp_value()),
      callback: Keyword.get(opts, :callback),
      stamper: nil
    }
  end

  @doc """
  Decodes announce data from a received discovery announce.

  Returns the decoded interface info map, or nil if invalid.
  """
  @spec decode_announce_data(t(), binary() | nil) :: map() | nil
  def decode_announce_data(_handler, nil), do: nil

  def decode_announce_data(_handler, app_data) when byte_size(app_data) <= @stamp_size + 1,
    do: nil

  def decode_announce_data(_handler, _app_data) do
    # Full stamp validation requires LXStamper (LXMF module).
    # This is a stub that returns nil — the actual stamp validation
    # would require the LXMF dependency which is not part of RNS core.
    nil
  end

  @doc """
  Parses unpacked msgpack data into an interface info map.

  This is the core logic for extracting interface details and generating
  config entries, separated from stamp validation for testability.
  """
  @spec parse_interface_info(map(), String.t(), non_neg_integer(), integer()) :: map() | nil
  def parse_interface_info(unpacked, network_id_hex, hops, received_at) do
    if Map.has_key?(unpacked, Discovery.interface_type_field()) do
      interface_type = unpacked[Discovery.interface_type_field()]
      transport_id = unpacked[Discovery.transport_id_field()]
      transport_id_hex = RNS.hexrep(transport_id, false)

      info = %{
        "type" => interface_type,
        "transport" => unpacked[Discovery.transport_field()],
        "name" => unpacked[Discovery.name_field()] || "Discovered #{interface_type}",
        "received" => received_at,
        "transport_id" => transport_id_hex,
        "network_id" => network_id_hex,
        "hops" => hops,
        "latitude" => unpacked[Discovery.latitude_field()],
        "longitude" => unpacked[Discovery.longitude_field()],
        "height" => unpacked[Discovery.height_field()]
      }

      # Validate reachable_on if present
      if Map.has_key?(unpacked, Discovery.reachable_on_field()) do
        reachable = unpacked[Discovery.reachable_on_field()]

        unless Discovery.is_ip_address(reachable) or Discovery.is_hostname(reachable) do
          raise "Invalid data in reachable_on field of announce"
        end
      end

      # Add IFAC info if present
      info =
        if Map.has_key?(unpacked, Discovery.ifac_netname_field()) do
          Map.put(info, "ifac_netname", unpacked[Discovery.ifac_netname_field()])
        else
          info
        end

      info =
        if Map.has_key?(unpacked, Discovery.ifac_netkey_field()) do
          Map.put(info, "ifac_netkey", unpacked[Discovery.ifac_netkey_field()])
        else
          info
        end

      # Generate config entry based on interface type
      info = add_type_specific_info(info, unpacked, interface_type)

      # Compute discovery hash
      discovery_hash_material = info["transport_id"] <> info["name"]
      discovery_hash = RNS.Identity.full_hash(discovery_hash_material)
      Map.put(info, "discovery_hash", discovery_hash)
    else
      nil
    end
  end

  defp add_type_specific_info(info, unpacked, type)
       when type in ["BackboneInterface", "TCPServerInterface"] do
    backbone_support = not RNS.Vendor.PlatformUtils.is_windows?()
    reachable_on = unpacked[Discovery.reachable_on_field()]
    port = unpacked[Discovery.port_field()]

    info =
      info
      |> Map.put("reachable_on", reachable_on)
      |> Map.put("port", port)

    connection_interface =
      if backbone_support, do: "BackboneInterface", else: "TCPClientInterface"

    remote_str = if backbone_support, do: "remote", else: "target_host"

    cfg_name = info["name"]
    cfg_remote = reachable_on
    cfg_port = port
    cfg_identity = info["transport_id"]

    cfg_netname = Map.get(info, "ifac_netname")
    cfg_netkey = Map.get(info, "ifac_netkey")
    cfg_netname_str = if cfg_netname, do: "\n  network_name = #{cfg_netname}", else: ""
    cfg_netkey_str = if cfg_netkey, do: "\n  passphrase = #{cfg_netkey}", else: ""
    cfg_identity_str = "\n  transport_identity = #{cfg_identity}"

    config_entry =
      "[[#{cfg_name}]]\n  type = #{connection_interface}\n  enabled = yes\n  #{remote_str} = #{cfg_remote}\n  target_port = #{cfg_port}#{cfg_identity_str}#{cfg_netname_str}#{cfg_netkey_str}"

    Map.put(info, "config_entry", config_entry)
  end

  defp add_type_specific_info(info, unpacked, "I2PInterface") do
    reachable_on = unpacked[Discovery.reachable_on_field()]
    info = Map.put(info, "reachable_on", reachable_on)

    cfg_name = info["name"]
    cfg_remote = reachable_on
    cfg_identity = info["transport_id"]

    cfg_netname = Map.get(info, "ifac_netname")
    cfg_netkey = Map.get(info, "ifac_netkey")
    cfg_netname_str = if cfg_netname, do: "\n  network_name = #{cfg_netname}", else: ""
    cfg_netkey_str = if cfg_netkey, do: "\n  passphrase = #{cfg_netkey}", else: ""
    cfg_identity_str = "\n  transport_identity = #{cfg_identity}"

    config_entry =
      "[[#{cfg_name}]]\n  type = I2PInterface\n  enabled = yes\n  peers = #{cfg_remote}#{cfg_identity_str}#{cfg_netname_str}#{cfg_netkey_str}"

    Map.put(info, "config_entry", config_entry)
  end

  defp add_type_specific_info(info, unpacked, "RNodeInterface") do
    frequency = unpacked[Discovery.frequency_field()]
    bandwidth = unpacked[Discovery.bandwidth_field()]
    sf = unpacked[Discovery.spreading_factor_field()]
    cr = unpacked[Discovery.coding_rate_field()]

    info =
      info
      |> Map.put("frequency", frequency)
      |> Map.put("bandwidth", bandwidth)
      |> Map.put("sf", sf)
      |> Map.put("cr", cr)

    cfg_name = info["name"]
    cfg_identity = info["transport_id"]

    cfg_netname = Map.get(info, "ifac_netname")
    cfg_netkey = Map.get(info, "ifac_netkey")
    cfg_netname_str = if cfg_netname, do: "\n  network_name = #{cfg_netname}", else: ""
    cfg_netkey_str = if cfg_netkey, do: "\n  passphrase = #{cfg_netkey}", else: ""
    cfg_identity_str = "\n  transport_identity = #{cfg_identity}"

    config_entry =
      "[[#{cfg_name}]]\n  type = RNodeInterface\n  enabled = yes\n  port = \n  frequency = #{frequency}\n  bandwidth = #{bandwidth}\n  spreadingfactor = #{sf}\n  codingrate = #{cr}\n  txpower = #{cfg_netname_str}#{cfg_netkey_str}"

    info
    |> Map.put("config_entry", config_entry)
    |> Map.put("transport_identity", cfg_identity_str)
  end

  defp add_type_specific_info(info, unpacked, "WeaveInterface") do
    frequency = unpacked[Discovery.frequency_field()]
    bandwidth = unpacked[Discovery.bandwidth_field()]
    channel = unpacked[Discovery.channel_field()]
    modulation = unpacked[Discovery.modulation_field()]

    info =
      info
      |> Map.put("frequency", frequency)
      |> Map.put("bandwidth", bandwidth)
      |> Map.put("channel", channel)
      |> Map.put("modulation", modulation)

    cfg_name = info["name"]

    cfg_netname = Map.get(info, "ifac_netname")
    cfg_netkey = Map.get(info, "ifac_netkey")
    cfg_netname_str = if cfg_netname, do: "\n  network_name = #{cfg_netname}", else: ""
    cfg_netkey_str = if cfg_netkey, do: "\n  passphrase = #{cfg_netkey}", else: ""

    config_entry =
      "[[#{cfg_name}]]\n  type = WeaveInterface\n  enabled = yes\n  port = #{cfg_netname_str}#{cfg_netkey_str}"

    Map.put(info, "config_entry", config_entry)
  end

  defp add_type_specific_info(info, unpacked, "KISSInterface") do
    frequency = unpacked[Discovery.frequency_field()]
    bandwidth = unpacked[Discovery.bandwidth_field()]
    modulation = unpacked[Discovery.modulation_field()]

    info =
      info
      |> Map.put("frequency", frequency)
      |> Map.put("bandwidth", bandwidth)
      |> Map.put("modulation", modulation)

    cfg_name = info["name"]
    cfg_frequency = frequency
    cfg_bandwidth = bandwidth
    cfg_modulation = modulation
    cfg_identity = info["transport_id"]

    cfg_netname = Map.get(info, "ifac_netname")
    cfg_netkey = Map.get(info, "ifac_netkey")
    cfg_netname_str = if cfg_netname, do: "\n  network_name = #{cfg_netname}", else: ""
    cfg_netkey_str = if cfg_netkey, do: "\n  passphrase = #{cfg_netkey}", else: ""
    cfg_identity_str = "\n  transport_identity = #{cfg_identity}"

    config_entry =
      "[[#{cfg_name}]]\n  type = KISSInterface\n  enabled = yes\n  port = \n  # Frequency: #{cfg_frequency}\n  # Bandwidth: #{cfg_bandwidth}\n  # Modulation: #{cfg_modulation}#{cfg_identity_str}#{cfg_netname_str}#{cfg_netkey_str}"

    Map.put(info, "config_entry", config_entry)
  end

  defp add_type_specific_info(info, _unpacked, _type), do: info
end

defmodule RNS.Discovery.InterfaceAnnouncer do
  @moduledoc """
  Creates and sends interface discovery announces.

  Periodically checks for interfaces that are due for a discovery announce,
  builds the announce data, and sends it via the discovery destination.
  """

  alias RNS.Discovery

  @job_interval 60
  @default_stamp_value 14
  @workblock_expand_rounds 20

  @discoverable_interface_types [
    "BackboneInterface",
    "TCPServerInterface",
    "TCPClientInterface",
    "RNodeInterface",
    "WeaveInterface",
    "I2PInterface",
    "KISSInterface"
  ]

  @doc "Returns the job interval in seconds."
  @spec job_interval() :: non_neg_integer()
  def job_interval, do: @job_interval

  @doc "Returns the default stamp value."
  @spec default_stamp_value() :: non_neg_integer()
  def default_stamp_value, do: @default_stamp_value

  @doc "Returns the workblock expand rounds constant."
  @spec workblock_expand_rounds() :: non_neg_integer()
  def workblock_expand_rounds, do: @workblock_expand_rounds

  @doc "Returns the list of interface types that support discovery."
  @spec discoverable_interface_types() :: [String.t()]
  def discoverable_interface_types, do: @discoverable_interface_types

  @doc """
  Builds the interface info map for a given interface.

  Returns nil if the interface type is not discoverable or if
  required data (like reachable_on) is invalid.
  """
  @spec build_interface_info(map(), map()) :: map() | nil
  def build_interface_info(interface, ctx) do
    type_name = get_type_name(interface)

    # Handle TCPClientInterface with kiss_framing
    effective_type =
      if type_name == "TCPClientInterface" and Map.get(interface, :kiss_framing, false) do
        "KISSInterface"
      else
        type_name
      end

    if effective_type in @discoverable_interface_types do
      info = %{
        Discovery.interface_type_field() => effective_type,
        Discovery.transport_field() => ctx.transport_enabled,
        Discovery.transport_id_field() => ctx.transport_identity_hash,
        Discovery.name_field() =>
          Discovery.sanitize(Map.get(interface, :discovery_name, interface.name)),
        Discovery.latitude_field() => Map.get(interface, :discovery_latitude),
        Discovery.longitude_field() => Map.get(interface, :discovery_longitude),
        Discovery.height_field() => Map.get(interface, :discovery_height)
      }

      info = add_type_params(info, interface, effective_type)

      # Return nil if add_type_params returned nil (e.g., invalid reachable_on)
      if info == nil do
        nil
      else
        # Add IFAC info if configured
        if Map.get(interface, :discovery_publish_ifac) == true do
          info
          |> Map.put(
            Discovery.ifac_netname_field(),
            Discovery.sanitize(Map.get(interface, :ifac_netname, ""))
          )
          |> Map.put(
            Discovery.ifac_netkey_field(),
            Discovery.sanitize(Map.get(interface, :ifac_netkey, ""))
          )
        else
          info
        end
      end
    else
      nil
    end
  end

  @doc """
  Builds the full announce payload including stamp.

  Returns `{payload, updated_stamp_cache}` or nil if stamping fails.
  Since LXMF/LXStamper is not available in the core RNS library, this
  is a stub that returns nil.
  """
  @spec get_interface_announce_data(map(), map()) :: {binary(), map()} | nil
  def get_interface_announce_data(interface, ctx) do
    info = build_interface_info(interface, ctx)

    if info == nil do
      nil
    else
      # Stamp generation requires LXMF module (LXStamper).
      # This is a stub — real implementation would:
      # 1. Pack info with Msgpax
      # 2. Compute infohash = Identity.full_hash(packed)
      # 3. Check stamp_cache for existing stamp
      # 4. Generate stamp via LXStamper if not cached
      # 5. Optionally encrypt with network identity
      # 6. Return <<flags>> <> payload
      nil
    end
  end

  defp get_type_name(%{type_name: name}), do: name
  defp get_type_name(%{__struct__: mod}), do: mod |> Module.split() |> List.last()
  defp get_type_name(_), do: "Unknown"

  defp add_type_params(info, interface, type)
       when type in ["BackboneInterface", "TCPServerInterface"] do
    reachable_on = Discovery.sanitize(Map.get(interface, :reachable_on, ""))

    if Discovery.is_ip_address(reachable_on) or Discovery.is_hostname(reachable_on) do
      info
      |> Map.put(Discovery.reachable_on_field(), reachable_on)
      |> Map.put(Discovery.port_field(), Map.get(interface, :bind_port))
    else
      nil
    end
  end

  defp add_type_params(info, interface, "I2PInterface") do
    if Map.get(interface, :connectable) and Map.get(interface, :b32) do
      Map.put(info, Discovery.reachable_on_field(), interface.b32)
    else
      info
    end
  end

  defp add_type_params(info, interface, "RNodeInterface") do
    info
    |> Map.put(Discovery.frequency_field(), interface.frequency)
    |> Map.put(Discovery.bandwidth_field(), interface.bandwidth)
    |> Map.put(Discovery.spreading_factor_field(), interface.sf)
    |> Map.put(Discovery.coding_rate_field(), interface.cr)
  end

  defp add_type_params(info, interface, "WeaveInterface") do
    info
    |> Map.put(Discovery.frequency_field(), Map.get(interface, :discovery_frequency))
    |> Map.put(Discovery.bandwidth_field(), Map.get(interface, :discovery_bandwidth))
    |> Map.put(Discovery.channel_field(), Map.get(interface, :discovery_channel))
    |> Map.put(Discovery.modulation_field(), Map.get(interface, :discovery_modulation))
  end

  defp add_type_params(info, interface, "KISSInterface") do
    info
    |> Map.put(Discovery.frequency_field(), Map.get(interface, :discovery_frequency))
    |> Map.put(Discovery.bandwidth_field(), Map.get(interface, :discovery_bandwidth))
    |> Map.put(
      Discovery.modulation_field(),
      Discovery.sanitize(to_string(Map.get(interface, :discovery_modulation, "")))
    )
  end

  defp add_type_params(info, _interface, _type), do: info
end

defmodule RNS.Discovery.InterfaceDiscovery do
  @moduledoc """
  Coordinates interface discovery across the Reticulum network.

  Maintains a persistent store of discovered interfaces, manages their
  lifecycle (available → unknown → stale → removed), and handles
  auto-connection of discovered interfaces.
  """

  alias RNS.Discovery

  @threshold_unknown 24 * 60 * 60
  @threshold_stale 3 * 24 * 60 * 60
  @threshold_remove 7 * 24 * 60 * 60

  @monitor_interval 5
  @detach_threshold 12

  @status_stale 0
  @status_unknown 100
  @status_available 1000

  @status_code_map %{
    "available" => @status_available,
    "unknown" => @status_unknown,
    "stale" => @status_stale
  }

  @autoconnect_types ["BackboneInterface", "TCPServerInterface"]

  @doc "Returns the unknown threshold in seconds (24 hours)."
  @spec threshold_unknown() :: non_neg_integer()
  def threshold_unknown, do: @threshold_unknown

  @doc "Returns the stale threshold in seconds (3 days)."
  @spec threshold_stale() :: non_neg_integer()
  def threshold_stale, do: @threshold_stale

  @doc "Returns the remove threshold in seconds (7 days)."
  @spec threshold_remove() :: non_neg_integer()
  def threshold_remove, do: @threshold_remove

  @doc "Returns the monitor interval in seconds."
  @spec monitor_interval() :: non_neg_integer()
  def monitor_interval, do: @monitor_interval

  @doc "Returns the detach threshold in seconds."
  @spec detach_threshold() :: non_neg_integer()
  def detach_threshold, do: @detach_threshold

  @doc "Returns the status code for stale interfaces."
  @spec status_stale() :: non_neg_integer()
  def status_stale, do: @status_stale

  @doc "Returns the status code for unknown interfaces."
  @spec status_unknown() :: non_neg_integer()
  def status_unknown, do: @status_unknown

  @doc "Returns the status code for available interfaces."
  @spec status_available() :: non_neg_integer()
  def status_available, do: @status_available

  @doc "Returns the status code map."
  @spec status_code_map() :: map()
  def status_code_map, do: @status_code_map

  @doc "Returns the list of interface types eligible for auto-connection."
  @spec autoconnect_types() :: [String.t()]
  def autoconnect_types, do: @autoconnect_types

  @doc """
  Processes a newly discovered interface.

  If the interface has not been seen before, creates a new entry.
  If it has been seen before, updates the last_heard time and increments heard_count.

  Persists the data as a msgpack file in the storage directory.
  """
  @spec interface_discovered(map(), String.t()) :: :ok | {:error, term()}
  def interface_discovered(info, storage_path) do
    discovery_hash = info["discovery_hash"]
    filename = RNS.hexrep(discovery_hash, false)
    filepath = Path.join(storage_path, filename)

    if File.regular?(filepath) do
      # Update existing entry
      update_existing_discovery(filepath, info)
    else
      # Create new entry
      create_new_discovery(filepath, info)
    end
  end

  defp create_new_discovery(filepath, info) do
    entry =
      info
      |> Map.put("discovered", info["received"])
      |> Map.put("last_heard", info["received"])
      |> Map.put("heard_count", 0)

    File.write!(filepath, Msgpax.pack!(entry, iodata: false))
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp update_existing_discovery(filepath, info) do
    last_info = filepath |> File.read!() |> Msgpax.unpack!()
    discovered = Map.get(last_info, "discovered", info["received"])
    heard_count = Map.get(last_info, "heard_count", 0)

    entry =
      info
      |> Map.put("discovered", discovered)
      |> Map.put("last_heard", info["received"])
      |> Map.put("heard_count", heard_count + 1)

    File.write!(filepath, Msgpax.pack!(entry, iodata: false))
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Lists all discovered interfaces from the storage directory.

  ## Options
  - `:only_available` — only return interfaces with "available" status
  - `:only_transport` — only return interfaces with transport enabled
  - `:discovery_sources` — list of authorized network identity hashes (binaries)

  Returns a list of interface info maps sorted by status, value, and last_heard (descending).
  """
  @spec list_discovered_interfaces(String.t(), keyword()) :: [map()]
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def list_discovered_interfaces(storage_path, opts \\ []) do
    only_available = Keyword.get(opts, :only_available, false)
    only_transport = Keyword.get(opts, :only_transport, false)
    discovery_sources = Keyword.get(opts, :discovery_sources, nil)
    now = System.system_time(:second)

    storage_path
    |> File.ls!()
    |> Enum.reduce([], fn filename, acc ->
      filepath = Path.join(storage_path, filename)

      try do
        info = filepath |> File.read!() |> Msgpax.unpack!()
        heard_delta = now - info["last_heard"]

        should_remove =
          cond do
            heard_delta > @threshold_remove ->
              true

            discovery_sources != nil and not Map.has_key?(info, "network_id") ->
              true

            discovery_sources != nil and
                Base.decode16!(info["network_id"], case: :mixed) not in discovery_sources ->
              true

            Map.has_key?(info, "reachable_on") and
                not (Discovery.is_ip_address(info["reachable_on"]) or
                         Discovery.is_hostname(info["reachable_on"])) ->
              true

            true ->
              false
          end

        if should_remove do
          File.rm(filepath)
          acc
        else
          status =
            cond do
              heard_delta > @threshold_stale -> "stale"
              heard_delta > @threshold_unknown -> "unknown"
              true -> "available"
            end

          info =
            info
            |> Map.put("status", status)
            |> Map.put("status_code", @status_code_map[status])

          should_include =
            cond do
              not only_available and not only_transport -> true
              only_available and info["status"] != "available" -> false
              only_transport and not info["transport"] -> false
              true -> true
            end

          if should_include, do: [info | acc], else: acc
        end
      rescue
        _ -> acc
      end
    end)
    |> Enum.sort_by(
      fn info -> {info["status_code"], info["value"], info["last_heard"]} end,
      :desc
    )
  end

  @doc """
  Computes an endpoint hash from interface info.

  The hash is computed from the reachable_on address and port (if present).
  """
  @spec endpoint_hash(map()) :: binary()
  def endpoint_hash(info) do
    endpoint_specifier =
      if(Map.has_key?(info, "reachable_on"), do: to_string(info["reachable_on"]), else: "") <>
        if Map.has_key?(info, "port"), do: ":" <> to_string(info["port"]), else: ""

    RNS.Identity.full_hash(endpoint_specifier)
  end
end

defmodule RNS.Discovery.BlackholeUpdater do
  @moduledoc """
  Periodically fetches and distributes network blackhole lists.

  Connects to configured blackhole sources, retrieves their blackholed
  identity lists, and merges them into the local Transport blackhole table.
  """

  @initial_wait 20
  @job_interval 60
  @update_interval 60 * 60
  @source_timeout 25

  defstruct [
    :last_updates,
    :should_run,
    :job_interval
  ]

  @type t :: %__MODULE__{
          last_updates: map(),
          should_run: boolean(),
          job_interval: non_neg_integer()
        }

  @doc "Returns the initial wait time in seconds."
  @spec initial_wait() :: non_neg_integer()
  def initial_wait, do: @initial_wait

  @doc "Returns the job interval in seconds."
  @spec job_interval() :: non_neg_integer()
  def job_interval, do: @job_interval

  @doc "Returns the update interval in seconds."
  @spec update_interval() :: non_neg_integer()
  def update_interval, do: @update_interval

  @doc "Returns the source timeout in seconds."
  @spec source_timeout() :: non_neg_integer()
  def source_timeout, do: @source_timeout

  @doc "Creates a new BlackholeUpdater with default values."
  @spec new() :: t()
  def new do
    %__MODULE__{
      last_updates: %{},
      should_run: false,
      job_interval: @job_interval
    }
  end
end
