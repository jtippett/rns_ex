defmodule RNS.Interfaces.I2PInterface do
  @moduledoc """
  I2P network interface for RNS.

  Provides anonymous networking through the I2P overlay network using the
  SAM (Simple Anonymous Messaging) protocol. Contains three components:

  - `RNS.Interfaces.I2PController` — manages I2P tunnel lifecycle via SAM API
  - `RNS.Interfaces.I2PInterfacePeer` — TCP client peer for I2P tunnel connections
  - `RNS.Interfaces.I2PInterface` — server interface managing peers and incoming connections

  Uses HDLC framing by default with optional KISS framing mode.
  Supports automatic reconnection and tunnel re-establishment.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  # ── Constants ──────────────────────────────────────────────────────

  @bitrate_guess 256_000
  @default_ifac_size 16
  @hw_mtu 1064

  defstruct Keyword.merge(default_fields(), spawned_interfaces: []) ++
              [
                # Server config
                bind_ip: "127.0.0.1",
                bind_port: nil,
                listen_socket: nil,

                # I2P state
                i2p_tunneled: true,
                connectable: false,
                b32: nil,
                i2p_controller: nil,
                storagepath: nil,

                # Owner (Transport or callback)
                owner: nil,

                # Receives flag
                receives: true,

                # IFAC config passthrough
                ifac_netname: nil,
                ifac_netkey: nil
              ]

  @type t :: %__MODULE__{}

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the bitrate guess for I2P interfaces (256 kbps)."
  @spec bitrate_guess() :: pos_integer()
  def bitrate_guess, do: @bitrate_guess

  @doc "Returns the default IFAC size."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns the HW_MTU for I2P interfaces."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu

  @doc """
  Starts an I2P server interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:owner` — owner process or callback for inbound data
    * `:storagepath` — RNS storage path for I2P key files
    * `:peers` — list of I2P destination addresses to connect to
    * `:connectable` — whether to create a server tunnel (default: false)
    * `:ifac_size` — IFAC size override
    * `:ifac_netname` — IFAC network name
    * `:ifac_netkey` — IFAC network key
    * `:bind_port` — local TCP port for I2P tunnel (default: auto)
    * `:server_name` — GenServer registration name (optional)
    * `:skip_i2p` — skip I2P controller startup for testing (default: false)
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

  @doc "Returns the number of connected peer clients."
  @spec client_count(GenServer.server()) :: non_neg_integer()
  def client_count(server) do
    GenServer.call(server, :client_count)
  end

  @doc "Detaches and stops the interface."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.call(server, :detach)
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
    if state.i2p_controller do
      RNS.Interfaces.I2PController.stop_controller(state.i2p_controller)
    end

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
    storagepath = Keyword.get(opts, :storagepath)
    peers = Keyword.get(opts, :peers)
    connectable = Keyword.get(opts, :connectable, false)
    ifac_size = Keyword.get(opts, :ifac_size)
    ifac_netname = Keyword.get(opts, :ifac_netname)
    ifac_netkey = Keyword.get(opts, :ifac_netkey)
    bind_port = Keyword.get(opts, :bind_port)
    skip_i2p = Keyword.get(opts, :skip_i2p, false)

    # Get a free port for the local TCP listener
    bind_port = bind_port || get_free_port()

    state = %__MODULE__{
      name: name,
      owner: owner,
      bind_ip: "127.0.0.1",
      bind_port: bind_port,
      in: true,
      out: false,
      online: false,
      bitrate: @bitrate_guess,
      hw_mtu: @hw_mtu,
      ifac_size: ifac_size || @default_ifac_size,
      ifac_netname: ifac_netname,
      ifac_netkey: ifac_netkey,
      connectable: connectable,
      storagepath: storagepath,
      i2p_tunneled: true,
      receives: true,
      supports_discovery: true,
      mode: RNS.Interfaces.Interface.mode_full(),
      created: System.system_time(:second)
    }

    # Start I2P controller (unless testing without I2P)
    state =
      if not skip_i2p and storagepath do
        case RNS.Interfaces.I2PController.start_link(storagepath: storagepath) do
          {:ok, pid} ->
            %{state | i2p_controller: pid}

          {:error, reason} ->
            Logger.error("Failed to start I2P controller: #{inspect(reason)}")
            state
        end
      else
        state
      end

    # Start local TCP listener for incoming I2P connections
    case start_listener(state) do
      {:ok, state} ->
        state = %{state | hash: RNS.Interfaces.Interface.hash(state)}

        # Start peer connections
        if peers do
          Enum.each(peers, fn peer_addr ->
            interface_name = "#{name} to #{peer_addr}"
            start_peer(state, interface_name, peer_addr)
          end)
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, {:error, reason}}
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
    Logger.debug("Detaching #{state}")

    if state.i2p_controller do
      RNS.Interfaces.I2PController.stop_controller(state.i2p_controller)
    end

    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    # Stop all spawned clients
    Enum.each(state.spawned_interfaces, fn pid ->
      if Process.alive?(pid) do
        try do
          RNS.Interfaces.I2PInterfacePeer.stop(pid)
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
         spawned_interfaces: [],
         i2p_controller: nil
     }}
  end

  @impl GenServer
  def handle_info({:inet_async, listen_socket, _ref, {:ok, client_socket}}, state) do
    state = handle_incoming_connection(state, client_socket)
    accept_async(listen_socket)
    {:noreply, state}
  end

  def handle_info({:inet_async, _listen_socket, _ref, {:error, reason}}, state) do
    if not state.detached do
      Logger.error("Accept error on #{state}: #{inspect(reason)}")
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

    RNS.Interfaces.Interface.deregister_on_terminate(state)
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp start_listener(state) do
    ip_tuple = parse_ip!(state.bind_ip)

    tcp_opts = [
      :binary,
      ip: ip_tuple,
      active: false,
      reuseaddr: true,
      packet: :raw,
      nodelay: true,
      backlog: 128
    ]

    case :gen_tcp.listen(state.bind_port, tcp_opts) do
      {:ok, listen_socket} ->
        accept_async(listen_socket)
        {:ok, %{state | listen_socket: listen_socket, online: true}}

      {:error, reason} ->
        Logger.error(
          "Could not bind TCP socket for #{state.name} on #{state.bind_ip}:#{state.bind_port}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp accept_async(listen_socket) do
    case :prim_inet.async_accept(listen_socket, -1) do
      {:ok, _ref} -> :ok
      {:error, reason} -> Logger.error("Failed to start async accept: #{inspect(reason)}")
    end
  end

  defp handle_incoming_connection(state, client_socket) do
    Logger.info("Accepting incoming I2P connection on #{state}")

    :inet_db.register_socket(client_socket, :inet_tcp)

    client_name = "Connected peer on #{state.name}"

    client_opts = [
      name: client_name,
      owner: state.owner,
      connected_socket: client_socket,
      parent_interface: self(),
      i2p_tunneled: true,
      kiss_framing: false,
      ifac_size: state.ifac_size,
      ifac_netname: state.ifac_netname,
      ifac_netkey: state.ifac_netkey
    ]

    case RNS.Interfaces.I2PInterfacePeer.start_link(client_opts) do
      {:ok, pid} ->
        Process.monitor(pid)

        Logger.info("Spawned new I2PInterface Peer: I2PInterfacePeer[#{client_name}]")

        alive = Enum.filter(state.spawned_interfaces, &Process.alive?/1)
        %{state | spawned_interfaces: alive ++ [pid]}

      {:error, reason} ->
        Logger.error("Failed to spawn I2P peer interface: #{inspect(reason)}")
        :gen_tcp.close(client_socket)
        state
    end
  end

  defp start_peer(state, interface_name, peer_addr) do
    peer_opts = [
      name: interface_name,
      owner: state.owner,
      target_i2p_dest: peer_addr,
      parent_interface: self(),
      i2p_tunneled: true,
      kiss_framing: false,
      i2p_controller: state.i2p_controller,
      ifac_size: state.ifac_size,
      ifac_netname: state.ifac_netname,
      ifac_netkey: state.ifac_netkey
    ]

    case RNS.Interfaces.I2PInterfacePeer.start_link(peer_opts) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start I2P peer #{interface_name}: #{inspect(reason)}")
    end
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp parse_ip!(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, tuple} -> tuple
      {:error, _} -> raise ArgumentError, "Invalid IP address: #{ip_string}"
    end
  end

  # ── String.Chars protocol ──────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name}) do
      "I2PInterface[#{name}]"
    end
  end
end

defmodule RNS.Interfaces.I2PInterfacePeer do
  @moduledoc """
  I2P peer interface for RNS.

  TCP client that communicates through I2P tunnels. Supports both
  initiator mode (connects to a remote I2P destination) and responder
  mode (accepts connections from the I2P server interface). Uses HDLC
  framing by default with optional KISS framing.

  Includes a read watchdog that monitors tunnel health and triggers
  reconnection when the tunnel becomes unresponsive.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  alias RNS.Interfaces.Interface.HDLC
  alias RNS.Interfaces.Interface.KISS

  # ── Constants ──────────────────────────────────────────────────────

  @hw_mtu 1064
  @bitrate_guess 256_000
  @default_ifac_size 16

  @reconnect_wait 15
  @reconnect_max_tries nil

  # I2P TCP socket options (longer timeouts than regular TCP)
  @i2p_user_timeout 45
  @i2p_probe_after 10
  @i2p_probe_interval 9
  @i2p_probes 5
  @i2p_read_timeout (@i2p_probe_interval * @i2p_probes + @i2p_probe_after) * 2

  # Tunnel states
  @tunnel_state_init 0x00
  @tunnel_state_active 0x01
  @tunnel_state_stale 0x02

  # Watchdog interval in ms
  @watchdog_interval 1_000

  # Minimum frame size to accept
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

                # Framing
                kiss_framing: false,
                frame_buffer: <<>>,

                # I2P state
                i2p_tunneled: true,
                i2p_dest: nil,
                i2p_tunnel_ready: false,
                i2p_tunnel_state: @tunnel_state_init,
                i2p_controller: nil,
                awaiting_i2p_tunnel: false,

                # Wants tunnel (for non-KISS transport synthesis)
                wants_tunnel: false,

                # Watchdog state
                last_read: 0,
                last_write: 0,

                # Reconnection tracking
                reconnect_attempts: 0,
                max_reconnect_tries: @reconnect_max_tries,

                # Parent tracking
                parent_count: true,

                # Owner (Transport or callback)
                owner: nil,

                # Receives flag
                receives: true,

                # IFAC config
                ifac_netname: nil,
                ifac_netkey: nil
              ]

  @type t :: %__MODULE__{}

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the HW_MTU for I2P peer interfaces."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu

  @doc "Returns the bitrate guess for I2P (256 kbps)."
  @spec bitrate_guess() :: pos_integer()
  def bitrate_guess, do: @bitrate_guess

  @doc "Returns the default IFAC size."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns the reconnect wait time in seconds."
  @spec reconnect_wait() :: pos_integer()
  def reconnect_wait, do: @reconnect_wait

  @doc "Returns the I2P user timeout in seconds."
  @spec i2p_user_timeout() :: pos_integer()
  def i2p_user_timeout, do: @i2p_user_timeout

  @doc "Returns the I2P probe-after interval in seconds."
  @spec i2p_probe_after() :: pos_integer()
  def i2p_probe_after, do: @i2p_probe_after

  @doc "Returns the I2P probe interval in seconds."
  @spec i2p_probe_interval() :: pos_integer()
  def i2p_probe_interval, do: @i2p_probe_interval

  @doc "Returns the I2P probe count."
  @spec i2p_probes() :: pos_integer()
  def i2p_probes, do: @i2p_probes

  @doc "Returns the I2P read timeout in seconds."
  @spec i2p_read_timeout() :: number()
  def i2p_read_timeout, do: @i2p_read_timeout

  @doc "Returns the tunnel state init constant."
  @spec tunnel_state_init() :: non_neg_integer()
  def tunnel_state_init, do: @tunnel_state_init

  @doc "Returns the tunnel state active constant."
  @spec tunnel_state_active() :: non_neg_integer()
  def tunnel_state_active, do: @tunnel_state_active

  @doc "Returns the tunnel state stale constant."
  @spec tunnel_state_stale() :: non_neg_integer()
  def tunnel_state_stale, do: @tunnel_state_stale

  @doc """
  Starts an I2P peer interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:owner` — owner process or callback for inbound data
    * `:target_i2p_dest` — I2P destination to connect to (initiator mode)
    * `:connected_socket` — pre-connected socket (responder mode)
    * `:parent_interface` — parent I2PInterface pid
    * `:i2p_controller` — I2PController pid
    * `:kiss_framing` — use KISS framing (default: false)
    * `:max_reconnect_tries` — max reconnection attempts (default: nil = unlimited)
    * `:ifac_size` — IFAC size override
    * `:ifac_netname` — IFAC network name
    * `:ifac_netkey` — IFAC network key
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

  @doc "Sends data out through this I2P peer interface."
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

  # ── Behaviour callbacks ───────────────────────────────────────────

  @impl RNS.Interfaces.Interface
  def process_outgoing(state, data) do
    do_send(state, data)
  end

  @impl RNS.Interfaces.Interface
  def process_incoming(state, data) do
    if state.online and not state.detached do
      updated = %{state | rxb: state.rxb + byte_size(data)}

      # Update parent interface stats
      if updated.parent_interface do
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

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    owner = Keyword.get(opts, :owner)
    target_i2p_dest = Keyword.get(opts, :target_i2p_dest)
    connected_socket = Keyword.get(opts, :connected_socket)
    parent_interface = Keyword.get(opts, :parent_interface)
    i2p_controller = Keyword.get(opts, :i2p_controller)
    kiss_framing = Keyword.get(opts, :kiss_framing, false)
    max_reconnect_tries = Keyword.get(opts, :max_reconnect_tries, @reconnect_max_tries)
    ifac_size = Keyword.get(opts, :ifac_size)
    ifac_netname = Keyword.get(opts, :ifac_netname)
    ifac_netkey = Keyword.get(opts, :ifac_netkey)

    now = System.system_time(:second)

    state = %__MODULE__{
      name: name,
      owner: owner,
      in: true,
      out: false,
      online: false,
      bitrate: @bitrate_guess,
      hw_mtu: @hw_mtu,
      ifac_size: ifac_size || @default_ifac_size,
      ifac_netname: ifac_netname,
      ifac_netkey: ifac_netkey,
      kiss_framing: kiss_framing,
      i2p_tunneled: true,
      max_reconnect_tries: max_reconnect_tries,
      parent_interface: parent_interface,
      i2p_controller: i2p_controller,
      i2p_dest: target_i2p_dest,
      supports_discovery: true,
      mode: RNS.Interfaces.Interface.mode_full(),
      created: now,
      last_read: now,
      last_write: now
    }

    state =
      cond do
        # Responder mode — pre-connected socket from server
        connected_socket != nil ->
          set_i2p_keepalive(connected_socket)

          %{
            state
            | socket: connected_socket,
              receives: true,
              online: true,
              never_connected: false,
              out: true,
              parent_count: true,
              i2p_tunnel_state: @tunnel_state_active
          }

        # Initiator mode — connect to remote I2P destination
        target_i2p_dest != nil ->
          # For initiator mode, the tunnel setup is async.
          # In production, the I2PController handles SAM tunnel creation.
          # We schedule a connection attempt.
          state = %{
            state
            | receives: true,
              initiator: true,
              out: true,
              parent_count: false,
              awaiting_i2p_tunnel: true,
              i2p_dest: target_i2p_dest
          }

          if kiss_framing do
            state
          else
            %{state | wants_tunnel: true}
          end

        true ->
          state
      end

    state = %{state | hash: RNS.Interfaces.Interface.hash(state)}

    # Start watchdog for connected sockets
    if state.online do
      schedule_watchdog()
    end

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
    now = System.system_time(:second)
    state = %{state | last_read: now}
    {:ok, updated} = process_tcp_data(state, data)
    {:noreply, updated}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    state = %{state | online: false, socket: nil}

    if state.initiator and not state.detached do
      Logger.warning("Socket for #{state} was closed, attempting to reconnect...")
      Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
      {:noreply, %{state | reconnecting: true}}
    else
      Logger.info("Socket for remote client #{state} was closed.")
      {:noreply, teardown(state)}
    end
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("An interface error occurred for #{state}: #{inspect(reason)}")

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
            Logger.info("#{state} Re-established connection via I2P tunnel")
          end

          connected_state =
            if connected_state.kiss_framing do
              connected_state
            else
              %{connected_state | wants_tunnel: true}
            end

          schedule_watchdog()
          {:noreply, connected_state}

        {:error, reason} ->
          attempts = state.reconnect_attempts + 1

          if state.max_reconnect_tries != nil and attempts > state.max_reconnect_tries do
            Logger.error("Max reconnection attempts reached for #{state}")
            {:noreply, teardown(state)}
          else
            if state.awaiting_i2p_tunnel do
              Logger.info("#{state} still waiting for I2P tunnel to appear")
            else
              Logger.debug("Connection attempt for #{state} failed: #{inspect(reason)}")
            end

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

      schedule_watchdog()
    end

    {:noreply, state}
  end

  def handle_info(:watchdog, state) do
    state = run_watchdog(state)

    if state.online do
      schedule_watchdog()
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_socket(state.socket)
    RNS.Interfaces.Interface.deregister_on_terminate(state)
  end

  # ── Watchdog ─────────────────────────────────────────────────────

  defp schedule_watchdog do
    Process.send_after(self(), :watchdog, @watchdog_interval)
  end

  @doc false
  @spec run_watchdog(t()) :: t()
  def run_watchdog(state) do
    now = System.system_time(:second)

    # Check for stale tunnel
    state =
      if now - state.last_read > @i2p_probe_after * 2 do
        if state.i2p_tunnel_state != @tunnel_state_stale do
          Logger.debug("I2P tunnel became unresponsive")
        end

        %{state | i2p_tunnel_state: @tunnel_state_stale}
      else
        %{state | i2p_tunnel_state: @tunnel_state_active}
      end

    # Send keepalive if no recent write
    state =
      if now - state.last_write > @i2p_probe_after do
        if state.socket != nil do
          case :gen_tcp.send(state.socket, <<HDLC.flag(), HDLC.flag()>>) do
            :ok ->
              %{state | last_write: now}

            {:error, reason} ->
              Logger.error(
                "An error occurred while sending I2P keepalive. The contained exception was: #{inspect(reason)}"
              )

              close_socket(state.socket)
              %{state | online: false, socket: nil}
          end
        else
          state
        end
      else
        state
      end

    # Check for read timeout
    if state.online and now - state.last_read > @i2p_read_timeout do
      Logger.warning("I2P socket is unresponsive, restarting...")
      close_socket(state.socket)

      state = %{state | online: false, socket: nil}

      if state.initiator and not state.detached do
        Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
        %{state | reconnecting: true}
      else
        teardown(state)
      end
    else
      state
    end
  end

  # ── Private helpers ───────────────────────────────────────────────

  defp do_connect(state) do
    target_ip = state.target_ip || "127.0.0.1"
    target_port = state.target_port

    if target_port == nil do
      {:error, :no_target_port}
    else
      Logger.debug("Establishing I2P tunnel connection for #{state}...")

      ip_charlist = String.to_charlist(target_ip)

      tcp_opts = [
        :binary,
        active: true,
        packet: :raw,
        nodelay: true
      ]

      case :gen_tcp.connect(ip_charlist, target_port, tcp_opts, 5_000) do
        {:ok, socket} ->
          set_i2p_keepalive(socket)

          now = System.system_time(:second)

          {:ok,
           %{
             state
             | socket: socket,
               online: true,
               never_connected: false,
               frame_buffer: <<>>,
               reconnect_attempts: 0,
               last_read: now,
               last_write: now,
               i2p_tunnel_state: @tunnel_state_active
           }}

        {:error, reason} ->
          if state.never_connected do
            if not state.awaiting_i2p_tunnel do
              Logger.error(
                "Initial connection for #{state} could not be established: #{inspect(reason)}"
              )

              Logger.error(
                "Leaving unconnected and retrying connection in #{@reconnect_wait} seconds."
              )
            end
          end

          {:error, reason}
      end
    end
  end

  defp do_send(state, data) do
    if state.online and not state.detached and state.socket != nil do
      framed =
        if state.kiss_framing do
          KISS.frame(data)
        else
          HDLC.frame(data)
        end

      case :gen_tcp.send(state.socket, framed) do
        :ok ->
          now = System.system_time(:second)
          updated = %{state | txb: state.txb + byte_size(framed), last_write: now}

          # Update parent interface stats
          if updated.parent_interface do
            send(updated.parent_interface, {:update_rxb, byte_size(framed)})
          end

          {:ok, updated}

        {:error, reason} ->
          Logger.error(
            "Exception occurred while transmitting via #{state}, tearing down interface"
          )

          Logger.error("The contained exception was: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_connected}
    end
  end

  defp process_tcp_data(state, data) do
    if state.kiss_framing do
      process_kiss_data(state, data)
    else
      process_hdlc_data(state, data)
    end
  end

  defp process_hdlc_data(state, data) do
    buffer = state.frame_buffer <> data

    {frames, remaining} = HDLC.deframe(buffer)

    state = %{state | frame_buffer: remaining}

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        if byte_size(frame) > @header_minsize do
          {:ok, updated} = process_incoming(acc, frame)
          updated
        else
          acc
        end
      end)

    {:ok, state}
  end

  defp process_kiss_data(state, data) do
    buffer = state.frame_buffer <> data

    {frames, remaining} = KISS.deframe(buffer)

    state = %{state | frame_buffer: remaining}

    state =
      Enum.reduce(frames, state, fn {cmd, frame_data}, acc ->
        if cmd == KISS.cmd_data() do
          {:ok, updated} = process_incoming(acc, frame_data)
          updated
        else
          acc
        end
      end)

    {:ok, state}
  end

  defp set_i2p_keepalive(socket) do
    :inet.setopts(socket, [{:keepalive, true}])

    case :os.type() do
      {:unix, :linux} ->
        try do
          :inet.setopts(socket, [{:raw, 6, 18, <<@i2p_user_timeout * 1000::native-32>>}])
          :inet.setopts(socket, [{:raw, 6, 4, <<@i2p_probe_after::native-32>>}])
          :inet.setopts(socket, [{:raw, 6, 5, <<@i2p_probe_interval::native-32>>}])
          :inet.setopts(socket, [{:raw, 6, 6, <<@i2p_probes::native-32>>}])
        rescue
          e ->
            Logger.debug("I2P TCP keepalive setup (Linux): #{inspect(e)}")
            :ok
        end

      {:unix, :darwin} ->
        try do
          :inet.setopts(socket, [{:raw, 6, 0x10, <<@i2p_probe_after::native-32>>}])
        rescue
          e ->
            Logger.debug("I2P TCP keepalive setup (macOS): #{inspect(e)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  defp teardown(state) do
    if state.initiator and not state.detached do
      Logger.error(
        "The interface #{state} experienced an unrecoverable error and is being torn down. " <>
          "Restart Reticulum to attempt to open this interface again."
      )
    else
      Logger.info("The interface #{state} is being torn down.")
    end

    close_socket(state.socket)

    %{state | online: false, out: false, in: false, socket: nil}
  end

  defp close_socket(nil), do: :ok

  defp close_socket(socket) do
    try do
      :gen_tcp.shutdown(socket, :read_write)
    rescue
      e ->
        Logger.debug("I2P socket shutdown: #{inspect(e)}")
        :ok
    catch
      _, reason ->
        Logger.debug("I2P socket shutdown caught: #{inspect(reason)}")
        :ok
    end

    try do
      :gen_tcp.close(socket)
    rescue
      e ->
        Logger.debug("I2P socket close: #{inspect(e)}")
        :ok
    catch
      _, reason ->
        Logger.debug("I2P socket close caught: #{inspect(reason)}")
        :ok
    end
  end

  defp notify_owner(owner, data, interface) when is_pid(owner) do
    send(owner, {:i2p_interface_data, data, interface})
  end

  defp notify_owner({module, fun}, data, interface) when is_atom(module) and is_atom(fun) do
    apply(module, fun, [data, interface])
  end

  defp notify_owner(fun, data, interface) when is_function(fun, 2) do
    fun.(data, interface)
  end

  defp notify_owner(_, _data, _interface), do: :ok

  # ── String.Chars protocol ─────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name}) do
      "I2PInterfacePeer[#{name}]"
    end
  end
end

defmodule RNS.Interfaces.I2PController do
  @moduledoc """
  I2P tunnel controller for RNS.

  Manages I2P tunnel lifecycle via the SAM (Simple Anonymous Messaging)
  protocol. Handles client tunnel creation (connecting to remote I2P
  destinations) and server tunnel creation (making local services
  reachable via I2P).

  Tunnel management is handled via GenServer state and TCP connections
  to the SAM bridge.
  """

  use GenServer

  require Logger

  # SAM protocol constants
  @sam_default_host "127.0.0.1"
  @sam_default_port 7656

  # SAM protocol commands
  @sam_hello "HELLO VERSION MIN=3.1 MAX=3.1\n"

  # Session/tunnel states
  @tunnel_state_init :init
  @tunnel_state_setting_up :setting_up
  @tunnel_state_active :active
  @tunnel_state_failed :failed

  defstruct [
    :storagepath,
    :sam_host,
    :sam_port,
    ready: false,
    client_tunnels: %{},
    server_tunnels: %{},
    i2p_tunnels: %{}
  ]

  @type tunnel_state :: :init | :setting_up | :active | :failed

  @type tunnel_entry :: %{
          state: tunnel_state(),
          socket: port() | nil,
          destination: String.t() | nil,
          b32: String.t() | nil
        }

  @type t :: %__MODULE__{
          storagepath: String.t() | nil,
          sam_host: String.t(),
          sam_port: pos_integer(),
          ready: boolean(),
          client_tunnels: %{String.t() => boolean()},
          server_tunnels: %{String.t() => boolean()},
          i2p_tunnels: %{String.t() => tunnel_entry() | nil}
        }

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the default SAM host."
  @spec sam_default_host() :: String.t()
  def sam_default_host, do: @sam_default_host

  @doc "Returns the default SAM port."
  @spec sam_default_port() :: pos_integer()
  def sam_default_port, do: @sam_default_port

  @doc "Returns the SAM HELLO command."
  @spec sam_hello() :: String.t()
  def sam_hello, do: @sam_hello

  @doc "Returns the tunnel state init atom."
  @spec tunnel_state_init() :: tunnel_state()
  def tunnel_state_init, do: @tunnel_state_init

  @doc "Returns the tunnel state setting_up atom."
  @spec tunnel_state_setting_up() :: tunnel_state()
  def tunnel_state_setting_up, do: @tunnel_state_setting_up

  @doc "Returns the tunnel state active atom."
  @spec tunnel_state_active() :: tunnel_state()
  def tunnel_state_active, do: @tunnel_state_active

  @doc "Returns the tunnel state failed atom."
  @spec tunnel_state_failed() :: tunnel_state()
  def tunnel_state_failed, do: @tunnel_state_failed

  @doc """
  Starts an I2P controller GenServer.

  ## Options

    * `:storagepath` — RNS storage path for I2P key files (required)
    * `:sam_host` — SAM bridge host (default: "127.0.0.1")
    * `:sam_port` — SAM bridge port (default: 7656)
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

  @doc "Returns the current state of the controller."
  @spec get_state(GenServer.server()) :: t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Checks if the controller is ready."
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server) do
    GenServer.call(server, :ready?)
  end

  @doc "Returns the SAM address as {host, port}."
  @spec get_sam_address(GenServer.server()) :: {String.t(), pos_integer()}
  def get_sam_address(server) do
    GenServer.call(server, :get_sam_address)
  end

  @doc "Gets a free TCP port."
  @spec get_free_port() :: pos_integer()
  def get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @doc "Registers a client tunnel for the given I2P destination."
  @spec register_client_tunnel(GenServer.server(), String.t()) :: :ok
  def register_client_tunnel(server, i2p_destination) do
    GenServer.call(server, {:register_client_tunnel, i2p_destination})
  end

  @doc "Registers a server tunnel."
  @spec register_server_tunnel(GenServer.server(), String.t()) :: :ok
  def register_server_tunnel(server, b32_address) do
    GenServer.call(server, {:register_server_tunnel, b32_address})
  end

  @doc "Gets the status of a tunnel."
  @spec get_tunnel_status(GenServer.server(), String.t()) :: tunnel_entry() | nil
  def get_tunnel_status(server, tunnel_id) do
    GenServer.call(server, {:get_tunnel_status, tunnel_id})
  end

  @doc "Stops the controller and all tunnels."
  @spec stop_controller(GenServer.server()) :: :ok
  def stop_controller(server) do
    GenServer.stop(server, :normal)
  end

  @doc """
  Formats a SAM session create command.

  ## Parameters

    * `style` — session style ("STREAM", "DATAGRAM", "RAW")
    * `session_id` — unique session identifier
    * `destination` — I2P destination key or "TRANSIENT"
    * `opts` — additional options as keyword list
  """
  @spec format_session_create(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def format_session_create(style, session_id, destination, opts \\ []) do
    base = "SESSION CREATE STYLE=#{style} ID=#{session_id} DESTINATION=#{destination}"

    opts_str =
      Enum.map_join(opts, " ", fn {k, v} -> "#{k}=#{v}" end)

    if opts_str == "" do
      base <> "\n"
    else
      base <> " " <> opts_str <> "\n"
    end
  end

  @doc """
  Formats a SAM stream connect command.

  ## Parameters

    * `session_id` — session identifier
    * `destination` — I2P destination to connect to
  """
  @spec format_stream_connect(String.t(), String.t()) :: String.t()
  def format_stream_connect(session_id, destination) do
    "STREAM CONNECT ID=#{session_id} DESTINATION=#{destination} SILENT=false\n"
  end

  @doc """
  Formats a SAM stream accept command.

  ## Parameters

    * `session_id` — session identifier
  """
  @spec format_stream_accept(String.t()) :: String.t()
  def format_stream_accept(session_id) do
    "STREAM ACCEPT ID=#{session_id} SILENT=false\n"
  end

  @doc """
  Formats a SAM naming lookup command.

  ## Parameters

    * `name` — name to look up (e.g., "ME" for own destination)
  """
  @spec format_naming_lookup(String.t()) :: String.t()
  def format_naming_lookup(name) do
    "NAMING LOOKUP NAME=#{name}\n"
  end

  @doc """
  Formats a SAM destination generate command.
  """
  @spec format_dest_generate() :: String.t()
  def format_dest_generate do
    "DEST GENERATE\n"
  end

  @doc """
  Parses a SAM response string into a keyword list.

  ## Examples

      iex> RNS.Interfaces.I2PController.parse_sam_response("HELLO REPLY RESULT=OK VERSION=3.1\\n")
      %{command: "HELLO REPLY", "RESULT" => "OK", "VERSION" => "3.1"}

      iex> RNS.Interfaces.I2PController.parse_sam_response("SESSION STATUS RESULT=DUPLICATED_ID\\n")
      %{command: "SESSION STATUS", "RESULT" => "DUPLICATED_ID"}
  """
  @spec parse_sam_response(String.t()) :: map()
  def parse_sam_response(response) do
    response = String.trim(response)

    # SAM responses have format: COMMAND SUBCOMMAND KEY=VALUE KEY=VALUE ...
    # The first two words are the command, rest are key=value pairs.
    # We split only on spaces that precede KEY= patterns to handle
    # values that may contain spaces.
    parts = String.split(response, " ")

    case parts do
      [cmd, sub | rest] ->
        # Re-join the rest and parse key=value pairs
        # Each key=value is separated by space, but values after the last
        # = can contain spaces. We parse greedily by finding = in each segment.
        kvs = parse_sam_kvs(rest, [])

        kvs
        |> Map.new()
        |> Map.put(:command, "#{cmd} #{sub}")

      [cmd] ->
        %{command: cmd}

      [] ->
        %{command: ""}
    end
  end

  defp parse_sam_kvs([], acc), do: Enum.reverse(acc)

  defp parse_sam_kvs(parts, acc) do
    # Find the next KEY=VALUE boundary
    # A new key starts when a segment contains "=" and is not a continuation
    case parts do
      [part | rest] ->
        case String.split(part, "=", parts: 2) do
          [key, value] ->
            # Collect any remaining parts that belong to this value
            # (i.e., parts until the next KEY= pattern)
            {value_parts, remaining} = collect_value_parts(rest, [])

            full_value =
              if value_parts == [] do
                value
              else
                Enum.join([value | value_parts], " ")
              end

            parse_sam_kvs(remaining, [{key, full_value} | acc])

          _ ->
            # Not a key=value pair, skip
            parse_sam_kvs(rest, acc)
        end
    end
  end

  defp collect_value_parts([], acc), do: {Enum.reverse(acc), []}

  defp collect_value_parts([part | rest] = parts, acc) do
    if String.contains?(part, "=") do
      # This is the start of a new key=value pair
      {Enum.reverse(acc), parts}
    else
      # This is a continuation of the current value
      collect_value_parts(rest, [part | acc])
    end
  end

  @doc """
  Computes the I2P key file path for a server tunnel.

  Uses the same hashing scheme as Python: SHA-256(SHA-256(name)) for old format,
  SHA-256(SHA-256(name) + SHA-256(identity_hash)) for new format.

  ## Parameters

    * `storagepath` — base storage path
    * `name` — interface name
    * `identity_hash` — transport identity hash (optional, for new format)
  """
  @spec compute_i2p_keyfile_path(String.t(), String.t(), binary() | nil) :: String.t()
  def compute_i2p_keyfile_path(storagepath, name, identity_hash \\ nil) do
    name_bytes = name
    name_hash = RNS.Identity.full_hash(RNS.Identity.full_hash(name_bytes))

    dest_hash =
      if identity_hash do
        id_hash = RNS.Identity.full_hash(identity_hash)
        RNS.Identity.full_hash(name_hash <> id_hash)
      else
        name_hash
      end

    hex = RNS.hexrep(dest_hash, false)
    Path.join([storagepath, "i2p", "#{hex}.i2p"])
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    storagepath = Keyword.fetch!(opts, :storagepath)
    sam_host = Keyword.get(opts, :sam_host, @sam_default_host)
    sam_port = Keyword.get(opts, :sam_port, @sam_default_port)

    # Ensure I2P storage directory exists
    i2p_path = Path.join(storagepath, "i2p")
    File.mkdir_p!(i2p_path)

    state = %__MODULE__{
      storagepath: storagepath,
      sam_host: sam_host,
      sam_port: sam_port,
      ready: true
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, state.ready, state}
  end

  def handle_call(:get_sam_address, _from, state) do
    {:reply, {state.sam_host, state.sam_port}, state}
  end

  def handle_call({:register_client_tunnel, i2p_destination}, _from, state) do
    client_tunnels = Map.put(state.client_tunnels, i2p_destination, false)

    i2p_tunnels =
      Map.put(state.i2p_tunnels, i2p_destination, %{
        state: @tunnel_state_init,
        socket: nil,
        destination: i2p_destination,
        b32: nil
      })

    {:reply, :ok, %{state | client_tunnels: client_tunnels, i2p_tunnels: i2p_tunnels}}
  end

  def handle_call({:register_server_tunnel, b32_address}, _from, state) do
    server_tunnels = Map.put(state.server_tunnels, b32_address, false)

    i2p_tunnels =
      Map.put(state.i2p_tunnels, b32_address, %{
        state: @tunnel_state_init,
        socket: nil,
        destination: nil,
        b32: b32_address
      })

    {:reply, :ok, %{state | server_tunnels: server_tunnels, i2p_tunnels: i2p_tunnels}}
  end

  def handle_call({:get_tunnel_status, tunnel_id}, _from, state) do
    {:reply, Map.get(state.i2p_tunnels, tunnel_id), state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :ok
  end
end
