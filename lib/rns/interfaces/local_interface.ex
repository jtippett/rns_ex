defmodule RNS.Interfaces.LocalInterface do
  @moduledoc """
  Local network interfaces for RNS shared instance communication.

  Provides `RNS.Interfaces.LocalClientInterface` (connects to the local
  shared RNS instance) and `RNS.Interfaces.LocalServerInterface` (listens
  for local client connections on the shared instance).

  Uses HDLC framing over TCP on localhost (or Unix domain sockets where
  supported). Designed for daemon-to-client communication within a single
  host.
  """

  # Shared HW_MTU constant for both client and server
  @hw_mtu 262_144

  @doc "Returns the default HW_MTU for local interfaces."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu
end

defmodule RNS.Interfaces.LocalClientInterface do
  @moduledoc """
  Local client interface for RNS shared instance communication.

  Connects to the local shared RNS daemon via TCP on localhost or Unix
  domain socket. Uses HDLC framing. Supports automatic reconnection
  when the shared instance connection is lost. Can also wrap a
  pre-connected socket (when spawned by `RNS.Interfaces.LocalServerInterface`).
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  alias RNS.Interfaces.Interface.HDLC

  # ── Constants ──────────────────────────────────────────────────────

  @bitrate 1_000_000_000
  @reconnect_wait 8
  @header_minsize 19

  defstruct default_fields() ++
              [
                # TCP connection
                socket: nil,
                target_ip: nil,
                target_port: nil,
                frame_buffer: <<>>,

                # Socket path for Unix domain sockets
                socket_path: nil,

                # Shared instance state
                is_connected_to_shared_instance: false,

                # Connection tracking
                reconnecting: false,
                never_connected: true,

                # Owner (Transport or callback)
                owner: nil,

                # Receives flag
                receives: false
              ]

  @type t :: %__MODULE__{}

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the reconnect wait time in seconds."
  @spec reconnect_wait() :: pos_integer()
  def reconnect_wait, do: @reconnect_wait

  @doc "Returns the HEADER_MINSIZE constant."
  @spec header_minsize() :: pos_integer()
  def header_minsize, do: @header_minsize

  @doc "Returns the bitrate for local interfaces (1 Gbps)."
  @spec bitrate_const() :: pos_integer()
  def bitrate_const, do: @bitrate

  @doc """
  Starts a local client interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:owner` — owner process or callback for inbound data
    * `:target_port` — TCP port on localhost to connect to
    * `:socket_path` — Unix domain socket path (alternative to TCP)
    * `:connected_socket` — pre-connected socket (for server-spawned clients)
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
        # If a pre-connected socket was provided, transfer ownership and activate
        if connected_socket != nil do
          :gen_tcp.controlling_process(connected_socket, pid)
          send(pid, :activate_socket)
        end

        result

      other ->
        other
    end
  end

  @doc "Sends data out through this local interface."
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
    updated = %{state | rxb: state.rxb + byte_size(data)}

    # Update parent interface stats
    updated =
      if updated.parent_interface != nil do
        updated
      else
        updated
      end

    if state.owner do
      notify_owner(state.owner, data, updated)
    end

    {:ok, updated}
  end

  @impl RNS.Interfaces.Interface
  def detach(%__MODULE__{} = state) do
    close_socket(state.socket)
    :ok
  end

  @doc """
  LocalClientInterface should never ingress limit.
  Matches Python's `should_ingress_limit` returning False.
  """
  @spec should_ingress_limit(t()) :: false
  def should_ingress_limit(_state), do: false

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    owner = Keyword.get(opts, :owner)
    target_port = Keyword.get(opts, :target_port)
    socket_path = Keyword.get(opts, :socket_path)
    connected_socket = Keyword.get(opts, :connected_socket)
    out = Keyword.get(opts, :out, false)

    state = %__MODULE__{
      name: name,
      owner: owner,
      in: true,
      out: out,
      online: false,
      bitrate: @bitrate,
      hw_mtu: RNS.Interfaces.LocalInterface.hw_mtu(),
      autoconfigure_mtu: true,
      mode: RNS.Interfaces.Interface.mode_full(),
      created: System.system_time(:second)
    }

    state =
      cond do
        # Pre-connected socket (spawned by server)
        connected_socket != nil ->
          %{
            state
            | socket: connected_socket,
              receives: true,
              target_ip: nil,
              target_port: nil,
              online: true,
              never_connected: false,
              is_connected_to_shared_instance: false
          }

        # Unix domain socket path
        socket_path != nil ->
          state = %{
            state
            | socket_path: socket_path,
              receives: true,
              target_ip: nil,
              target_port: nil
          }

          case do_connect(state) do
            {:ok, connected_state} ->
              connected_state

            {:error, _reason} ->
              Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
              state
          end

        # TCP port on localhost
        target_port != nil ->
          target_port =
            if is_binary(target_port), do: String.to_integer(target_port), else: target_port

          state = %{
            state
            | target_ip: "127.0.0.1",
              target_port: target_port,
              receives: true
          }

          case do_connect(state) do
            {:ok, connected_state} ->
              connected_state

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
    {:ok, updated} = process_hdlc_data(state, data)
    {:noreply, updated}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    state = %{state | online: false, socket: nil}

    if state.is_connected_to_shared_instance and not state.detached do
      Logger.warning("Socket for #{format_name(state)} was closed, attempting to reconnect...")
      Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
      {:noreply, %{state | reconnecting: true}}
    else
      # Non-shared-instance clients (server-spawned) stop on socket close
      {:stop, :normal, teardown(state, true)}
    end
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("An interface error occurred for #{format_name(state)}: #{inspect(reason)}")
    close_socket(state.socket)
    {:noreply, teardown(%{state | online: false, socket: nil})}
  end

  def handle_info(:reconnect, state) do
    if state.detached do
      {:noreply, state}
    else
      if state.is_connected_to_shared_instance do
        case do_connect(state) do
          {:ok, connected_state} ->
            connected_state = %{connected_state | reconnecting: false}

            if not state.never_connected do
              Logger.info("Reconnected socket for #{format_name(connected_state)}.")
            end

            {:noreply, connected_state}

          {:error, reason} ->
            Logger.debug(
              "Connection attempt for #{format_name(state)} failed: #{inspect(reason)}"
            )

            Process.send_after(self(), :reconnect, @reconnect_wait * 1000)
            {:noreply, state}
        end
      else
        Logger.error("Attempt to reconnect on a non-initiator shared local interface.")
        {:noreply, state}
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

  def handle_info({:set_field, field, value}, state) when is_atom(field) do
    {:noreply, Map.put(state, field, value)}
  end

  def handle_info({:process_outgoing, raw}, state) when is_binary(raw) do
    process_outgoing(state, raw)
    {:noreply, %{state | txb: state.txb + byte_size(raw)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:update_connection_info, ip, port, parent_name, parent_bitrate}, state) do
    state = %{
      state
      | target_ip: ip,
        target_port: port,
        parent_interface: parent_name,
        bitrate: parent_bitrate
    }

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

  # ── Private helpers ───────────────────────────────────────────────

  defp do_connect(state) do
    cond do
      state.socket_path != nil ->
        # Unix domain socket connection
        case :gen_tcp.connect({:local, state.socket_path}, 0, [
               :binary,
               active: true,
               packet: :raw
             ]) do
          {:ok, socket} ->
            {:ok,
             %{
               state
               | socket: socket,
                 online: true,
                 never_connected: false,
                 is_connected_to_shared_instance: true,
                 frame_buffer: <<>>
             }}

          {:error, reason} ->
            {:error, reason}
        end

      state.target_ip != nil and state.target_port != nil ->
        # TCP connection on localhost
        ip_charlist = String.to_charlist(state.target_ip)

        tcp_opts = [
          :binary,
          active: true,
          packet: :raw,
          nodelay: true
        ]

        case :gen_tcp.connect(ip_charlist, state.target_port, tcp_opts, 5_000) do
          {:ok, socket} ->
            {:ok,
             %{
               state
               | socket: socket,
                 online: true,
                 never_connected: false,
                 is_connected_to_shared_instance: true,
                 frame_buffer: <<>>
             }}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :no_target}
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

  defp process_hdlc_data(state, data) do
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

  defp teardown(state, nowarning \\ false) do
    if not nowarning do
      Logger.error(
        "The interface #{format_name(state)} experienced an unrecoverable error and is being torn down. " <>
          "Restart Reticulum to attempt to open this interface again."
      )
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
    send(owner, {:local_interface_data, data, interface})
  end

  defp notify_owner({module, fun}, data, interface) when is_atom(module) and is_atom(fun) do
    apply(module, fun, [data, interface])
  end

  defp notify_owner(fun, data, interface) when is_function(fun, 2) do
    fun.(data, interface)
  end

  defp notify_owner(_, _data, _interface), do: :ok

  defp format_name(state) do
    cond do
      state.socket_path != nil ->
        "LocalInterface[#{state.socket_path}]"

      state.target_port != nil ->
        "LocalInterface[#{state.target_port}]"

      true ->
        "LocalInterface[#{state.name}]"
    end
  end

  # ── String.Chars protocol ─────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{socket_path: path}) when is_binary(path) do
      "LocalInterface[#{path}]"
    end

    def to_string(%{target_port: port}) when not is_nil(port) do
      "LocalInterface[#{port}]"
    end

    def to_string(%{name: name}) do
      "LocalInterface[#{name}]"
    end
  end
end

defmodule RNS.Interfaces.LocalServerInterface do
  @moduledoc """
  Local server interface for the RNS shared instance.

  Listens on localhost TCP (or Unix domain socket) and spawns
  `RNS.Interfaces.LocalClientInterface` GenServers for each incoming
  connection. The server itself does not directly process packets —
  all data flows through spawned client interfaces.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  @bitrate 1_000_000_000

  defstruct Keyword.merge(default_fields(), spawned_interfaces: []) ++
              [
                # Server config
                bind_ip: nil,
                bind_port: nil,
                listen_socket: nil,

                # Unix domain socket path
                socket_path: nil,

                # Client tracking
                clients: 0,

                # Owner (Transport or callback)
                owner: nil,

                # Receives flag
                receives: false,

                # Shared instance flag
                is_local_shared_instance: false
              ]

  @type t :: %__MODULE__{}

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the bitrate for local server interfaces (1 Gbps)."
  @spec bitrate_const() :: pos_integer()
  def bitrate_const, do: @bitrate

  @doc """
  Starts a local server interface GenServer.

  ## Options

    * `:name` — interface name (default: "Reticulum")
    * `:owner` — owner process or callback for inbound data
    * `:bindport` — TCP port on localhost to listen on
    * `:socket_path` — Unix domain socket path (alternative to TCP)
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

  # ── Behaviour callbacks ───────────────────────────────────────────

  @impl RNS.Interfaces.Interface
  def process_outgoing(_state, _data) do
    # Server interfaces don't directly process outgoing data
    # Matches Python: pass
    :ok
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

  @doc """
  Track received announces from spawned interfaces.
  Matches Python's `received_announce(from_spawned=False)`.
  """
  @spec received_announce(t(), boolean()) :: t()
  def received_announce(state, from_spawned \\ false) do
    if from_spawned do
      updated_deque = state.ia_freq_deque ++ [System.system_time(:second)]
      %{state | ia_freq_deque: updated_deque}
    else
      state
    end
  end

  @doc """
  Track sent announces from spawned interfaces.
  Matches Python's `sent_announce(from_spawned=False)`.
  """
  @spec sent_announce(t(), boolean()) :: t()
  def sent_announce(state, from_spawned \\ false) do
    if from_spawned do
      updated_deque = state.oa_freq_deque ++ [System.system_time(:second)]
      %{state | oa_freq_deque: updated_deque}
    else
      state
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, "Reticulum")
    owner = Keyword.get(opts, :owner)
    bindport = Keyword.get(opts, :bindport)
    socket_path = Keyword.get(opts, :socket_path)
    out = Keyword.get(opts, :out, false)

    state = %__MODULE__{
      name: name,
      owner: owner,
      in: true,
      out: out,
      online: false,
      bitrate: @bitrate,
      hw_mtu: RNS.Interfaces.LocalInterface.hw_mtu(),
      autoconfigure_mtu: true,
      mode: RNS.Interfaces.Interface.mode_full(),
      is_local_shared_instance: true,
      created: System.system_time(:second)
    }

    result =
      cond do
        socket_path != nil ->
          # Unix domain socket listener
          do_listen_unix(state, socket_path)

        bindport != nil ->
          # TCP listener on localhost
          do_listen_tcp(state, bindport)

        true ->
          {:error, :no_bind_config}
      end

    case result do
      {:ok, state} ->
        state = %{state | hash: RNS.Interfaces.Interface.hash(state)}
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:client_count, _from, state) do
    alive = Enum.filter(state.spawned_interfaces, &Process.alive?/1)
    actual_count = length(alive)
    state = %{state | spawned_interfaces: alive, clients: actual_count}
    {:reply, actual_count, state}
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
          RNS.Interfaces.LocalClientInterface.stop(pid)
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
         clients: 0
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
    clients = max(state.clients - 1, 0)
    {:noreply, %{state | spawned_interfaces: spawned, clients: clients}}
  end

  def handle_info({:set_field, field, value}, state) when is_atom(field) do
    {:noreply, Map.put(state, field, value)}
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

  # ── Private helpers ───────────────────────────────────────────────

  defp do_listen_tcp(state, bindport) do
    bind_ip = "127.0.0.1"

    tcp_opts = [
      :binary,
      ip: {127, 0, 0, 1},
      active: false,
      packet: :raw,
      nodelay: true,
      backlog: 128
    ]

    case :gen_tcp.listen(bindport, tcp_opts) do
      {:ok, listen_socket} ->
        accept_async(listen_socket)

        {:ok,
         %{
           state
           | bind_ip: bind_ip,
             bind_port: bindport,
             listen_socket: listen_socket,
             online: true,
             receives: true
         }}

      {:error, reason} ->
        Logger.error(
          "Could not bind local TCP socket on #{bind_ip}:#{bindport}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp do_listen_unix(state, socket_path) do
    # Remove existing socket file if it exists (only for non-abstract paths)
    if is_binary(socket_path) and not String.starts_with?(socket_path, <<0>>) and
         File.exists?(socket_path) do
      File.rm(socket_path)
    end

    tcp_opts = [
      :binary,
      active: false,
      packet: :raw,
      backlog: 128
    ]

    case :gen_tcp.listen(0, [{:ifaddr, {:local, socket_path}} | tcp_opts]) do
      {:ok, listen_socket} ->
        accept_async(listen_socket)

        {:ok,
         %{
           state
           | socket_path: socket_path,
             listen_socket: listen_socket,
             online: true,
             receives: true
         }}

      {:error, reason} ->
        Logger.error("Could not bind local Unix socket at #{inspect(socket_path)}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp accept_async(listen_socket) do
    case :prim_inet.async_accept(listen_socket, -1) do
      {:ok, _ref} -> :ok
      {:error, reason} -> Logger.error("Failed to start async accept: #{inspect(reason)}")
    end
  end

  defp handle_new_connection(state, client_socket) do
    # Register the socket so it behaves properly with gen_tcp
    :inet_db.register_socket(client_socket, :inet_tcp)

    {interface_name, client_ip, client_port} =
      case :inet.peername(client_socket) do
        {:ok, {ip, port}} ->
          {Integer.to_string(port), :inet.ntoa(ip) |> List.to_string(), port}

        {:error, _} ->
          # Unix domain socket — no peername
          name = "#{state.clients}@#{state.socket_path || "local"}"
          {name, nil, nil}
      end

    client_opts = [
      name: interface_name,
      owner: state.owner,
      connected_socket: client_socket
    ]

    case RNS.Interfaces.LocalClientInterface.start_link(client_opts) do
      {:ok, pid} ->
        Process.monitor(pid)

        # Update the spawned client with parent info
        parent_name = state.name
        parent_bitrate = state.bitrate

        GenServer.cast(
          pid,
          {:update_connection_info, client_ip, client_port, parent_name, parent_bitrate}
        )

        alive = Enum.filter(state.spawned_interfaces, &Process.alive?/1)
        clients = state.clients + 1

        %{state | spawned_interfaces: alive ++ [pid], clients: clients}

      {:error, reason} ->
        Logger.error("Failed to spawn local client interface: #{inspect(reason)}")
        :gen_tcp.close(client_socket)
        state
    end
  end

  defp format_name(state) do
    cond do
      state.socket_path != nil ->
        "Shared Instance[#{state.socket_path}]"

      state.bind_port != nil ->
        "Shared Instance[#{state.bind_port}]"

      true ->
        "Shared Instance[#{state.name}]"
    end
  end

  # ── String.Chars protocol ─────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{socket_path: path}) when is_binary(path) do
      "Shared Instance[#{path}]"
    end

    def to_string(%{bind_port: port}) when is_integer(port) do
      "Shared Instance[#{port}]"
    end

    def to_string(%{name: name}) do
      "Shared Instance[#{name}]"
    end
  end
end
