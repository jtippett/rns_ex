defmodule RNS.Interfaces.AutoInterface do
  @moduledoc """
  UDP multicast peer discovery interface for RNS.

  Automatically discovers peers on local network segments using IPv6
  multicast. Each discovered peer gets a spawned `AutoInterfacePeer`
  interface for data exchange via unicast UDP.

  Matches `python/RNS/Interfaces/AutoInterface.py`.
  """

  use GenServer
  use RNS.Interfaces.Interface

  import Bitwise
  require Logger

  # ── Constants ─────────────────────────────────────────────────

  @hw_mtu 1196
  @fixed_mtu true

  @default_discovery_port 29716
  @default_data_port 42671
  @default_group_id "reticulum"
  @default_ifac_size 16

  @scope_link "2"
  @scope_admin "4"
  @scope_site "5"
  @scope_organisation "8"
  @scope_global "e"

  @multicast_permanent_address_type "0"
  @multicast_temporary_address_type "1"

  @peering_timeout 22.0
  @announce_interval 1.6
  @peer_job_interval 4.0
  @mcast_echo_timeout 6.5

  @all_ignore_ifs ["lo0"]
  @darwin_ignore_ifs ["awdl0", "llw0", "lo0", "en5"]
  @android_ignore_ifs ["dummy0", "lo", "tun0"]

  @bitrate_guess 10_000_000

  @multi_if_deque_len 48
  @multi_if_deque_ttl 0.75

  # Expose constants
  def hw_mtu, do: @hw_mtu
  def default_discovery_port, do: @default_discovery_port
  def default_data_port, do: @default_data_port
  def default_group_id, do: @default_group_id
  def default_ifac_size, do: @default_ifac_size
  def scope_link, do: @scope_link
  def scope_admin, do: @scope_admin
  def scope_site, do: @scope_site
  def scope_organisation, do: @scope_organisation
  def scope_global, do: @scope_global
  def multicast_permanent_address_type, do: @multicast_permanent_address_type
  def multicast_temporary_address_type, do: @multicast_temporary_address_type
  def peering_timeout, do: @peering_timeout
  def announce_interval, do: @announce_interval
  def peer_job_interval, do: @peer_job_interval
  def mcast_echo_timeout, do: @mcast_echo_timeout
  def all_ignore_ifs, do: @all_ignore_ifs
  def darwin_ignore_ifs, do: @darwin_ignore_ifs
  def android_ignore_ifs, do: @android_ignore_ifs
  def bitrate_guess, do: @bitrate_guess
  def multi_if_deque_len, do: @multi_if_deque_len
  def multi_if_deque_ttl, do: @multi_if_deque_ttl

  # ── Struct ────────────────────────────────────────────────────

  defstruct default_fields() ++
              [
                # Config
                group_id: @default_group_id,
                discovery_port: @default_discovery_port,
                unicast_discovery_port: @default_discovery_port + 1,
                data_port: @default_data_port,
                discovery_scope: @scope_link,
                multicast_address_type: @multicast_temporary_address_type,
                mcast_discovery_address: nil,
                allowed_interfaces: [],
                ignored_interfaces: [],

                # Timing
                peering_timeout_val: @peering_timeout,
                announce_interval_val: @announce_interval,
                peer_job_interval_val: @peer_job_interval,
                multicast_echo_timeout_val: @mcast_echo_timeout,
                reverse_peering_interval: @announce_interval * 3.25,

                # Network state
                peers: %{},
                link_local_addresses: [],
                adopted_interfaces: %{},
                interface_servers: %{},
                multicast_echoes: %{},
                initial_echoes: %{},
                timed_out_interfaces: %{},
                carrier_changed: false,
                final_init_done: false,
                receives: false,

                # Multi-interface dedup deque (using :queue)
                mif_deque: nil,
                mif_deque_times: nil,

                # Sockets
                outbound_udp_socket: nil,
                discovery_sockets: %{},
                unicast_discovery_sockets: %{},

                # Owner
                owner: nil,

                # Skip network for testing
                skip_network: false
              ]

  @type t :: %__MODULE__{}

  # ── Public API ────────────────────────────────────────────────

  @doc "Starts an AutoInterface GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    server_opts =
      case Keyword.get(opts, :server_name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "Returns the current state."
  @spec get_state(GenServer.server()) :: t()
  def get_state(server), do: GenServer.call(server, :get_state)

  @doc "Stops the interface."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  @doc "Returns the number of spawned peer interfaces."
  @spec peer_count(GenServer.server()) :: non_neg_integer()
  def peer_count(server), do: GenServer.call(server, :peer_count)

  @doc "Adds or refreshes a peer."
  @spec add_peer(GenServer.server(), String.t(), String.t()) :: :ok
  def add_peer(server, addr, ifname), do: GenServer.call(server, {:add_peer, addr, ifname})

  @doc "Removes a peer."
  @spec remove_peer(GenServer.server(), String.t()) :: :ok
  def remove_peer(server, addr), do: GenServer.call(server, {:remove_peer, addr})

  @doc "Returns all peers."
  @spec get_peers(GenServer.server()) :: map()
  def get_peers(server), do: GenServer.call(server, :get_peers)

  @doc "Sends data out. No-op for AutoInterface parent."
  @spec send_data(GenServer.server(), binary()) :: :ok
  def send_data(server, _data), do: GenServer.call(server, :process_outgoing)

  @doc "Detaches the interface."
  @spec stop_interface(GenServer.server()) :: :ok
  def stop_interface(server), do: GenServer.call(server, :detach)

  # ── Behaviour callbacks ─────────────────────────────────────

  @impl RNS.Interfaces.Interface
  def process_outgoing(_state, _data), do: {:ok, nil}

  @impl RNS.Interfaces.Interface
  def process_incoming(_state, _data), do: {:ok, nil}

  @impl RNS.Interfaces.Interface
  def detach(_state), do: :ok

  @doc "Sets an adopted interface (for testing)."
  @spec set_adopted_interface(GenServer.server(), String.t(), String.t()) :: :ok
  def set_adopted_interface(server, ifname, addr) do
    GenServer.call(server, {:set_adopted_interface, ifname, addr})
  end

  @doc "Adds a link-local address (for testing)."
  @spec set_link_local_address(GenServer.server(), String.t()) :: :ok
  def set_link_local_address(server, addr) do
    GenServer.call(server, {:set_link_local_address, addr})
  end

  # ── Pure functions ────────────────────────────────────────────

  @doc """
  Removes scope specifiers from IPv6 link-local addresses.

  Handles macOS `%ifname` suffix and BSD embedded scope specifiers.
  """
  @spec descope_linklocal(String.t()) :: String.t()
  def descope_linklocal(addr) do
    addr
    # Drop macOS scope specifier (%ifname)
    |> String.split("%")
    |> hd()
    # Drop BSD embedded scope specifier (fe80:XXXX:: -> fe80::)
    |> then(fn a ->
      Regex.replace(~r/fe80:[0-9a-f]*::/, a, "fe80::")
    end)
  end

  @doc """
  Computes the IPv6 multicast discovery address from group ID, scope, and address type.

  Matches the Python computation exactly.
  """
  @spec compute_mcast_address(String.t() | binary(), String.t(), String.t()) :: String.t()
  def compute_mcast_address(group_id, scope, address_type) do
    group_id_bytes =
      if is_binary(group_id) do
        group_id
      else
        to_string(group_id)
      end

    group_hash = RNS.Identity.full_hash(group_id_bytes)
    bytes = :binary.bin_to_list(group_hash)

    # Python: gt = "0" + ":hex(g[3]+(g[2]<<8))" + ...
    parts =
      for {hi_idx, lo_idx} <- [{2, 3}, {4, 5}, {6, 7}, {8, 9}, {10, 11}, {12, 13}] do
        val = Enum.at(bytes, lo_idx) + (Enum.at(bytes, hi_idx) <<< 8)
        String.downcase(Integer.to_string(val, 16))
      end

    "ff" <> address_type <> scope <> ":0:" <> Enum.join(parts, ":")
  end

  @doc """
  Computes the discovery token (peering hash) for authentication.

  Returns SHA-256 hash of group_id + link_local_addr.
  """
  @spec compute_discovery_token(String.t() | binary(), String.t()) :: binary()
  def compute_discovery_token(group_id, link_local_addr) do
    group_id_bytes =
      if is_binary(group_id) do
        group_id
      else
        to_string(group_id)
      end

    RNS.Identity.full_hash(group_id_bytes <> link_local_addr)
  end

  @doc """
  Determines whether a network interface should be used for AutoInterface.

  Checks against platform-specific ignore lists, explicit allowed/ignored lists.
  """
  @spec should_use_interface?(String.t(), [String.t()], [String.t()], atom()) :: boolean()
  def should_use_interface?(ifname, allowed, ignored, platform) do
    cond do
      # Check platform-specific ignore lists (but allow if explicitly in allowed)
      platform == :darwin and ifname in @darwin_ignore_ifs and ifname not in allowed ->
        false

      platform == :android and ifname in @android_ignore_ifs and ifname not in allowed ->
        false

      # Check explicit ignored list
      ifname in ignored ->
        false

      # Check ALL_IGNORE_IFS
      ifname in @all_ignore_ifs and ifname not in allowed ->
        false

      # If allowed list is non-empty, interface must be in it
      length(allowed) > 0 and ifname not in allowed ->
        false

      true ->
        true
    end
  end

  @doc "Parses a discovery scope string into the scope constant."
  @spec parse_discovery_scope(String.t() | nil) :: String.t()
  def parse_discovery_scope(nil), do: @scope_link

  def parse_discovery_scope(scope) do
    case String.downcase(to_string(scope)) do
      "link" -> @scope_link
      "admin" -> @scope_admin
      "site" -> @scope_site
      "organisation" -> @scope_organisation
      "global" -> @scope_global
      _ -> @scope_link
    end
  end

  @doc "Parses a multicast address type string."
  @spec parse_multicast_address_type(String.t() | nil) :: String.t()
  def parse_multicast_address_type(nil), do: @multicast_temporary_address_type

  def parse_multicast_address_type(type) do
    case String.downcase(to_string(type)) do
      "permanent" -> @multicast_permanent_address_type
      "temporary" -> @multicast_temporary_address_type
      _ -> @multicast_temporary_address_type
    end
  end

  @doc """
  Lists IPv6 link-local addresses for a given interface name.

  Uses `:inet.getifaddrs/0` to find `fe80::` prefixed addresses.
  """
  @spec list_link_local_addresses(String.t()) :: [String.t()]
  def list_link_local_addresses(ifname) do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        charlist_name = String.to_charlist(ifname)

        case List.keyfind(ifaddrs, charlist_name, 0) do
          {_, opts} ->
            opts
            |> Keyword.get_values(:addr)
            |> Enum.filter(fn
              {_a, _b, _c, _d, _e, _f, _g, _h} = addr ->
                # IPv6 tuple - check if link-local (fe80::/10)
                formatted = format_ipv6(addr)
                String.starts_with?(formatted, "fe80:")

              _ ->
                false
            end)
            |> Enum.map(fn addr ->
              descope_linklocal(format_ipv6(addr))
            end)

          nil ->
            []
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Lists suitable interfaces with their link-local addresses.

  Returns `[{ifname, link_local_addr}]` for interfaces that pass filtering.
  """
  @spec list_suitable_interfaces([String.t()], [String.t()], atom()) :: [{String.t(), String.t()}]
  def list_suitable_interfaces(allowed, ignored, platform) do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {charlist_name, opts} ->
          ifname = List.to_string(charlist_name)

          if should_use_interface?(ifname, allowed, ignored, platform) do
            link_locals =
              opts
              |> Keyword.get_values(:addr)
              |> Enum.filter(fn
                {_a, _b, _c, _d, _e, _f, _g, _h} = addr ->
                  formatted = format_ipv6(addr)
                  String.starts_with?(formatted, "fe80:")

                _ ->
                  false
              end)
              |> Enum.map(fn addr -> descope_linklocal(format_ipv6(addr)) end)

            case link_locals do
              [addr | _] -> [{ifname, addr}]
              [] -> []
            end
          else
            []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Checks multi-interface deduplication deque for duplicate data.

  Returns `{hit?, updated_deque, updated_times}`.
  """
  @spec mif_deque_check(binary(), :queue.queue(), :queue.queue(), pos_integer(), float()) ::
          {boolean(), :queue.queue(), :queue.queue()}
  def mif_deque_check(data, deque, deque_times, max_len, ttl) do
    data_hash = RNS.Identity.full_hash(data)
    now = System.system_time(:millisecond) / 1000

    # Check if hash is in deque and within TTL
    deque_hit =
      if queue_member?(deque, data_hash) do
        :queue.to_list(deque_times)
        |> Enum.any?(fn {hash, time} ->
          hash == data_hash and now < time + ttl
        end)
      else
        false
      end

    if deque_hit do
      {true, deque, deque_times}
    else
      # Add to deque, respecting max length
      deque = bounded_queue_in(data_hash, deque, max_len)
      deque_times = bounded_queue_in({data_hash, now}, deque_times, max_len)
      {false, deque, deque_times}
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    owner = Keyword.get(opts, :owner)
    group_id = Keyword.get(opts, :group_id, @default_group_id)
    discovery_scope = parse_discovery_scope(Keyword.get(opts, :discovery_scope))
    discovery_port = Keyword.get(opts, :discovery_port, @default_discovery_port)

    multicast_address_type =
      parse_multicast_address_type(Keyword.get(opts, :multicast_address_type))

    data_port = Keyword.get(opts, :data_port, @default_data_port)
    allowed_interfaces = Keyword.get(opts, :allowed_interfaces, [])
    ignored_interfaces = Keyword.get(opts, :ignored_interfaces, [])
    configured_bitrate = Keyword.get(opts, :configured_bitrate)
    skip_network = Keyword.get(opts, :skip_network, false)

    mcast_address = compute_mcast_address(group_id, discovery_scope, multicast_address_type)

    peering_timeout_val =
      if RNS.Vendor.PlatformUtils.is_android?() do
        @peering_timeout * 1.25
      else
        @peering_timeout
      end

    state = %__MODULE__{
      name: name,
      owner: owner,
      in: true,
      out: false,
      online: false,
      hw_mtu: @hw_mtu,
      fixed_mtu: @fixed_mtu,
      ifac_size: @default_ifac_size,
      bitrate: configured_bitrate || @bitrate_guess,
      created: System.system_time(:second),
      group_id: group_id,
      discovery_port: discovery_port,
      unicast_discovery_port: discovery_port + 1,
      data_port: data_port,
      discovery_scope: discovery_scope,
      multicast_address_type: multicast_address_type,
      mcast_discovery_address: mcast_address,
      allowed_interfaces: allowed_interfaces,
      ignored_interfaces: ignored_interfaces,
      peering_timeout_val: peering_timeout_val,
      announce_interval_val: @announce_interval,
      peer_job_interval_val: @peer_job_interval,
      multicast_echo_timeout_val: @mcast_echo_timeout,
      reverse_peering_interval: @announce_interval * 3.25,
      mif_deque: :queue.new(),
      mif_deque_times: :queue.new(),
      skip_network: skip_network
    }

    # spawned_interfaces defaults to nil from default_fields, override to map
    state = %{state | hash: RNS.Interfaces.Interface.hash(state), spawned_interfaces: %{}}

    if not skip_network do
      state = setup_network(state)
      schedule_peer_jobs(state)
      {:ok, state}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:peer_count, _from, state) do
    {:reply, map_size(state.spawned_interfaces), state}
  end

  def handle_call({:add_peer, addr, ifname}, _from, state) do
    state = do_add_peer(state, addr, ifname)
    {:reply, :ok, state}
  end

  def handle_call({:remove_peer, addr}, _from, state) do
    state = do_remove_peer(state, addr)
    {:reply, :ok, state}
  end

  def handle_call(:get_peers, _from, state) do
    {:reply, state.peers, state}
  end

  def handle_call(:process_outgoing, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:detach, _from, state) do
    state = do_detach(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_adopted_interface, ifname, addr}, _from, state) do
    adopted = Map.put(state.adopted_interfaces, ifname, addr)
    {:reply, :ok, %{state | adopted_interfaces: adopted}}
  end

  def handle_call({:set_link_local_address, addr}, _from, state) do
    addrs =
      if addr in state.link_local_addresses do
        state.link_local_addresses
      else
        [addr | state.link_local_addresses]
      end

    {:reply, :ok, %{state | link_local_addresses: addrs}}
  end

  @impl GenServer
  def handle_info(:peer_jobs, state) do
    state = do_peer_jobs(state)
    schedule_peer_jobs(state)
    {:noreply, state}
  end

  def handle_info({:announce, ifname}, state) do
    do_peer_announce(state, ifname)
    schedule_announce(state, ifname)
    {:noreply, state}
  end

  def handle_info({:udp, _socket, ip, _port, data}, state) do
    # Discovery packet received
    addr = format_ipv6_tuple(ip)
    state = handle_discovery_packet(state, data, addr)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    do_detach(state)
    :ok
  end

  # ── Private: Network setup ───────────────────────────────────

  defp setup_network(state) do
    platform = get_platform()

    suitable =
      list_suitable_interfaces(
        state.allowed_interfaces,
        state.ignored_interfaces,
        platform
      )

    state =
      Enum.reduce(suitable, state, fn {ifname, link_local_addr}, acc ->
        adopted = Map.put(acc.adopted_interfaces, ifname, link_local_addr)
        echoes = Map.put(acc.multicast_echoes, ifname, System.system_time(:second))
        addrs = [link_local_addr | acc.link_local_addresses]

        acc = %{
          acc
          | adopted_interfaces: adopted,
            multicast_echoes: echoes,
            link_local_addresses: addrs
        }

        # Set up discovery sockets for this interface
        setup_discovery_sockets(acc, ifname, link_local_addr)
      end)

    if map_size(state.adopted_interfaces) > 0 do
      # Set up data port listeners
      state = setup_data_listeners(state)
      %{state | receives: true, online: true}
    else
      Logger.warning(
        "#{state} could not autoconfigure. This interface currently provides no connectivity."
      )

      state
    end
  end

  defp setup_discovery_sockets(state, ifname, link_local_addr) do
    try do
      if_index = interface_name_to_index(ifname)

      # Set up multicast discovery socket
      case open_multicast_discovery_socket(state, ifname, if_index) do
        {:ok, mcast_socket} ->
          # Set up unicast discovery socket
          case open_unicast_discovery_socket(state, ifname, link_local_addr, if_index) do
            {:ok, ucast_socket} ->
              discovery_sockets = Map.put(state.discovery_sockets, ifname, mcast_socket)
              unicast_sockets = Map.put(state.unicast_discovery_sockets, ifname, ucast_socket)

              # Schedule announce loop for this interface
              schedule_announce(state, ifname)

              %{
                state
                | discovery_sockets: discovery_sockets,
                  unicast_discovery_sockets: unicast_sockets
              }

            {:error, reason} ->
              Logger.error(
                "Could not open unicast discovery socket for #{ifname}: #{inspect(reason)}"
              )

              :gen_udp.close(mcast_socket)
              state
          end

        {:error, reason} ->
          Logger.error(
            "Could not open multicast discovery socket for #{ifname}: #{inspect(reason)}"
          )

          state
      end
    rescue
      e ->
        Logger.error(
          "Could not configure interface #{ifname} for #{state}: #{Exception.message(e)}"
        )

        state
    end
  end

  defp open_multicast_discovery_socket(state, _ifname, if_index) do
    udp_opts = [
      :binary,
      :inet6,
      active: true,
      reuseaddr: true,
      multicast_if: if_index
    ]

    # Add reuseport if available
    udp_opts =
      case :os.type() do
        {:unix, _} -> [{:raw, 0xFFFF, 0x0200, <<1::native-32>>} | udp_opts]
        _ -> udp_opts
      end

    case :gen_udp.open(state.discovery_port, udp_opts) do
      {:ok, socket} ->
        # Join multicast group
        mcast_addr = parse_ipv6!(state.mcast_discovery_address)

        mcast_group =
          mcast_addr
          |> Tuple.to_list()
          |> Enum.map(fn x -> <<x::16>> end)
          |> IO.iodata_to_binary()

        if_struct = <<if_index::native-unsigned-32>>
        group_req = mcast_group <> if_struct

        :inet.setopts(socket, [{:raw, 41, 20, group_req}])
        {:ok, socket}

      error ->
        error
    end
  end

  defp open_unicast_discovery_socket(state, _ifname, _link_local_addr, _if_index) do
    udp_opts = [
      :binary,
      :inet6,
      active: true,
      reuseaddr: true
    ]

    :gen_udp.open(state.unicast_discovery_port, udp_opts)
  end

  defp setup_data_listeners(state) do
    Enum.reduce(state.adopted_interfaces, state, fn {ifname, link_local_addr}, acc ->
      try do
        _if_index = interface_name_to_index(ifname)
        addr = parse_ipv6!(link_local_addr)

        udp_opts = [
          :binary,
          :inet6,
          active: true,
          reuseaddr: true,
          ifaddr: addr
        ]

        case :gen_udp.open(acc.data_port, udp_opts) do
          {:ok, socket} ->
            servers = Map.put(acc.interface_servers, ifname, socket)
            %{acc | interface_servers: servers}

          {:error, reason} ->
            Logger.error("Could not open data socket for #{ifname}: #{inspect(reason)}")
            acc
        end
      rescue
        e ->
          Logger.error("Could not set up data listener for #{ifname}: #{Exception.message(e)}")
          acc
      end
    end)
  end

  # ── Private: Discovery and peering ───────────────────────────

  defp handle_discovery_packet(state, data, addr) do
    if state.final_init_done do
      hash_len = min(byte_size(data), div(RNS.Identity.hashlength(), 8))
      <<peering_hash::binary-size(hash_len), _::binary>> = data
      expected_hash = RNS.Identity.full_hash(state.group_id <> addr)

      if peering_hash == expected_hash do
        do_add_peer(state, addr, nil)
      else
        Logger.debug(
          "#{state} received peering packet from #{addr}, but authentication hash was incorrect."
        )

        state
      end
    else
      state
    end
  end

  defp do_add_peer(state, addr, ifname) do
    if addr in state.link_local_addresses do
      # This is our own echo - find the interface and record the echo
      echo_ifname =
        Enum.find_value(state.adopted_interfaces, fn {name, adopted_addr} ->
          if adopted_addr == addr, do: name
        end)

      if echo_ifname do
        now = System.system_time(:second)
        echoes = Map.put(state.multicast_echoes, echo_ifname, now)
        initial = Map.put_new(state.initial_echoes, echo_ifname, now)
        %{state | multicast_echoes: echoes, initial_echoes: initial}
      else
        Logger.warning("#{state} received multicast echo on unexpected interface")
        state
      end
    else
      if not Map.has_key?(state.peers, addr) do
        now = System.system_time(:second)
        peer_ifname = ifname || find_ifname_for_peer(state, addr)

        # Create peer entry: [ifname, last_heard, last_outbound]
        peers =
          Map.put(state.peers, addr, %{
            ifname: peer_ifname,
            last_heard: now,
            last_outbound: now
          })

        # Create spawned interface
        spawned = %RNS.Interfaces.AutoInterfacePeer{
          addr: addr,
          ifname: peer_ifname,
          hw_mtu: state.hw_mtu,
          fixed_mtu: state.fixed_mtu,
          in: state.in,
          out: state.out,
          online: true,
          bitrate: state.bitrate,
          mode: state.mode,
          ifac_size: state.ifac_size,
          parent_interface: self(),
          announce_rate_target: state.announce_rate_target
        }

        # Replace existing spawned interface if any
        spawned_interfaces = Map.put(state.spawned_interfaces, addr, spawned)

        Logger.debug("#{state} added peer #{addr} on #{peer_ifname}")

        %{state | peers: peers, spawned_interfaces: spawned_interfaces}
      else
        # Refresh existing peer
        do_refresh_peer(state, addr)
      end
    end
  end

  defp do_refresh_peer(state, addr) do
    case Map.get(state.peers, addr) do
      nil ->
        state

      peer ->
        peers = Map.put(state.peers, addr, %{peer | last_heard: System.system_time(:second)})
        %{state | peers: peers}
    end
  end

  defp do_remove_peer(state, addr) do
    peers = Map.delete(state.peers, addr)
    spawned_interfaces = Map.delete(state.spawned_interfaces, addr)
    Logger.debug("#{state} removed peer #{addr}")
    %{state | peers: peers, spawned_interfaces: spawned_interfaces}
  end

  defp find_ifname_for_peer(_state, _addr) do
    # In a real implementation, we'd determine the interface from the source address
    # For now return nil
    nil
  end

  # ── Private: Periodic jobs ───────────────────────────────────

  defp schedule_peer_jobs(state) do
    interval = trunc(state.peer_job_interval_val * 1000)
    Process.send_after(self(), :peer_jobs, interval)
  end

  defp schedule_announce(state, ifname) do
    interval = trunc(state.announce_interval_val * 1000)
    Process.send_after(self(), {:announce, ifname}, interval)
  end

  defp do_peer_jobs(state) do
    now = System.system_time(:second)

    # Check for timed out peers
    timed_out =
      state.peers
      |> Enum.filter(fn {_addr, peer} ->
        now > peer.last_heard + state.peering_timeout_val
      end)
      |> Enum.map(fn {addr, _} -> addr end)

    # Remove timed out peers
    state =
      Enum.reduce(timed_out, state, fn addr, acc ->
        do_remove_peer(acc, addr)
      end)

    # Send reverse peering packets
    state =
      Enum.reduce(state.peers, state, fn {addr, peer}, acc ->
        if now > peer.last_outbound + acc.reverse_peering_interval do
          do_reverse_announce(acc, peer.ifname, addr)
          peers = Map.put(acc.peers, addr, %{peer | last_outbound: now})
          %{acc | peers: peers}
        else
          acc
        end
      end)

    # Check multicast echo timeouts
    state =
      Enum.reduce(state.adopted_interfaces, state, fn {ifname, _addr}, acc ->
        last_echo = Map.get(acc.multicast_echoes, ifname, 0)

        if now - last_echo > acc.multicast_echo_timeout_val do
          prev_timed_out = Map.get(acc.timed_out_interfaces, ifname)

          acc =
            if prev_timed_out == false do
              Logger.warning("Multicast echo timeout for #{ifname}. Carrier lost.")
              %{acc | carrier_changed: true}
            else
              acc
            end

          timed_out_ifs = Map.put(acc.timed_out_interfaces, ifname, true)
          %{acc | timed_out_interfaces: timed_out_ifs}
        else
          prev_timed_out = Map.get(acc.timed_out_interfaces, ifname)

          acc =
            if prev_timed_out == true do
              Logger.warning("#{acc} Carrier recovered on #{ifname}")
              %{acc | carrier_changed: true}
            else
              acc
            end

          timed_out_ifs = Map.put(acc.timed_out_interfaces, ifname, false)
          %{acc | timed_out_interfaces: timed_out_ifs}
        end
      end)

    state
  end

  defp do_peer_announce(state, ifname) do
    try do
      link_local_addr = Map.get(state.adopted_interfaces, ifname)

      if link_local_addr do
        token = compute_discovery_token(state.group_id, link_local_addr)
        if_index = interface_name_to_index(ifname)
        mcast_addr = parse_ipv6!(state.mcast_discovery_address)

        case :gen_udp.open(0, [:binary, :inet6, {:multicast_if, if_index}]) do
          {:ok, socket} ->
            :gen_udp.send(socket, mcast_addr, state.discovery_port, token)
            :gen_udp.close(socket)

          {:error, reason} ->
            timed_out = Map.get(state.timed_out_interfaces, ifname)

            if timed_out != true do
              Logger.warning(
                "#{state} Detected possible carrier loss on #{ifname}: #{inspect(reason)}"
              )
            end
        end
      end
    rescue
      e ->
        Logger.error("Error in peer_announce for #{ifname}: #{Exception.message(e)}")
    end
  end

  defp do_reverse_announce(state, ifname, peer_addr) do
    try do
      link_local_addr = Map.get(state.adopted_interfaces, ifname)

      if link_local_addr do
        token = compute_discovery_token(state.group_id, link_local_addr)
        addr = parse_ipv6!(peer_addr)

        case :gen_udp.open(0, [:binary, :inet6]) do
          {:ok, socket} ->
            :gen_udp.send(socket, addr, state.unicast_discovery_port, token)
            :gen_udp.close(socket)

          {:error, reason} ->
            Logger.error(
              "Could not send reverse peering packet to #{peer_addr} on #{ifname}: #{inspect(reason)}"
            )
        end
      end
    rescue
      e ->
        Logger.error(
          "Could not send reverse peering packet to #{peer_addr} on #{ifname}: #{Exception.message(e)}"
        )
    end
  end

  defp do_detach(state) do
    # Close all sockets
    Enum.each(state.discovery_sockets, fn {_name, socket} -> :gen_udp.close(socket) end)
    Enum.each(state.unicast_discovery_sockets, fn {_name, socket} -> :gen_udp.close(socket) end)
    Enum.each(state.interface_servers, fn {_name, socket} -> :gen_udp.close(socket) end)

    if state.outbound_udp_socket do
      :gen_udp.close(state.outbound_udp_socket)
    end

    %{
      state
      | online: false,
        discovery_sockets: %{},
        unicast_discovery_sockets: %{},
        interface_servers: %{},
        outbound_udp_socket: nil
    }
  end

  # ── Private: Helpers ─────────────────────────────────────────

  defp interface_name_to_index(ifname) do
    charlist_name = String.to_charlist(ifname)
    # :net.if_name2index returns {:ok, index} in OTP 26+
    case :net.if_name2index(charlist_name) do
      {:ok, index} -> index
      _ -> 0
    end
  end

  defp get_platform do
    cond do
      RNS.Vendor.PlatformUtils.is_darwin?() -> :darwin
      RNS.Vendor.PlatformUtils.is_android?() -> :android
      true -> :linux
    end
  end

  defp format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
    |> String.downcase()
  end

  defp format_ipv6_tuple(tuple) when is_tuple(tuple) and tuple_size(tuple) == 8 do
    format_ipv6(tuple)
  end

  defp format_ipv6_tuple(tuple) when is_tuple(tuple) and tuple_size(tuple) == 4 do
    # IPv4 tuple
    Tuple.to_list(tuple) |> Enum.join(".")
  end

  defp format_ipv6_tuple(other), do: to_string(other)

  defp parse_ipv6!(addr_string) do
    case :inet.parse_ipv6strict_address(String.to_charlist(addr_string)) do
      {:ok, tuple} -> tuple
      {:error, _} -> raise ArgumentError, "Invalid IPv6 address: #{addr_string}"
    end
  end

  defp queue_member?(queue, item) do
    :queue.to_list(queue)
    |> Enum.member?(item)
  end

  defp bounded_queue_in(item, queue, max_len) do
    queue = :queue.in(item, queue)

    if :queue.len(queue) > max_len do
      {_, queue} = :queue.out(queue)
      queue
    else
      queue
    end
  end

  # ── String.Chars ─────────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name}) do
      "AutoInterface[#{name}]"
    end
  end
end
