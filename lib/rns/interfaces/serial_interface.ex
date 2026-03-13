defmodule RNS.Interfaces.SerialInterface do
  @moduledoc """
  Serial port interface for RNS.

  Sends and receives packets over a serial port using HDLC framing.
  Supports configurable baud rate, data bits, parity, and stop bits.
  Automatically reconnects on port errors.

  Uses `circuits_uart` if available, falls back to an Elixir Port-based
  implementation for testing without hardware.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  @compile {:no_warn_undefined, Circuits.UART}

  alias RNS.Interfaces.Interface.HDLC

  @max_chunk 32_768
  @default_ifac_size 8
  @hw_mtu 564
  @reconnect_wait 5_000
  @read_timeout_ms 100

  # Default serial configuration
  @default_speed 9600
  @default_databits 8
  @default_parity :none
  @default_stopbits 1

  defstruct default_fields() ++
              [
                # Serial config
                port: nil,
                speed: @default_speed,
                databits: @default_databits,
                parity: @default_parity,
                stopbits: @default_stopbits,
                timeout: @read_timeout_ms,

                # Runtime state
                uart_pid: nil,
                port_ref: nil,
                frame_buffer: <<>>,
                reconnecting: false,

                # Owner (Transport or callback)
                owner: nil,

                # Backend module (:circuits_uart or :port)
                backend: nil,

                # For testing: skip actual serial port operations
                skip_open: false
              ]

  @type parity :: :none | :even | :odd
  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────

  @doc "Returns the maximum chunk size for serial writes."
  @spec max_chunk() :: pos_integer()
  def max_chunk, do: @max_chunk

  @doc "Returns the default IFAC size for serial interfaces."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns the hardware MTU for serial interfaces."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu

  @doc "Returns the reconnect wait time in milliseconds."
  @spec reconnect_wait() :: pos_integer()
  def reconnect_wait, do: @reconnect_wait

  @doc """
  Parses a parity string to the internal atom representation.

  Accepts: "N", "none", "E", "even", "O", "odd" (case-insensitive).
  Returns `:none`, `:even`, or `:odd`.
  """
  @spec parse_parity(String.t()) :: parity()
  def parse_parity(parity) when is_binary(parity) do
    case String.downcase(parity) do
      p when p in ["e", "even"] -> :even
      p when p in ["o", "odd"] -> :odd
      _ -> :none
    end
  end

  def parse_parity(_), do: :none

  @doc """
  Checks if `circuits_uart` is available.
  """
  @spec circuits_uart_available?() :: boolean()
  def circuits_uart_available? do
    Code.ensure_loaded?(Circuits.UART)
  end

  @doc """
  Starts a Serial interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:port` — serial port path (e.g., "/dev/ttyUSB0") (required unless skip_open)
    * `:speed` — baud rate (default: 9600)
    * `:databits` — data bits (default: 8)
    * `:parity` — parity string: "N", "E", "O" (default: "N")
    * `:stopbits` — stop bits (default: 1)
    * `:owner` — owner process or callback for inbound data
    * `:server_name` — GenServer registration name (optional)
    * `:skip_open` — skip serial port open (for testing, default: false)

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

  @doc "Sends data out through this serial interface."
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
    if state.online do
      framed = HDLC.frame(data)

      case do_write(state, framed) do
        :ok ->
          {:ok, %{state | txb: state.txb + byte_size(framed)}}

        {:error, reason} ->
          Logger.error("Serial interface #{state.name} write error: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :offline}
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
    close_port(state)
    :ok
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    serial_port = Keyword.get(opts, :port)
    speed = Keyword.get(opts, :speed, @default_speed)
    databits = Keyword.get(opts, :databits, @default_databits)
    parity_str = Keyword.get(opts, :parity, "N")
    stopbits = Keyword.get(opts, :stopbits, @default_stopbits)
    owner = Keyword.get(opts, :owner)
    skip_open = Keyword.get(opts, :skip_open, false)

    parity = if is_atom(parity_str), do: parity_str, else: parse_parity(parity_str)

    state = %__MODULE__{
      name: name,
      port: serial_port,
      speed: speed,
      databits: databits,
      parity: parity,
      stopbits: stopbits,
      owner: owner,
      in: true,
      out: true,
      online: false,
      bitrate: speed,
      hw_mtu: @hw_mtu,
      ifac_size: @default_ifac_size,
      created: System.system_time(:second),
      skip_open: skip_open,
      backend: detect_backend()
    }

    state = %{state | hash: RNS.Interfaces.Interface.hash(state)}

    if skip_open do
      {:ok, %{state | online: true}}
    else
      if serial_port == nil do
        {:stop, {:error, :no_port_specified}}
      else
        case open_port(state) do
          {:ok, new_state} ->
            Logger.info("Serial port #{serial_port} is now open")
            {:ok, %{new_state | online: true}}

          {:error, reason} ->
            Logger.error("Could not open serial port #{serial_port}: #{inspect(reason)}")
            {:stop, {:error, reason}}
        end
      end
    end
  end

  @impl GenServer
  def handle_call({:send_data, data}, _from, state) do
    case process_outgoing(state, data) do
      {:ok, updated} -> {:reply, :ok, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:detach, _from, state) do
    close_port(state)
    {:reply, :ok, %{state | online: false, detached: true, uart_pid: nil, port_ref: nil}}
  end

  @impl GenServer
  def handle_info({:circuits_uart, _pid, data}, state) when is_binary(data) do
    # Data from circuits_uart
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info({port_ref, {:data, data}}, state) when is_port(port_ref) do
    # Data from Elixir Port
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info({:serial_data, data}, state) when is_binary(data) do
    # Data injected for testing
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    if not state.online and not state.detached do
      Logger.info("Attempting to reconnect serial port #{state.port}...")

      case open_port(state) do
        {:ok, new_state} ->
          Logger.info("Reconnected serial port #{state.port}")
          {:noreply, %{new_state | online: true, reconnecting: false}}

        {:error, _reason} ->
          schedule_reconnect()
          {:noreply, state}
      end
    else
      {:noreply, %{state | reconnecting: false}}
    end
  end

  def handle_info({:port_closed, _ref}, state) do
    Logger.error("Serial port #{state.port} closed unexpectedly")
    handle_port_error(state)
  end

  def handle_info({:EXIT, _port, reason}, state) do
    Logger.error("Serial port #{state.port} exited: #{inspect(reason)}")
    handle_port_error(state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_port(state)
    :ok
  end

  # ── should_ingress_limit (always false, matching Python) ─────────

  @doc """
  Serial interfaces never limit ingress.
  Matches Python's `should_ingress_limit` returning `False`.
  """
  @spec should_ingress_limit(t()) :: {false, t()}
  def should_ingress_limit(%__MODULE__{} = state), do: {false, state}

  # ── Private helpers ──────────────────────────────────────────────

  defp detect_backend do
    if Code.ensure_loaded?(Circuits.UART), do: :circuits_uart, else: :port
  end

  defp open_port(%{backend: :circuits_uart} = state) do
    case Circuits.UART.start_link() do
      {:ok, pid} ->
        uart_opts = [
          speed: state.speed,
          data_bits: state.databits,
          parity: state.parity,
          stop_bits: state.stopbits,
          active: true,
          framing: :none
        ]

        case Circuits.UART.open(pid, state.port, uart_opts) do
          :ok ->
            {:ok, %{state | uart_pid: pid}}

          {:error, reason} ->
            Circuits.UART.stop(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_port(%{backend: :port} = state) do
    # Port-based fallback using stty and /dev/ device
    # This is a simplified implementation for when circuits_uart is not available

    # Configure the serial port with stty
    stty_cmd =
      "stty -F #{state.port} #{state.speed} cs#{state.databits} " <>
        "#{parity_to_stty(state.parity)} " <>
        "#{stopbits_to_stty(state.stopbits)} " <>
        "-echo raw"

    case System.cmd("stty", String.split(stty_cmd), stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> :ok
    end

    port_ref = Port.open({:spawn, "cat #{state.port}"}, [:binary, :stream, :exit_status])
    {:ok, %{state | port_ref: port_ref}}
  rescue
    e -> {:error, e}
  end

  defp parity_to_stty(:none), do: "-parenb"
  defp parity_to_stty(:even), do: "parenb -parodd"
  defp parity_to_stty(:odd), do: "parenb parodd"

  defp stopbits_to_stty(1), do: "-cstopb"
  defp stopbits_to_stty(2), do: "cstopb"
  defp stopbits_to_stty(_), do: "-cstopb"

  defp do_write(%{backend: :circuits_uart, uart_pid: pid}, data) when pid != nil do
    Circuits.UART.write(pid, data)
  end

  defp do_write(%{backend: :port, port_ref: ref}, data) when ref != nil do
    Port.command(ref, data)
    :ok
  rescue
    _ -> {:error, :write_failed}
  end

  defp do_write(%{skip_open: true}, _data), do: :ok

  defp do_write(_, _data), do: {:error, :no_port}

  defp close_port(%{backend: :circuits_uart, uart_pid: pid}) when pid != nil do
    Circuits.UART.close(pid)
    Circuits.UART.stop(pid)
  rescue
    _ -> :ok
  end

  defp close_port(%{backend: :port, port_ref: ref}) when ref != nil do
    Port.close(ref)
  rescue
    _ -> :ok
  end

  defp close_port(_), do: :ok

  defp handle_serial_data(state, data) do
    buffer = state.frame_buffer <> data

    {frames, remaining} = HDLC.deframe(buffer)

    state = %{state | frame_buffer: remaining}

    Enum.reduce(frames, state, fn frame, acc ->
      if byte_size(frame) > 0 and byte_size(frame) <= acc.hw_mtu do
        {:ok, updated} = process_incoming(acc, frame)
        updated
      else
        acc
      end
    end)
  end

  defp handle_port_error(state) do
    close_port(state)
    updated = %{state | online: false, uart_pid: nil, port_ref: nil}

    if state.detached do
      {:noreply, updated}
    else
      Logger.error("Interface #{state.name} is now offline. Will attempt reconnection.")
      schedule_reconnect()
      {:noreply, %{updated | reconnecting: true}}
    end
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, @reconnect_wait)
  end

  defp notify_owner(owner, data, interface) when is_pid(owner) do
    send(owner, {:serial_interface_data, data, interface})
  end

  defp notify_owner({module, fun}, data, interface) when is_atom(module) and is_atom(fun) do
    apply(module, fun, [data, interface])
  end

  defp notify_owner(fun, data, interface) when is_function(fun, 2) do
    fun.(data, interface)
  end

  defp notify_owner(_, _data, _interface), do: :ok

  # ── String.Chars protocol ────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name}) do
      "SerialInterface[#{name}]"
    end
  end
end
