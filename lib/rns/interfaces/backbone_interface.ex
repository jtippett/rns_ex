defmodule RNS.Interfaces.BackboneInterface do
  @moduledoc """
  Backbone TCP server interface for RNS.

  High-bandwidth TCP-based interface that listens for connections and spawns
  `RNS.Interfaces.BackboneClientInterface` GenServers for each incoming
  connection. Uses HDLC framing over raw TCP sockets with a 1 MB HW_MTU.

  In Python this uses Linux epoll for I/O multiplexing. The Elixir port
  leverages BEAM's built-in I/O scheduling via `:gen_tcp` active mode,
  making it cross-platform.

  The server itself does not directly process packets — all data flows
  through spawned client interfaces.

  Matches `BackboneInterface` in `python/RNS/Interfaces/BackboneInterface.py`.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  # ── Constants ──────────────────────────────────────────────────────

  @hw_mtu 1_048_576
  @bitrate_guess 1_000_000_000
  @default_ifac_size 16
  @autoconfigure_mtu true

  defstruct Keyword.merge(default_fields(), spawned_interfaces: []) ++
              [
                # Server config
                bind_ip: nil,
                bind_port: nil,
                listen_socket: nil,

                # IPv6 preference
                prefer_ipv6: false,

                # Owner (Transport or callback)
                owner: nil,

                # Receives flag
                receives: false
              ]

  @type t :: %__MODULE__{}

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the HW_MTU for Backbone interfaces (1 MB)."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu

  @doc "Returns the default bitrate guess (1 Gbps)."
  @spec bitrate_guess() :: pos_integer()
  def bitrate_guess, do: @bitrate_guess

  @doc "Returns the default IFAC size."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns whether MTU autoconfiguration is enabled."
  @spec autoconfigure_mtu() :: boolean()
  def autoconfigure_mtu, do: @autoconfigure_mtu

  @doc """
  Starts a Backbone server interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:owner` — owner process or callback for inbound data
    * `:listen_ip` — IP address to bind to
    * `:listen_port` / `:port` — port to listen on (required)
    * `:device` — network device name for address resolution
    * `:prefer_ipv6` — prefer IPv6 addresses (default: false)
    * `:server_name` — GenServer registration name (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    server_opts =
      case Keyword.get(opts, :server_name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "Returns the current state of the server interface."
  @spec get_state(GenServer.server()) :: t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Returns the number of connected clients."
  @spec client_count(GenServer.server()) :: non_neg_integer()
  def client_count(server) do
    GenServer.call(server, :client_count)
  end

  @doc "Detaches and stops the server interface."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.call(server, :detach)
  end

  @doc """
  Resolves the IP address for a given network interface name.

  Returns `{:ok, ip_string}` or `{:error, reason}`.
  """
  @spec get_address_for_if(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_address_for_if(device_name) do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        device_charlist = String.to_charlist(device_name)

        case List.keyfind(ifaddrs, device_charlist, 0) do
          {_, opts} ->
            case Keyword.get(opts, :addr) do
              {a, b, c, d} -> {:ok, "#{a}.#{b}.#{c}.#{d}"}
              _ -> {:error, :no_ipv4_address}
            end

          nil ->
            {:error, :device_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Updates announce frequency tracking when a received announce comes from a spawned interface."
  @spec received_announce(t(), boolean()) :: t()
  def received_announce(state, from_spawned \\ false) do
    if from_spawned do
      %{state | ia_freq_deque: state.ia_freq_deque ++ [System.system_time(:second)]}
    else
      state
    end
  end

  @doc "Updates announce frequency tracking when a sent announce comes from a spawned interface."
  @spec sent_announce(t(), boolean()) :: t()
  def sent_announce(state, from_spawned \\ false) do
    if from_spawned do
      %{state | oa_freq_deque: state.oa_freq_deque ++ [System.system_time(:second)]}
    else
      state
    end
  end

  # ── Behaviour callbacks ──────────────────────────────────────────

  @impl RNS.Interfaces.Interface
  def process_outgoing(state, _data) do
    # Server interfaces don't directly process outgoing data (pass in Python)
    {:ok, state}
  end

  @impl RNS.Interfaces.Interface
  def process_incoming(_state, _data) do
    {:error, :server_interface}
  end

  @impl RNS.Interfaces.Interface
  def detach(%__MODULE__{} = state) do
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    :ok
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    owner = Keyword.get(opts, :owner)
    device = Keyword.get(opts, :device)
    port = Keyword.get(opts, :port)
    bind_ip = Keyword.get(opts, :listen_ip)
    bind_port = Keyword.get(opts, :listen_port)
    prefer_ipv6 = Keyword.get(opts, :prefer_ipv6, false)

    # Port shorthand
    bind_port = bind_port || port

    if bind_port == nil do
      {:stop, {:error, "No TCP port configured for interface \"#{name}\""}}
    else
      # Resolve bind address
      bind_ip =
        cond do
          device != nil ->
            case get_address_for_if(device) do
              {:ok, addr} -> addr
              {:error, _} -> bind_ip
            end

          bind_ip != nil ->
            bind_ip

          true ->
            nil
        end

      if bind_ip == nil do
        {:stop, {:error, "No TCP bind IP configured for interface \"#{name}\""}}
      else
        do_listen(name, owner, bind_ip, bind_port, prefer_ipv6)
      end
    end
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:client_count, _from, state) do
    alive = Enum.filter(state.spawned_interfaces, &Process.alive?/1)
    state = %{state | spawned_interfaces: alive}
    {:reply, length(alive), state}
  end

  def handle_call(:detach, _from, state) do
    Logger.debug("Detaching #{format_name(state)}")

    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    # Stop all spawned clients
    Enum.each(state.spawned_interfaces, fn pid ->
      if Process.alive?(pid) do
        try do
          RNS.Interfaces.BackboneClientInterface.stop(pid)
        catch
          _, _ -> :ok
        end
      end
    end)

    {:reply, :ok,
     %{
       state
       | online: false,
         detached: true,
         listen_socket: nil,
         spawned_interfaces: []
     }}
  end

  @impl GenServer
  def handle_info({:inet_async, listen_socket, _ref, {:ok, client_socket}}, state) do
    state = handle_new_connection(state, client_socket)
    accept_async(listen_socket)
    {:noreply, state}
  end

  def handle_info({:inet_async, _listen_socket, _ref, {:error, reason}}, state) do
    if not state.detached do
      Logger.error("Accept error on #{format_name(state)}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    spawned = List.delete(state.spawned_interfaces, pid)
    {:noreply, %{state | spawned_interfaces: spawned}}
  end

  def handle_info({:update_rxb, bytes}, state) do
    {:noreply, %{state | rxb: state.rxb + bytes}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp do_listen(name, owner, bind_ip, bind_port, prefer_ipv6) do
    ip_tuple = parse_ip!(bind_ip)

    tcp_opts = [
      :binary,
      ip: ip_tuple,
      active: false,
      reuseaddr: true,
      packet: :raw,
      nodelay: true,
      backlog: 128
    ]

    case :gen_tcp.listen(bind_port, tcp_opts) do
      {:ok, listen_socket} ->
        accept_async(listen_socket)

        state = %__MODULE__{
          name: name,
          owner: owner,
          bind_ip: bind_ip,
          bind_port: bind_port,
          listen_socket: listen_socket,
          in: true,
          out: false,
          online: true,
          receives: true,
          prefer_ipv6: prefer_ipv6,
          bitrate: @bitrate_guess,
          hw_mtu: @hw_mtu,
          autoconfigure_mtu: @autoconfigure_mtu,
          ifac_size: @default_ifac_size,
          supports_discovery: true,
          mode: RNS.Interfaces.Interface.mode_full(),
          created: System.system_time(:second)
        }

        state = %{state | hash: RNS.Interfaces.Interface.hash(state)}
        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "Could not bind TCP socket for #{name} on #{bind_ip}:#{bind_port}: #{inspect(reason)}"
        )

        {:stop, {:error, reason}}
    end
  end

  defp accept_async(listen_socket) do
    case :prim_inet.async_accept(listen_socket, -1) do
      {:ok, _ref} -> :ok
      {:error, reason} -> Logger.error("Failed to start async accept: #{inspect(reason)}")
    end
  end

  defp handle_new_connection(state, client_socket) do
    Logger.info("Accepting incoming connection on #{format_name(state)}")

    :inet_db.register_socket(client_socket, :inet_tcp)

    {:ok, {client_ip, client_port}} = :inet.peername(client_socket)
    client_ip_str = :inet.ntoa(client_ip) |> List.to_string()

    client_name = "Client on #{state.name}"

    client_opts = [
      name: client_name,
      owner: state.owner,
      connected_socket: client_socket,
      target_host: nil,
      target_port: nil,
      parent_interface: self()
    ]

    case RNS.Interfaces.BackboneClientInterface.start_link(client_opts) do
      {:ok, pid} ->
        Process.monitor(pid)

        GenServer.cast(
          pid,
          {:update_connection_info, client_ip_str, client_port, state}
        )

        Logger.info(
          "Spawned new BackboneClient Interface: BackboneInterface[#{client_name}/#{client_ip_str}:#{client_port}]"
        )

        alive = Enum.filter(state.spawned_interfaces, &Process.alive?/1)
        %{state | spawned_interfaces: alive ++ [pid]}

      {:error, reason} ->
        Logger.error("Failed to spawn client interface: #{inspect(reason)}")
        :gen_tcp.close(client_socket)
        state
    end
  end

  defp parse_ip!(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, tuple} -> tuple
      {:error, _} -> raise ArgumentError, "Invalid IP address: #{ip_string}"
    end
  end

  defp format_name(state) do
    ip = state.bind_ip || "unknown"
    port = state.bind_port || "?"

    ip_str =
      if String.contains?(ip, ":") do
        "[#{ip}]"
      else
        ip
      end

    "BackboneInterface[#{state.name}/#{ip_str}:#{port}]"
  end

  # ── String.Chars protocol ────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name, bind_ip: ip, bind_port: port})
        when is_binary(ip) and not is_nil(port) do
      ip_str = if String.contains?(ip, ":"), do: "[#{ip}]", else: ip
      "BackboneInterface[#{name}/#{ip_str}:#{port}]"
    end

    def to_string(%{name: name}) do
      "BackboneInterface[#{name}]"
    end
  end
end

defmodule RNS.Interfaces.BackboneClientInterface do
  @moduledoc """
  Backbone TCP client interface for RNS.

  Connects to a remote Backbone server or wraps a pre-connected socket
  (when spawned by `RNS.Interfaces.BackboneInterface`). Uses HDLC
  framing over raw TCP with high-bandwidth optimization (1 MB HW_MTU,
  100 Mbps bitrate guess).

  Supports automatic reconnection with configurable retry limits.

  Matches `BackboneClientInterface` in `python/RNS/Interfaces/BackboneInterface.py`.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  alias RNS.Interfaces.Interface.HDLC

  # ── Constants ──────────────────────────────────────────────────────

  @bitrate_guess 100_000_000
  @default_ifac_size 16

  @reconnect_wait 5
  @reconnect_max_tries nil

  # TCP socket options
  @tcp_user_timeout 24
  @tcp_probe_after 5
  @tcp_probe_interval 2
  @tcp_probes 12

  @initial_connect_timeout 5_000

  # Minimum frame size to accept (matches RNS.Reticulum.HEADER_MINSIZE)
  @header_minsize 19

  defstruct default_fields() ++
              [
                # TCP connection
                socket: nil,
                target_ip: nil,
                target_port: nil,
                initiator: false,
                reconnecting: false,
                never_connected: true,
                connect_timeout: @initial_connect_timeout,
                max_reconnect_tries: @reconnect_max_tries,

                # Framing
                frame_buffer: <<>>,
                transmit_buffer: <<>>,

                # I2P tunneling
                i2p_tunneled: false,

                # IPv6 preference
                prefer_ipv6: false,

                # Wants tunnel (for reconnections)
                wants_tunnel: false,

                # Reconnection tracking
                reconnect_attempts: 0,

                # Owner (Transport or callback)
                owner: nil,

                # Receives flag
                receives: false
              ]

  @type t :: %__MODULE__{}

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the default bitrate guess (100 Mbps)."
  @spec bitrate_guess() :: pos_integer()
  def bitrate_guess, do: @bitrate_guess

  @doc "Returns the default IFAC size."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns the reconnect wait time in seconds."
  @spec reconnect_wait() :: pos_integer()
  def reconnect_wait, do: @reconnect_wait

  @doc "Returns the max reconnect tries (nil = unlimited)."
  @spec reconnect_max_tries() :: nil | pos_integer()
  def reconnect_max_tries, do: @reconnect_max_tries

  @doc "Returns the initial connect timeout in milliseconds."
  @spec initial_connect_timeout() :: pos_integer()
  def initial_connect_timeout, do: @initial_connect_timeout

  @doc "Returns the HEADER_MINSIZE constant."
  @spec header_minsize() :: pos_integer()
  def header_minsize, do: @header_minsize

  @doc "Returns the TCP_USER_TIMEOUT constant."
  @spec tcp_user_timeout() :: pos_integer()
  def tcp_user_timeout, do: @tcp_user_timeout

  @doc "Returns the TCP_PROBE_AFTER constant."
  @spec tcp_probe_after() :: pos_integer()
  def tcp_probe_after, do: @tcp_probe_after

  @doc "Returns the TCP_PROBE_INTERVAL constant."
  @spec tcp_probe_interval() :: pos_integer()
  def tcp_probe_interval, do: @tcp_probe_interval

  @doc "Returns the TCP_PROBES constant."
  @spec tcp_probes() :: pos_integer()
  def tcp_probes, do: @tcp_probes

  @doc """
  Starts a Backbone client interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:owner` — owner process or callback for inbound data
    * `:target_host` — IP/hostname to connect to
    * `:target_port` — port to connect to
    * `:connect_timeout` — connection timeout in ms (default: 5000)
    * `:max_reconnect_tries` — max reconnection attempts (default: nil = unlimited)
    * `:connected_socket` — pre-connected socket (for server-spawned clients)
    * `:parent_interface` — PID of parent BackboneInterface (for spawned clients)
    * `:prefer_ipv6` — prefer IPv6 addresses (default: false)
    * `:i2p_tunneled` — whether this is an I2P tunnel (default: false)
    * `:server_name` — GenServer registration name (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    server_opts =
      case Keyword.get(opts, :server_name) do
        nil -> []
        name -> [name: name]
      end

    connected_socket = Keyword.get(opts, :connected_socket)

    case GenServer.start_link(__MODULE__, opts, server_opts) do
      {:ok, pid} = result ->
        if connected_socket != nil do
          :gen_tcp.controlling_process(connected_socket, pid)
          send(pid, :activate_socket)
        end

        result

      other ->
        other
    end
  end

  @doc "Sends data out through this Backbone interface."
  @spec send_data(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_data(server, data) do
    GenServer.call(server, {:send_data, data})
  end

  @doc "Returns the current state of the interface."
  @spec get_state(GenServer.server()) :: t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Detaches and stops the interface."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.call(server, :detach)
  end

  # ── Behaviour callbacks ──────────────────────────────────────────

  @impl RNS.Interfaces.Interface
  def process_outgoing(state, data) do
    do_send(state, data)
  end

  @impl RNS.Interfaces.Interface
  def process_incoming(state, data) do
    if state.online and not state.detached do
      updated = %{state | rxb: state.rxb + byte_size(data)}

      # Update parent interface stats
      if updated.parent_interface && is_pid(updated.parent_interface) do
        send(updated.parent_interface, {:update_rxb, byte_size(data)})
      end

      if state.owner do
        notify_owner(state.owner, data, updated)
      end

      {:ok, updated}
    else
      {:ok, state}
    end
  end

  @impl RNS.Interfaces.Interface
  def detach(%__MODULE__{} = state) do
    close_socket(state.socket)
    :ok
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    owner = Keyword.get(opts, :owner)
    target_ip = Keyword.get(opts, :target_host)
    target_port = Keyword.get(opts, :target_port)
    i2p_tunneled = Keyword.get(opts, :i2p_tunneled, false)
    connect_timeout = Keyword.get(opts, :connect_timeout, @initial_connect_timeout)
    max_reconnect_tries = Keyword.get(opts, :max_reconnect_tries, @reconnect_max_tries)
    connected_socket = Keyword.get(opts, :connected_socket)
    prefer_ipv6 = Keyword.get(opts, :prefer_ipv6, false)
    parent_interface = Keyword.get(opts, :parent_interface)

    state = %__MODULE__{
      name: name,
      owner: owner,
      in: true,
      out: false,
      online: false,
      bitrate: @bitrate_guess,
      hw_mtu: RNS.Interfaces.BackboneInterface.hw_mtu(),
      autoconfigure_mtu: RNS.Interfaces.BackboneInterface.autoconfigure_mtu(),
      ifac_size: @default_ifac_size,
      i2p_tunneled: i2p_tunneled,
      prefer_ipv6: prefer_ipv6,
      connect_timeout: connect_timeout,
      max_reconnect_tries: max_reconnect_tries,
      parent_interface: parent_interface,
      supports_discovery: true,
      mode: RNS.Interfaces.Interface.mode_full(),
      created: System.system_time(:second)
    }

    state =
      cond do
        # Pre-connected socket (spawned by server)
        connected_socket != nil ->
          set_tcp_keepalive(connected_socket)

          %{
            state
            | socket: connected_socket,
              receives: true,
              target_ip: nil,
              target_port: nil,
              online: true,
              never_connected: false
          }

        # Initiator mode — connect to target
        target_ip != nil and target_port != nil ->
          target_port =
            if is_binary(target_port), do: String.to_integer(target_port), else: target_port

          state = %{
            state
            | target_ip: target_ip,
              target_port: target_port,
              receives: true,
              initiator: true
          }

          case do_connect(state) do
            {:ok, connected_state} ->
              %{connected_state | wants_tunnel: true}

            {:error, _reason} ->
              Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
              state
          end

        true ->
          state
      end

    state = %{state | hash: RNS.Interfaces.Interface.hash(state)}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send_data, data}, _from, state) do
    case do_send(state, data) do
      {:ok, updated} -> {:reply, :ok, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:detach, _from, state) do
    close_socket(state.socket)
    {:reply, :ok, %{state | online: false, detached: true, socket: nil}}
  end

  @impl GenServer
  def handle_info({:tcp, _socket, data}, state) do
    {:ok, updated} = process_tcp_data(state, data)
    {:noreply, updated}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    state = %{state | online: false, socket: nil}

    if state.initiator and not state.detached do
      Logger.warning(
        "The socket for #{format_name(state)} was closed, attempting to reconnect..."
      )

      Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
      {:noreply, %{state | reconnecting: true}}
    else
      Logger.info("The socket for remote client #{format_name(state)} was closed.")
      {:noreply, teardown(state)}
    end
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("An interface error occurred for #{format_name(state)}: #{inspect(reason)}")

    state = %{state | online: false}

    if state.initiator and not state.detached do
      Logger.warning("Attempting to reconnect...")
      close_socket(state.socket)
      Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
      {:noreply, %{state | socket: nil, reconnecting: true}}
    else
      close_socket(state.socket)
      {:noreply, teardown(%{state | socket: nil})}
    end
  end

  def handle_info(:reconnect, state) do
    if not state.initiator or state.detached do
      {:noreply, state}
    else
      case do_connect(state) do
        {:ok, connected_state} ->
          connected_state = %{connected_state | reconnecting: false}

          if not state.never_connected do
            Logger.info("Reconnected socket for #{format_name(connected_state)}.")
          end

          connected_state = %{connected_state | wants_tunnel: true}
          {:noreply, connected_state}

        {:error, reason} ->
          attempts = state.reconnect_attempts + 1

          if state.max_reconnect_tries != nil and attempts > state.max_reconnect_tries do
            Logger.error("Max reconnection attempts reached for #{format_name(state)}")
            {:noreply, teardown(state)}
          else
            Logger.debug(
              "Connection attempt for #{format_name(state)} failed: #{inspect(reason)}"
            )

            Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
            {:noreply, %{state | reconnect_attempts: attempts}}
          end
      end
    end
  end

  def handle_info(:activate_socket, state) do
    if state.socket do
      :inet.setopts(state.socket, [
        :binary,
        {:nodelay, true},
        {:packet, :raw},
        {:active, true}
      ])
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:update_connection_info, ip, port, parent_state}, state) do
    state = %{
      state
      | target_ip: ip,
        target_port: port,
        bitrate: parent_state.bitrate,
        mode: parent_state.mode,
        hw_mtu: parent_state.hw_mtu
    }

    state = RNS.Interfaces.Interface.optimise_mtu(state)
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_socket(state.socket)
    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp do_connect(state) do
    target_ip = state.target_ip
    target_port = state.target_port
    timeout = state.connect_timeout

    Logger.debug("Establishing TCP connection for #{format_name(state)}...")

    ip_charlist = String.to_charlist(target_ip)

    tcp_opts = [
      :binary,
      active: true,
      packet: :raw,
      nodelay: true
    ]

    case :gen_tcp.connect(ip_charlist, target_port, tcp_opts, timeout) do
      {:ok, socket} ->
        set_tcp_keepalive(socket)

        Logger.debug("TCP connection for #{format_name(state)} established")

        {:ok,
         %{
           state
           | socket: socket,
             online: true,
             never_connected: false,
             frame_buffer: <<>>,
             reconnect_attempts: 0
         }}

      {:error, reason} ->
        if state.never_connected do
          Logger.error(
            "Initial connection for #{format_name(state)} could not be established: #{inspect(reason)}"
          )

          Logger.error(
            "Leaving unconnected and retrying connection in #{@reconnect_wait} seconds."
          )
        end

        {:error, reason}
    end
  end

  defp do_send(state, data) do
    if state.online and not state.detached and state.socket != nil do
      framed = HDLC.frame(data)

      case :gen_tcp.send(state.socket, framed) do
        :ok ->
          {:ok, %{state | txb: state.txb + byte_size(framed)}}

        {:error, reason} ->
          Logger.error(
            "Exception occurred while transmitting via #{format_name(state)}, tearing down interface"
          )

          Logger.error("The contained exception was: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_connected}
    end
  end

  defp process_tcp_data(state, data) do
    buffer = state.frame_buffer <> data

    {frames, remaining} = HDLC.deframe(buffer)

    state = %{state | frame_buffer: remaining}

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        if byte_size(frame) > @header_minsize do
          case process_incoming(acc, frame) do
            {:ok, updated} -> updated
            _ -> acc
          end
        else
          acc
        end
      end)

    {:ok, state}
  end

  defp set_tcp_keepalive(socket) do
    :inet.setopts(socket, [{:keepalive, true}])

    case :os.type() do
      {:unix, :linux} ->
        set_linux_keepalive(socket)

      {:unix, :darwin} ->
        set_darwin_keepalive(socket)

      _ ->
        :ok
    end
  end

  defp set_linux_keepalive(socket) do
    try do
      :inet.setopts(socket, [{:raw, 6, 18, <<@tcp_user_timeout * 1000::native-32>>}])
      :inet.setopts(socket, [{:raw, 6, 4, <<@tcp_probe_after::native-32>>}])
      :inet.setopts(socket, [{:raw, 6, 5, <<@tcp_probe_interval::native-32>>}])
      :inet.setopts(socket, [{:raw, 6, 6, <<@tcp_probes::native-32>>}])
    rescue
      _ -> :ok
    end
  end

  defp set_darwin_keepalive(socket) do
    try do
      :inet.setopts(socket, [{:raw, 6, 0x10, <<@tcp_probe_after::native-32>>}])
    rescue
      _ -> :ok
    end
  end

  defp teardown(state) do
    if state.initiator and not state.detached do
      Logger.error(
        "The interface #{format_name(state)} experienced an unrecoverable error and is being torn down. Restart Reticulum to attempt to open this interface again."
      )
    else
      Logger.info("The interface #{format_name(state)} is being torn down.")
    end

    close_socket(state.socket)

    %{state | online: false, out: false, in: false, socket: nil}
  end

  defp close_socket(nil), do: :ok

  defp close_socket(socket) do
    try do
      :gen_tcp.shutdown(socket, :read_write)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    try do
      :gen_tcp.close(socket)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp notify_owner(owner, data, interface) when is_pid(owner) do
    send(owner, {:backbone_interface_data, data, interface})
  end

  defp notify_owner({module, fun}, data, interface) when is_atom(module) and is_atom(fun) do
    apply(module, fun, [data, interface])
  end

  defp notify_owner(fun, data, interface) when is_function(fun, 2) do
    fun.(data, interface)
  end

  defp notify_owner(_, _data, _interface), do: :ok

  defp format_name(state) do
    ip = state.target_ip || "unknown"
    port = state.target_port || "?"

    ip_str =
      if is_binary(ip) and String.contains?(ip, ":") do
        "[#{ip}]"
      else
        ip
      end

    "BackboneInterface[#{state.name}/#{ip_str}:#{port}]"
  end

  # ── String.Chars protocol ────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name, target_ip: ip, target_port: port})
        when is_binary(ip) and not is_nil(port) do
      ip_str = if String.contains?(ip, ":"), do: "[#{ip}]", else: ip
      "BackboneInterface[#{name}/#{ip_str}:#{port}]"
    end

    def to_string(%{name: name}) do
      "BackboneInterface[#{name}]"
    end
  end
end
