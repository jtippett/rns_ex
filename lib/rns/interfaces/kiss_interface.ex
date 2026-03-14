defmodule RNS.Interfaces.KISSInterface do
  @moduledoc """
  KISS TNC interface for RNS.

  Sends and receives packets over a serial port using KISS framing
  with configurable TNC parameters (preamble, TX tail, persistence,
  slot time). Supports flow control and beacon identification.

  Uses `circuits_uart` if available, falls back to an Elixir Port-based
  implementation for testing without hardware.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  @compile {:no_warn_undefined, Circuits.UART}

  alias RNS.Interfaces.Interface.KISS

  @max_chunk 32_768
  @default_ifac_size 8
  @hw_mtu 564
  @bitrate_guess 1_200
  @reconnect_wait 5_000
  @read_timeout_ms 100
  @flow_control_timeout 5

  # Default serial configuration
  @default_speed 9600
  @default_databits 8
  @default_parity :none
  @default_stopbits 1

  # Default KISS TNC parameters
  @default_preamble 350
  @default_txtail 20
  @default_persistence 64
  @default_slottime 20

  defstruct default_fields() ++
              [
                # Serial config
                port: nil,
                speed: @default_speed,
                databits: @default_databits,
                parity: @default_parity,
                stopbits: @default_stopbits,
                timeout: @read_timeout_ms,

                # KISS TNC parameters
                preamble: @default_preamble,
                txtail: @default_txtail,
                persistence: @default_persistence,
                slottime: @default_slottime,

                # Flow control
                flow_control: false,
                interface_ready: true,
                flow_control_locked: 0,

                # Packet queue (for flow control)
                packet_queue: :queue.new(),

                # Beacon
                beacon_interval: nil,
                beacon_data: <<>>,
                first_tx: nil,

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

  @doc "Returns the default IFAC size for KISS interfaces."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns the hardware MTU for KISS interfaces."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu

  @doc "Returns the bitrate guess for KISS interfaces (1200 baud)."
  @spec bitrate_guess() :: pos_integer()
  def bitrate_guess, do: @bitrate_guess

  @doc "Returns the reconnect wait time in milliseconds."
  @spec reconnect_wait() :: pos_integer()
  def reconnect_wait, do: @reconnect_wait

  @doc "Returns the flow control timeout in seconds."
  @spec flow_control_timeout() :: pos_integer()
  def flow_control_timeout, do: @flow_control_timeout

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

  @doc "Checks if `circuits_uart` is available."
  @spec circuits_uart_available?() :: boolean()
  def circuits_uart_available? do
    Code.ensure_loaded?(Circuits.UART)
  end

  @doc """
  Builds a KISS command frame.

  Returns `<<FEND, command, value, FEND>>`.
  """
  @spec kiss_command(byte(), byte()) :: binary()
  def kiss_command(command, value) do
    <<KISS.fend(), command, value, KISS.fend()>>
  end

  @doc """
  Converts a preamble time in milliseconds to a KISS TXDELAY value.

  The value is `preamble_ms / 10`, clamped to 0-255.
  """
  @spec preamble_value(number()) :: byte()
  def preamble_value(preamble_ms) do
    preamble_ms |> div(10) |> max(0) |> min(255)
  end

  @doc """
  Converts a TX tail time in milliseconds to a KISS TXTAIL value.

  The value is `txtail_ms / 10`, clamped to 0-255.
  """
  @spec txtail_value(number()) :: byte()
  def txtail_value(txtail_ms) do
    txtail_ms |> div(10) |> max(0) |> min(255)
  end

  @doc """
  Clamps a persistence value to 0-255.
  """
  @spec persistence_value(integer()) :: byte()
  def persistence_value(p), do: p |> max(0) |> min(255)

  @doc """
  Converts a slot time in milliseconds to a KISS SLOTTIME value.

  The value is `slottime_ms / 10`, clamped to 0-255.
  """
  @spec slottime_value(number()) :: byte()
  def slottime_value(slottime_ms) do
    slottime_ms |> div(10) |> max(0) |> min(255)
  end

  @doc """
  Starts a KISS interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:port` — serial port path (e.g., "/dev/ttyUSB0") (required unless skip_open)
    * `:speed` — baud rate (default: 9600)
    * `:databits` — data bits (default: 8)
    * `:parity` — parity string: "N", "E", "O" (default: "N")
    * `:stopbits` — stop bits (default: 1)
    * `:preamble` — TX preamble in ms (default: 350)
    * `:txtail` — TX tail in ms (default: 20)
    * `:persistence` — CSMA persistence (default: 64)
    * `:slottime` — CSMA slot time in ms (default: 20)
    * `:flow_control` — enable flow control (default: false)
    * `:beacon_interval` — beacon interval in seconds (optional)
    * `:beacon_data` — beacon callsign string (optional)
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

  @doc "Sends data out through this KISS interface."
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
      if state.interface_ready do
        state =
          if state.flow_control do
            %{state | interface_ready: false, flow_control_locked: System.system_time(:second)}
          else
            state
          end

        # KISS escape and frame
        escaped = KISS.escape(data)
        frame = <<KISS.fend(), KISS.cmd_data()>> <> escaped <> <<KISS.fend()>>

        case do_write(state, frame) do
          :ok ->
            state = %{state | txb: state.txb + byte_size(data)}

            # Beacon tracking
            state =
              if data == state.beacon_data do
                %{state | first_tx: nil}
              else
                # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                if state.first_tx == nil do
                  %{state | first_tx: System.system_time(:second)}
                else
                  state
                end
              end

            {:ok, state}

          {:error, reason} ->
            Logger.error("KISS interface #{state.name} write error: #{inspect(reason)}")
            {:error, reason}
        end
      else
        # Queue the packet when flow control is active
        {:ok, queue_packet(state, data)}
      end
    else
      {:error, :offline}
    end
  end

  @impl RNS.Interfaces.Interface
  def process_incoming(state, data) do
    updated = %{state | rxb: state.rxb + byte_size(data)}
    RNS.Interfaces.Interface.deliver_to_transport(data, updated)
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

    preamble = Keyword.get(opts, :preamble, @default_preamble)
    txtail = Keyword.get(opts, :txtail, @default_txtail)
    persistence = Keyword.get(opts, :persistence, @default_persistence)
    slottime = Keyword.get(opts, :slottime, @default_slottime)
    flow_control = Keyword.get(opts, :flow_control, false)
    beacon_interval = Keyword.get(opts, :beacon_interval)

    beacon_data =
      case Keyword.get(opts, :beacon_data) do
        nil -> <<>>
        data when is_binary(data) -> data
      end

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
      bitrate: @bitrate_guess,
      hw_mtu: @hw_mtu,
      ifac_size: @default_ifac_size,
      created: System.system_time(:second),
      skip_open: skip_open,
      backend: detect_backend(),
      preamble: preamble,
      txtail: txtail,
      persistence: persistence,
      slottime: slottime,
      flow_control: flow_control,
      interface_ready: !flow_control,
      beacon_interval: beacon_interval,
      beacon_data: beacon_data
    }

    state = %{state | hash: RNS.Interfaces.Interface.hash(state)}
    RNS.Interfaces.Interface.schedule_ets_refresh()

    if skip_open do
      state = configure_device(state)
      {:ok, %{state | online: true, interface_ready: true}}
    else
      if serial_port == nil do
        {:stop, {:error, :no_port_specified}}
      else
        case open_port(state) do
          {:ok, new_state} ->
            Logger.info("Serial port #{serial_port} is now open")
            new_state = configure_device(new_state)
            {:ok, %{new_state | online: true, interface_ready: true}}

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
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info({port_ref, {:data, data}}, state) when is_port(port_ref) do
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
      Logger.info("Attempting to reconnect serial port #{state.port} for #{state.name}...")

      case open_port(state) do
        {:ok, new_state} ->
          Logger.info("Reconnected serial port for #{state.name}")
          new_state = configure_device(new_state)
          {:noreply, %{new_state | online: true, reconnecting: false, interface_ready: true}}

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

  def handle_info(:refresh_ets, state) do
    if state.hash do
      :ets.insert(:rns_interfaces, {state.hash, %{state | pid: self()}})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_port(state)
    RNS.Interfaces.Interface.deregister_on_terminate(state)
  end

  # ── should_ingress_limit (always false, matching Python) ─────────

  @doc """
  KISS interfaces never limit ingress.
  Matches Python's `should_ingress_limit` returning `False`.
  """
  @spec should_ingress_limit(t()) :: {false, t()}
  def should_ingress_limit(%__MODULE__{} = state), do: {false, state}

  # ── KISS device configuration ───────────────────────────────────

  @doc """
  Sends KISS TNC configuration commands.

  Configures preamble, TX tail, persistence, slot time, and flow control.
  In skip_open mode, just returns the state without writing.
  """
  @spec configure_device(t()) :: t()
  def configure_device(%__MODULE__{skip_open: true} = state), do: state

  def configure_device(%__MODULE__{} = state) do
    # Send KISS configuration commands
    write_kiss_command(state, KISS.cmd_txdelay(), preamble_value(state.preamble))
    write_kiss_command(state, KISS.cmd_txtail(), txtail_value(state.txtail))
    write_kiss_command(state, KISS.cmd_p(), persistence_value(state.persistence))
    write_kiss_command(state, KISS.cmd_slottime(), slottime_value(state.slottime))
    write_kiss_command(state, KISS.cmd_ready(), 0x01)
    state
  end

  # ── Packet queue (flow control) ──────────────────────────────────

  @doc "Queues a packet for later transmission (flow control)."
  @spec queue_packet(t(), binary()) :: t()
  def queue_packet(%__MODULE__{} = state, data) do
    %{state | packet_queue: :queue.in(data, state.packet_queue)}
  end

  @doc "Processes the packet queue, sending the next queued packet."
  @spec process_queue(t()) :: t()
  def process_queue(%__MODULE__{} = state) do
    case :queue.out(state.packet_queue) do
      {{:value, data}, remaining} ->
        state = %{state | packet_queue: remaining, interface_ready: true}

        case process_outgoing(state, data) do
          {:ok, updated} -> updated
          {:error, _} -> state
        end

      {:empty, _} ->
        %{state | interface_ready: true}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp detect_backend do
    if Code.ensure_loaded?(Circuits.UART), do: :circuits_uart, else: :port
  end

  @dialyzer {:nowarn_function, open_port: 1}
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

  @dialyzer {:nowarn_function, do_write: 2}
  defp do_write(%{backend: :circuits_uart, uart_pid: pid}, data) when pid != nil do
    Circuits.UART.write(pid, data)
  end

  defp do_write(%{backend: :port, port_ref: ref}, data) when ref != nil do
    Port.command(ref, data)
    :ok
  rescue
    e ->
      Logger.warning("KISS port write failed: #{inspect(e)}")
      {:error, :write_failed}
  end

  defp do_write(%{skip_open: true}, _data), do: :ok

  defp do_write(_, _data), do: {:error, :no_port}

  defp write_kiss_command(state, command, value) do
    do_write(state, kiss_command(command, value))
  end

  @dialyzer {:nowarn_function, close_port: 1}
  defp close_port(%{backend: :circuits_uart, uart_pid: pid}) when pid != nil do
    Circuits.UART.close(pid)
    Circuits.UART.stop(pid)
  rescue
    e ->
      Logger.debug("KISS UART close failed (may already be closed): #{inspect(e)}")
      :ok
  end

  defp close_port(%{backend: :port, port_ref: ref}) when ref != nil do
    Port.close(ref)
  rescue
    e ->
      Logger.debug("KISS port close failed (may already be closed): #{inspect(e)}")
      :ok
  end

  defp close_port(_), do: :ok

  defp handle_serial_data(state, data) do
    cmd_data = KISS.cmd_data()
    cmd_ready = KISS.cmd_ready()
    buffer = state.frame_buffer <> data

    {frames, remaining} = KISS.deframe(buffer)

    state = %{state | frame_buffer: remaining}

    Enum.reduce(frames, state, fn
      {^cmd_data, frame_data}, acc ->
        if byte_size(frame_data) > 0 and byte_size(frame_data) <= acc.hw_mtu do
          {:ok, updated} = process_incoming(acc, frame_data)
          updated
        else
          acc
        end

      {^cmd_ready, _frame_data}, acc ->
        # Flow control ready signal from TNC
        process_queue(acc)

      _other, acc ->
        acc
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

  # ── String.Chars protocol ────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name}) do
      "KISSInterface[#{name}]"
    end
  end
end
