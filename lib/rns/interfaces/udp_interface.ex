defmodule RNS.Interfaces.UDPInterface do
  @moduledoc """
  UDP network interface for RNS.

  Sends and receives packets over UDP sockets. Supports separate
  bind (listen) and forward (send) addresses, broadcast mode, and
  device-based address resolution.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  @bitrate_guess 10_000_000
  @default_ifac_size 16
  @hw_mtu 1064

  defstruct default_fields() ++
              [
                # Receive config
                receives: false,
                bind_ip: nil,
                bind_port: nil,

                # Forward/send config
                forwards: false,
                forward_ip: nil,
                forward_port: nil,

                # Socket references
                recv_socket: nil,

                # Owner (Transport or callback)
                owner: nil
              ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────

  @doc "Returns the default bitrate guess for UDP interfaces."
  @spec bitrate_guess() :: pos_integer()
  def bitrate_guess, do: @bitrate_guess

  @doc "Returns the default IFAC size for UDP interfaces."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc """
  Starts a UDP interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:owner` — owner process or module for inbound data callbacks
    * `:port` — shorthand port for both bind and forward
    * `:listen_ip` / `:bind_ip` — IP address to bind for receiving
    * `:listen_port` / `:bind_port` — port to bind for receiving
    * `:forward_ip` — IP address to send data to
    * `:forward_port` — port to send data to
    * `:device` — network device name for address resolution
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

  @doc "Sends data out through this UDP interface."
  @spec send_data(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_data(server, data) do
    GenServer.call(server, {:send_data, data})
  end

  @doc "Returns the current state of the interface."
  @spec get_state(GenServer.server()) :: t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Detaches and stops the interface via GenServer call."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.call(server, :detach)
  end

  @doc """
  Resolves the IP address for a given network interface name.

  Uses `:inet.getifaddrs/0` to look up the IPv4 address.
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

  @doc """
  Resolves the broadcast address for a given network interface name.

  Uses `:inet.getifaddrs/0` to look up the IPv4 broadcast address.
  """
  @spec get_broadcast_for_if(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_broadcast_for_if(device_name) do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        device_charlist = String.to_charlist(device_name)

        case List.keyfind(ifaddrs, device_charlist, 0) do
          {_, opts} ->
            case Keyword.get(opts, :broadaddr) do
              {a, b, c, d} -> {:ok, "#{a}.#{b}.#{c}.#{d}"}
              _ -> {:error, :no_broadcast_address}
            end

          nil ->
            {:error, :device_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Behaviour callbacks ──────────────────────────────────────────

  @impl RNS.Interfaces.Interface
  def process_outgoing(state, data) do
    case do_send(state, data) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl RNS.Interfaces.Interface
  def process_incoming(state, data) do
    updated = %{state | rxb: state.rxb + byte_size(data)}

    if state.owner do
      notify_owner(state.owner, data, updated)
    end

    {:ok, updated}
  end

  @impl RNS.Interfaces.Interface
  def detach(%__MODULE__{} = state) do
    if state.recv_socket do
      :gen_udp.close(state.recv_socket)
    end

    :ok
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl GenServer
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    owner = Keyword.get(opts, :owner)
    device = Keyword.get(opts, :device)
    port = Keyword.get(opts, :port)

    bind_ip = Keyword.get(opts, :listen_ip) || Keyword.get(opts, :bind_ip)
    bind_port = Keyword.get(opts, :listen_port) || Keyword.get(opts, :bind_port)
    forward_ip = Keyword.get(opts, :forward_ip)
    forward_port = Keyword.get(opts, :forward_port)

    # If a shorthand port is given, apply to both bind and forward if not set
    bind_port = bind_port || port
    forward_port = forward_port || port

    # Device-based address resolution
    {bind_ip, forward_ip} =
      if device do
        bind_ip =
          if bind_ip do
            bind_ip
          else
            case get_broadcast_for_if(device) do
              {:ok, addr} -> addr
              _ -> bind_ip
            end
          end

        forward_ip =
          if forward_ip do
            forward_ip
          else
            case get_broadcast_for_if(device) do
              {:ok, addr} -> addr
              _ -> forward_ip
            end
          end

        {bind_ip, forward_ip}
      else
        {bind_ip, forward_ip}
      end

    state = %__MODULE__{
      name: name,
      owner: owner,
      in: true,
      out: false,
      online: false,
      bitrate: @bitrate_guess,
      hw_mtu: @hw_mtu,
      ifac_size: @default_ifac_size,
      created: System.system_time(:second)
    }

    # Open receive socket if bind address is configured
    state =
      if bind_ip && bind_port do
        ip_tuple = parse_ip!(bind_ip)

        udp_opts = [
          :binary,
          active: true,
          ip: ip_tuple,
          reuseaddr: true
        ]

        # Add broadcast option if binding to broadcast address
        udp_opts =
          if is_broadcast_address?(bind_ip) do
            [{:broadcast, true} | udp_opts]
          else
            udp_opts
          end

        case :gen_udp.open(bind_port, udp_opts) do
          {:ok, socket} ->
            %{
              state
              | receives: true,
                bind_ip: bind_ip,
                bind_port: bind_port,
                recv_socket: socket,
                online: true
            }

          {:error, reason} ->
            Logger.error(
              "UDPInterface[#{name}] could not bind to #{bind_ip}:#{bind_port}: #{inspect(reason)}"
            )

            %{state | bind_ip: bind_ip, bind_port: bind_port}
        end
      else
        state
      end

    # Configure forward address
    state =
      if forward_ip && forward_port do
        %{
          state
          | forwards: true,
            forward_ip: forward_ip,
            forward_port: forward_port,
            out: true,
            online: true
        }
      else
        state
      end

    # Cache the interface hash
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
    if state.recv_socket do
      :gen_udp.close(state.recv_socket)
    end

    {:reply, :ok, %{state | online: false, detached: true, recv_socket: nil}}
  end

  @impl GenServer
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    {:ok, updated} = process_incoming(state, data)
    {:noreply, updated}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.recv_socket do
      :gen_udp.close(state.recv_socket)
    end

    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp do_send(%{forwards: false}, _data) do
    {:error, :not_configured_for_forwarding}
  end

  defp do_send(%{forwards: true} = state, data) do
    ip_tuple = parse_ip!(state.forward_ip)

    try do
      # Open a temporary socket for sending (matches Python behavior)
      case :gen_udp.open(0, [:binary, {:broadcast, true}]) do
        {:ok, socket} ->
          :gen_udp.send(socket, ip_tuple, state.forward_port, data)
          :gen_udp.close(socket)
          {:ok, %{state | txb: state.txb + byte_size(data)}}

        {:error, reason} ->
          Logger.error("Could not transmit on UDPInterface[#{state.name}]: #{inspect(reason)}")

          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Could not transmit on UDPInterface[#{state.name}]: #{Exception.message(e)}")

        {:error, :send_failed}
    end
  end

  defp notify_owner(owner, data, interface) when is_pid(owner) do
    send(owner, {:udp_interface_data, data, interface})
  end

  defp notify_owner({module, fun}, data, interface) when is_atom(module) and is_atom(fun) do
    apply(module, fun, [data, interface])
  end

  defp notify_owner(fun, data, interface) when is_function(fun, 2) do
    fun.(data, interface)
  end

  defp notify_owner(_, _data, _interface), do: :ok

  defp parse_ip!(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, tuple} -> tuple
      {:error, _} -> raise ArgumentError, "Invalid IP address: #{ip_string}"
    end
  end

  defp is_broadcast_address?(ip_string) do
    ip_string == "255.255.255.255" or String.ends_with?(ip_string, ".255")
  end

  # ── String.Chars protocol ────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name, bind_ip: ip, bind_port: port})
        when is_binary(ip) and is_integer(port) do
      "UDPInterface[#{name}/#{ip}:#{port}]"
    end

    def to_string(%{name: name}) do
      "UDPInterface[#{name}]"
    end
  end
end
