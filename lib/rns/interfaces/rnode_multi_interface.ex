defmodule RNS.Interfaces.RNodeMultiInterface do
  @moduledoc """
  RNode Multi-radio LoRa interface for RNS.

  Manages multiple LoRa sub-interfaces on a single RNode device with
  dual-radio or multi-radio capability. Each sub-interface has independent
  radio parameters (frequency, bandwidth, spreading factor, coding rate,
  TX power) and operates on a virtual port (vport) on the device.

  The parent interface handles serial communication with the RNode device
  and dispatches data to/from sub-interfaces based on KISS interface
  selection commands (`CMD_SEL_INT`). Sub-interfaces are registered
  individually with Transport as independent interfaces.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  import Bitwise

  @compile {:no_warn_undefined, Circuits.UART}

  # ── RNode Multi KISS command constants ──────────────────────────────

  # Frame delimiters
  @fend 0xC0
  @fesc 0xDB
  @tfend 0xDC
  @tfesc 0xDD

  # Command bytes
  @cmd_unknown 0xFE
  @cmd_data 0x00
  @cmd_frequency 0x01
  @cmd_bandwidth 0x02
  @cmd_txpower 0x03
  @cmd_sf 0x04
  @cmd_cr 0x05
  @cmd_radio_state 0x06
  @cmd_radio_lock 0x07
  @cmd_detect 0x08
  @cmd_leave 0x0A
  @cmd_st_alock 0x0B
  @cmd_lt_alock 0x0C
  @cmd_ready 0x0F
  @cmd_stat_rssi 0x23
  @cmd_stat_snr 0x24
  @cmd_stat_chtm 0x25
  @cmd_stat_phyprm 0x26
  # Defined in Python but not currently used:
  # cmd_blink = 0x30, cmd_fb_ext = 0x41, cmd_fb_read = 0x42,
  # cmd_fb_write = 0x43, cmd_bt_ctrl = 0x46, cmd_rom_read = 0x51
  @cmd_random 0x40
  @cmd_platform 0x48
  @cmd_mcu 0x49
  @cmd_fw_version 0x50
  @cmd_reset 0x55
  @cmd_interfaces 0x71
  @cmd_error 0x90

  # Interface selection command
  @cmd_sel_int 0x1F

  # Interface data commands (virtual port mapping)
  @cmd_int0_data 0x00
  @cmd_int1_data 0x10
  @cmd_int2_data 0x20
  @cmd_int3_data 0x70
  @cmd_int4_data 0x75
  @cmd_int5_data 0x90
  @cmd_int6_data 0xA0
  @cmd_int7_data 0xB0
  @cmd_int8_data 0xC0
  @cmd_int9_data 0xD0
  @cmd_int10_data 0xE0
  @cmd_int11_data 0xF0

  # Detection protocol
  @detect_req 0x73
  @detect_resp 0x46

  # Radio states
  @radio_state_off 0x00
  # Defined in Python but not currently used: radio_state_on = 0x01

  # Error codes
  @error_initradio 0x01
  @error_txfailed 0x02

  # Platform IDs
  @platform_esp32 0x80
  @platform_nrf52 0x70

  # Modem types
  @sx127x 0x00
  @sx1276 0x01
  @sx1278 0x02
  @sx126x 0x10
  @sx1262 0x11
  @sx128x 0x20
  @sx1280 0x21

  # ── Interface constants ────────────────────────────────────────────

  @max_chunk 32_768
  @default_ifac_size 8
  @hw_mtu 508
  @reconnect_wait 5_000
  @max_subinterfaces 11
  @callsign_max_len 32

  # Firmware version requirements (higher than single RNode)
  @required_fw_ver_maj 1
  @required_fw_ver_min 74

  # Display constants
  @fb_pixel_width 64
  @fb_bits_per_pixel 1
  @fb_pixels_per_byte div(8, @fb_bits_per_pixel)
  @fb_bytes_per_line div(@fb_pixel_width, @fb_pixels_per_byte)

  # Data commands list for matching
  @data_commands [
    @cmd_int0_data,
    @cmd_int1_data,
    @cmd_int2_data,
    @cmd_int3_data,
    @cmd_int4_data,
    @cmd_int5_data,
    @cmd_int6_data,
    @cmd_int7_data,
    @cmd_int8_data,
    @cmd_int9_data,
    @cmd_int10_data,
    @cmd_int11_data
  ]

  # ── Struct ─────────────────────────────────────────────────────────

  defstruct default_fields() ++
              [
                # Serial config
                port: nil,
                speed: 115_200,
                databits: 8,
                parity: :none,
                stopbits: 1,
                timeout: 100,

                # Device state
                detected: false,
                firmware_ok: false,
                maj_version: 0,
                min_version: 0,
                platform: nil,
                display: nil,
                mcu: nil,
                selected_index: 0,

                # Sub-interfaces
                subinterfaces: %{},
                subinterface_types: [],
                subint_config: [],
                clients: 0,

                # Flow control / stats
                r_stat_rx: nil,
                r_stat_tx: nil,
                r_stat_rssi: nil,
                r_stat_snr: nil,
                r_st_alock: nil,
                r_lt_alock: nil,
                r_random: nil,
                r_airtime_short: 0.0,
                r_airtime_long: 0.0,
                r_channel_load_short: 0.0,
                r_channel_load_long: 0.0,

                # ID beacon
                id_interval: nil,
                id_callsign: nil,
                first_tx: nil,
                last_id: 0,
                should_id: false,

                # Serial backend
                uart_pid: nil,
                port_ref: nil,
                frame_buffer: <<>>,
                backend: nil,
                reconnecting: false,

                # GenServer
                owner: nil,
                server_name: nil,
                skip_open: false,
                test_mode: false
              ]

  # ── Public API ─────────────────────────────────────────────────────

  @doc "Returns all public constants for testing."
  def constants do
    %{
      max_chunk: @max_chunk,
      default_ifac_size: @default_ifac_size,
      hw_mtu: @hw_mtu,
      reconnect_wait: @reconnect_wait,
      max_subinterfaces: @max_subinterfaces,
      callsign_max_len: @callsign_max_len,
      required_fw_ver_maj: @required_fw_ver_maj,
      required_fw_ver_min: @required_fw_ver_min,
      cmd_sel_int: @cmd_sel_int,
      cmd_interfaces: @cmd_interfaces,
      fb_pixel_width: @fb_pixel_width,
      fb_bytes_per_line: @fb_bytes_per_line
    }
  end

  @doc "Returns the data command byte for a given sub-interface index."
  @spec data_command_for_index(non_neg_integer()) :: byte()
  def data_command_for_index(index) do
    Enum.at(@data_commands, index, @cmd_data)
  end

  @doc "Maps a data command byte back to sub-interface index."
  @spec index_for_data_command(byte()) :: non_neg_integer() | nil
  def index_for_data_command(cmd) do
    Enum.find_index(@data_commands, &(&1 == cmd))
  end

  @doc "Converts interface type code to string representation."
  @spec interface_type_to_str(byte()) :: String.t()
  def interface_type_to_str(interface_type) do
    cond do
      interface_type in [@sx126x, @sx1262] -> "SX126X"
      interface_type in [@sx127x, @sx1276, @sx1278] -> "SX127X"
      interface_type in [@sx128x, @sx1280] -> "SX128X"
      true -> "SX127X"
    end
  end

  # ── KISS escape/unescape (RNode-specific, no port nibble stripping) ──

  @doc "KISS-escape binary data for RNode protocol."
  @spec kiss_escape(binary()) :: binary()
  def kiss_escape(data) do
    for <<byte <- data>>, into: <<>> do
      case byte do
        @fesc -> <<@fesc, @tfesc>>
        @fend -> <<@fesc, @tfend>>
        _ -> <<byte>>
      end
    end
  end

  @doc "KISS-unescape binary data for RNode protocol."
  @spec kiss_unescape(binary()) :: binary()
  def kiss_unescape(data) do
    do_kiss_unescape(data, <<>>)
  end

  defp do_kiss_unescape(<<>>, acc), do: acc

  defp do_kiss_unescape(<<@fesc, @tfend, rest::binary>>, acc),
    do: do_kiss_unescape(rest, acc <> <<@fend>>)

  defp do_kiss_unescape(<<@fesc, @tfesc, rest::binary>>, acc),
    do: do_kiss_unescape(rest, acc <> <<@fesc>>)

  defp do_kiss_unescape(<<@fesc, rest::binary>>, acc), do: do_kiss_unescape(rest, acc)
  defp do_kiss_unescape(<<byte, rest::binary>>, acc), do: do_kiss_unescape(rest, acc <> <<byte>>)

  # ── KISS deframe (preserving full command byte) ────────────────────

  @doc "Extract KISS frames from buffer, preserving full command bytes."
  @spec deframe(binary()) :: {[{byte(), binary()}], binary()}
  def deframe(buffer) do
    do_deframe(buffer, [], false, @cmd_unknown, <<>>, false)
  end

  defp do_deframe(<<>>, frames, false, _cmd, _data, _escape) do
    {Enum.reverse(frames), <<>>}
  end

  # Buffer exhausted mid-frame - reconstruct remaining bytes for next call
  defp do_deframe(<<>>, frames, true, cmd, data, _escape) do
    remaining =
      if cmd == @cmd_unknown do
        <<@fend>>
      else
        <<@fend, cmd>> <> data
      end

    {Enum.reverse(frames), remaining}
  end

  defp do_deframe(<<@fend, rest::binary>>, frames, true, cmd, data, _escape)
       when cmd in @data_commands do
    frames = [{cmd, data} | frames]
    do_deframe(<<@fend, rest::binary>>, frames, false, @cmd_unknown, <<>>, false)
  end

  defp do_deframe(<<@fend, rest::binary>>, frames, true, cmd, data, _escape)
       when cmd != @cmd_unknown and byte_size(data) > 0 do
    frames = [{cmd, data} | frames]
    do_deframe(rest, frames, true, @cmd_unknown, <<>>, false)
  end

  defp do_deframe(<<@fend, rest::binary>>, frames, _in_frame, _cmd, _data, _escape) do
    do_deframe(rest, frames, true, @cmd_unknown, <<>>, false)
  end

  defp do_deframe(<<_byte, rest::binary>>, frames, false, cmd, data, escape) do
    do_deframe(rest, frames, false, cmd, data, escape)
  end

  defp do_deframe(<<byte, rest::binary>>, frames, true, @cmd_unknown, <<>>, _escape) do
    do_deframe(rest, frames, true, byte, <<>>, false)
  end

  defp do_deframe(<<@fesc, rest::binary>>, frames, true, cmd, data, _escape) do
    do_deframe(rest, frames, true, cmd, data, true)
  end

  defp do_deframe(<<@tfend, rest::binary>>, frames, true, cmd, data, true) do
    do_deframe(rest, frames, true, cmd, data <> <<@fend>>, false)
  end

  defp do_deframe(<<@tfesc, rest::binary>>, frames, true, cmd, data, true) do
    do_deframe(rest, frames, true, cmd, data <> <<@fesc>>, false)
  end

  defp do_deframe(<<byte, rest::binary>>, frames, true, cmd, data, true) do
    do_deframe(rest, frames, true, cmd, data <> <<byte>>, false)
  end

  defp do_deframe(<<byte, rest::binary>>, frames, true, cmd, data, false)
       when byte_size(data) < @hw_mtu do
    do_deframe(rest, frames, true, cmd, data <> <<byte>>, false)
  end

  defp do_deframe(<<_byte, rest::binary>>, frames, true, cmd, data, false) do
    do_deframe(rest, frames, true, cmd, data, false)
  end

  # ── Command building (with interface selection) ────────────────────

  @doc "Build a select-interface + command frame for a sub-interface."
  @spec build_sel_command(non_neg_integer(), byte(), binary()) :: binary()
  def build_sel_command(index, command, payload) do
    <<@fend, @cmd_sel_int, index, @fend, @fend, command>> <> kiss_escape(payload) <> <<@fend>>
  end

  @doc "Build the detect frame for device identification."
  @spec build_detect_frame() :: binary()
  def build_detect_frame do
    <<@fend, @cmd_detect, @detect_req, @fend, @cmd_fw_version, 0x00, @fend, @cmd_platform, 0x00,
      @fend, @cmd_mcu, 0x00, @fend, @cmd_interfaces, 0x00, @fend>>
  end

  @doc "Build the leave frame."
  @spec build_leave_frame() :: binary()
  def build_leave_frame do
    <<@fend, @cmd_leave, 0xFF, @fend>>
  end

  @doc "Encode frequency as 4-byte big-endian."
  @spec encode_frequency(integer()) :: binary()
  def encode_frequency(freq), do: <<freq::unsigned-big-32>>

  @doc "Encode bandwidth as 4-byte big-endian."
  @spec encode_bandwidth(integer()) :: binary()
  def encode_bandwidth(bw), do: <<bw::unsigned-big-32>>

  @doc "Encode TX power as signed byte."
  @spec encode_txpower(integer()) :: binary()
  def encode_txpower(power) do
    <<power::signed-8>>
  end

  @doc "Encode spreading factor as single byte."
  @spec encode_sf(integer()) :: binary()
  def encode_sf(sf), do: <<sf::8>>

  @doc "Encode coding rate as single byte."
  @spec encode_cr(integer()) :: binary()
  def encode_cr(cr), do: <<cr::8>>

  @doc "Encode radio state as single byte."
  @spec encode_radio_state(integer()) :: binary()
  def encode_radio_state(state), do: <<state::8>>

  @doc "Encode airtime lock as 2-byte value (percentage * 100)."
  @spec encode_alock(float()) :: binary()
  def encode_alock(alock) do
    at = round(alock * 100)
    <<at::unsigned-big-16>>
  end

  @doc "Validate firmware version."
  @spec validate_firmware(integer(), integer()) :: boolean()
  def validate_firmware(maj, min) do
    maj > @required_fw_ver_maj or (maj == @required_fw_ver_maj and min >= @required_fw_ver_min)
  end

  # ── Handle command responses ───────────────────────────────────────

  @doc "Process a command response and update state."
  @spec handle_command(map(), byte(), binary()) :: map()
  def handle_command(state, command, data)

  def handle_command(state, @cmd_detect, <<@detect_resp>>) do
    %{state | detected: true}
  end

  def handle_command(state, @cmd_detect, _data) do
    %{state | detected: false}
  end

  def handle_command(state, @cmd_fw_version, <<maj, min>>) do
    firmware_ok = validate_firmware(maj, min)
    %{state | maj_version: maj, min_version: min, firmware_ok: firmware_ok}
  end

  def handle_command(state, @cmd_platform, <<platform>>) do
    display = if platform in [@platform_esp32, @platform_nrf52], do: true, else: state.display
    %{state | platform: platform, display: display}
  end

  def handle_command(state, @cmd_mcu, <<mcu>>) do
    %{state | mcu: mcu}
  end

  def handle_command(state, @cmd_interfaces, <<_vport, interface_type>>) do
    type_str = interface_type_to_str(interface_type)
    %{state | subinterface_types: state.subinterface_types ++ [type_str]}
  end

  def handle_command(state, @cmd_sel_int, <<index>>) do
    %{state | selected_index: index}
  end

  def handle_command(state, @cmd_frequency, <<c1, c2, c3, c4>>) do
    freq = c1 <<< 24 ||| c2 <<< 16 ||| c3 <<< 8 ||| c4

    update_subinterface(state, state.selected_index, fn sub ->
      sub = %{sub | r_frequency: freq}
      RNS.Interfaces.RNodeSubInterface.update_bitrate(sub)
    end)
  end

  def handle_command(state, @cmd_bandwidth, <<c1, c2, c3, c4>>) do
    bw = c1 <<< 24 ||| c2 <<< 16 ||| c3 <<< 8 ||| c4

    update_subinterface(state, state.selected_index, fn sub ->
      sub = %{sub | r_bandwidth: bw}
      RNS.Interfaces.RNodeSubInterface.update_bitrate(sub)
    end)
  end

  def handle_command(state, @cmd_txpower, <<txp>>) do
    txpower = if txp > 127, do: txp - 256, else: txp

    update_subinterface(state, state.selected_index, fn sub ->
      %{sub | r_txpower: txpower}
    end)
  end

  def handle_command(state, @cmd_sf, <<sf>>) do
    update_subinterface(state, state.selected_index, fn sub ->
      sub = %{sub | r_sf: sf}
      RNS.Interfaces.RNodeSubInterface.update_bitrate(sub)
    end)
  end

  def handle_command(state, @cmd_cr, <<cr>>) do
    update_subinterface(state, state.selected_index, fn sub ->
      sub = %{sub | r_cr: cr}
      RNS.Interfaces.RNodeSubInterface.update_bitrate(sub)
    end)
  end

  def handle_command(state, @cmd_radio_state, <<radio_state>>) do
    update_subinterface(state, state.selected_index, fn sub ->
      %{sub | r_state: radio_state}
    end)
  end

  def handle_command(state, @cmd_radio_lock, <<lock>>) do
    update_subinterface(state, state.selected_index, fn sub ->
      %{sub | r_lock: lock}
    end)
  end

  def handle_command(state, @cmd_stat_rssi, <<rssi_byte>>) do
    update_subinterface(state, state.selected_index, fn sub ->
      %{sub | r_stat_rssi: rssi_byte - RNS.Interfaces.RNodeSubInterface.rssi_offset()}
    end)
  end

  def handle_command(state, @cmd_stat_snr, <<snr_byte>>) do
    snr = if(snr_byte > 127, do: snr_byte - 256, else: snr_byte) * 0.25

    update_subinterface(state, state.selected_index, fn sub ->
      quality = RNS.Interfaces.RNodeSubInterface.calculate_quality(snr, sub.r_sf)
      %{sub | r_stat_snr: snr, r_stat_q: quality}
    end)
  end

  def handle_command(state, @cmd_st_alock, <<c1, c2>>) do
    at = (c1 <<< 8 ||| c2) / 100.0

    update_subinterface(state, state.selected_index, fn sub ->
      %{sub | r_st_alock: at}
    end)
  end

  def handle_command(state, @cmd_lt_alock, <<c1, c2>>) do
    at = (c1 <<< 8 ||| c2) / 100.0

    update_subinterface(state, state.selected_index, fn sub ->
      %{sub | r_lt_alock: at}
    end)
  end

  def handle_command(state, @cmd_stat_chtm, <<c1, c2, c3, c4, c5, c6, c7, c8>>) do
    ats = (c1 <<< 8 ||| c2) / 100.0
    atl = (c3 <<< 8 ||| c4) / 100.0
    cus = (c5 <<< 8 ||| c6) / 100.0
    cul = (c7 <<< 8 ||| c8) / 100.0

    %{
      state
      | r_airtime_short: ats,
        r_airtime_long: atl,
        r_channel_load_short: cus,
        r_channel_load_long: cul
    }
  end

  def handle_command(state, @cmd_stat_phyprm, data) when byte_size(data) == 10 do
    <<s1, s2, s3, s4, s5, s6, s7, s8, s9, s10>> = data
    lst = (s1 <<< 8 ||| s2) / 1000.0
    lsr = s3 <<< 8 ||| s4
    prs = s5 <<< 8 ||| s6
    prt = s7 <<< 8 ||| s8
    cst = s9 <<< 8 ||| s10

    update_subinterface(state, state.selected_index, fn sub ->
      %{
        sub
        | r_symbol_time_ms: lst,
          r_symbol_rate: lsr,
          r_preamble_symbols: prs,
          r_preamble_time_ms: prt,
          r_csma_slot_time_ms: cst
      }
    end)
  end

  def handle_command(state, @cmd_random, <<byte>>) do
    %{state | r_random: byte}
  end

  def handle_command(state, @cmd_error, <<error_byte>>) do
    case error_byte do
      @error_initradio ->
        Logger.error(
          "#{state.name} hardware initialisation error (code #{RNS.hexrep(<<error_byte>>)})"
        )

      @error_txfailed ->
        Logger.error("#{state.name} hardware TX error (code #{RNS.hexrep(<<error_byte>>)})")

      _ ->
        Logger.error("#{state.name} hardware error (code #{RNS.hexrep(<<error_byte>>)})")
    end

    state
  end

  def handle_command(state, @cmd_reset, <<0xF8>>) do
    if state.platform == @platform_esp32 and state.online do
      Logger.error("Detected reset while device was online, reinitialising device...")
    end

    state
  end

  def handle_command(state, @cmd_ready, _data) do
    process_queue(state)
  end

  def handle_command(state, _command, _data) do
    state
  end

  # ── Sub-interface helpers ──────────────────────────────────────────

  defp update_subinterface(state, index, fun) do
    case Map.get(state.subinterfaces, index) do
      nil ->
        state

      sub ->
        updated_sub = fun.(sub)
        %{state | subinterfaces: Map.put(state.subinterfaces, index, updated_sub)}
    end
  end

  defp process_queue(state) do
    Enum.reduce(state.subinterfaces, state, fn {_index, sub}, acc ->
      updated_sub = RNS.Interfaces.RNodeSubInterface.process_queue(sub)
      %{acc | subinterfaces: Map.put(acc.subinterfaces, updated_sub.index, updated_sub)}
    end)
  end

  # ── Serial backend ────────────────────────────────────────────────

  @doc "Check if circuits_uart is available."
  @spec circuits_uart_available?() :: boolean()
  def circuits_uart_available? do
    Code.ensure_loaded?(Circuits.UART)
  end

  # ── GenServer ─────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, "RNodeMultiInterface")
    server_name = Keyword.get(opts, :server_name)
    gen_opts = if server_name, do: [name: server_name], else: []
    GenServer.start_link(__MODULE__, [{:interface_name, name} | opts], gen_opts)
  end

  @impl true
  def init(opts) do
    interface_name = Keyword.get(opts, :interface_name, "RNodeMultiInterface")
    port = Keyword.get(opts, :port)
    speed = Keyword.get(opts, :speed, 115_200)
    owner = Keyword.get(opts, :owner)
    skip_open = Keyword.get(opts, :skip_open, false)
    test_mode = Keyword.get(opts, :test_mode, false)
    subint_config = Keyword.get(opts, :subint_config, [])
    id_interval = Keyword.get(opts, :id_interval)
    id_callsign = Keyword.get(opts, :id_callsign)

    {should_id, id_callsign_bytes} =
      if id_interval != nil and id_callsign != nil do
        encoded = if is_binary(id_callsign), do: id_callsign, else: to_string(id_callsign)

        if byte_size(encoded) <= @callsign_max_len do
          {true, encoded}
        else
          {false, nil}
        end
      else
        {false, nil}
      end

    hash = RNS.Interfaces.Interface.hash(%{name: interface_name})
    RNS.Interfaces.Interface.schedule_ets_refresh()

    state = %__MODULE__{
      name: interface_name,
      hash: hash,
      port: port,
      speed: speed,
      owner: owner,
      skip_open: skip_open,
      test_mode: test_mode,
      subint_config: subint_config,
      id_interval: id_interval,
      id_callsign: id_callsign_bytes,
      should_id: should_id,
      ifac_size: @default_ifac_size,
      hw_mtu: @hw_mtu,
      online: false,
      created: System.system_time(:second)
    }

    if skip_open do
      {:ok, state}
    else
      if port == nil do
        {:stop, :no_port}
      else
        case open_serial(state) do
          {:ok, new_state} -> {:ok, new_state}
          {:error, reason} -> {:stop, reason}
        end
      end
    end
  end

  @dialyzer {:nowarn_function, open_serial: 1}
  defp open_serial(state) do
    backend = if circuits_uart_available?(), do: :circuits_uart, else: :port

    case backend do
      :circuits_uart ->
        {:ok, pid} = Circuits.UART.start_link()

        case Circuits.UART.open(pid, state.port,
               speed: state.speed,
               data_bits: state.databits,
               stop_bits: state.stopbits,
               parity: state.parity,
               active: true
             ) do
          :ok ->
            {:ok, %{state | uart_pid: pid, backend: :circuits_uart, online: true}}

          {:error, reason} ->
            Circuits.UART.stop(pid)
            {:error, reason}
        end

      :port ->
        try do
          port_ref =
            Port.open({:spawn, "cat #{state.port}"}, [:binary, :stream, :exit_status, :use_stdio])

          {:ok, %{state | port_ref: port_ref, backend: :port, online: true}}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_call({:send_data, data, sub_index}, _from, state) do
    state = do_process_outgoing(state, data, sub_index)
    {:reply, :ok, state}
  end

  def handle_call(:detach, _from, state) do
    state = do_detach(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:serial_data, data}, state) do
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info({port_ref, {:data, data}}, state) when port_ref == state.port_ref do
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    if state.detached do
      {:noreply, state}
    else
      case open_serial(state) do
        {:ok, new_state} ->
          {:noreply, %{new_state | reconnecting: false}}

        {:error, _reason} ->
          Process.send_after(self(), :reconnect, @reconnect_wait)
          {:noreply, state}
      end
    end
  end

  def handle_info(:refresh_ets, state) do
    if state.hash do
      :ets.insert(:rns_interfaces, {state.hash, %{state | pid: self()}})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_detach(state)
    RNS.Interfaces.Interface.deregister_on_terminate(state)
  end

  # ── Serial data processing ────────────────────────────────────────

  defp handle_serial_data(state, data) do
    buffer = state.frame_buffer <> data
    {frames, remaining} = deframe(buffer)
    state = %{state | frame_buffer: remaining}

    Enum.reduce(frames, state, fn {command, frame_data}, acc ->
      if command in @data_commands do
        # Data frame - dispatch to appropriate sub-interface
        index = index_for_data_command(command) || acc.selected_index

        case Map.get(acc.subinterfaces, index) do
          nil ->
            acc

          sub ->
            {:ok, updated_sub} = RNS.Interfaces.RNodeSubInterface.process_incoming(sub, frame_data)
            notify_owner(acc, frame_data, index)
            %{acc | subinterfaces: Map.put(acc.subinterfaces, index, updated_sub)}
        end
      else
        handle_command(acc, command, frame_data)
      end
    end)
  end

  defp notify_owner(%{owner: nil}, _data, _index), do: :ok

  defp notify_owner(%{owner: owner}, data, index) when is_pid(owner) do
    send(owner, {:rnode_multi_data, data, index})
  end

  defp notify_owner(%{owner: fun}, data, index) when is_function(fun, 2) do
    fun.(data, index)
  end

  defp notify_owner(%{owner: {mod, fun}}, data, index) do
    apply(mod, fun, [data, index])
  end

  defp notify_owner(_, _, _), do: :ok

  # ── Process outgoing ───────────────────────────────────────────────

  @impl true
  @doc "Process outgoing data for a sub-interface."
  @spec process_outgoing(map(), binary()) :: {:ok, map()} | {:error, term()}
  def process_outgoing(state, _data) do
    # Direct transmission on parent is a no-op, matching Python
    {:ok, state}
  end

  @doc "Process outgoing data routed through a specific sub-interface."
  @spec process_outgoing(map(), binary(), non_neg_integer()) :: map()
  def process_outgoing(state, data, sub_index) do
    do_process_outgoing(state, data, sub_index)
  end

  defp do_process_outgoing(state, data, sub_index) do
    escaped = kiss_escape(data)
    frame = <<@fend, @cmd_sel_int, sub_index, @fend, @fend, @cmd_data>> <> escaped <> <<@fend>>

    case do_write(state, frame) do
      :ok ->
        %{state | txb: state.txb + byte_size(data)}

      {:error, _reason} ->
        state
    end
  end

  @dialyzer {:nowarn_function, do_write: 2}
  defp do_write(%{backend: :circuits_uart, uart_pid: pid}, data) do
    Circuits.UART.write(pid, data)
  end

  defp do_write(%{backend: :port, port_ref: ref}, data) when is_port(ref) do
    Port.command(ref, data)
    :ok
  end

  defp do_write(_, _data), do: {:error, :no_backend}

  # ── Process incoming ───────────────────────────────────────────────

  @impl true
  @doc "Process incoming data (called from sub-interface)."
  @spec process_incoming(map(), binary()) :: {:ok, map()} | {:error, term()}
  def process_incoming(state, data) do
    {:ok, %{state | rxb: state.rxb + byte_size(data)}}
  end

  # ── Detach ─────────────────────────────────────────────────────────

  @impl true
  @doc "Detach the interface."
  @spec detach(map()) :: :ok | map()
  def detach(state) do
    do_detach(state)
  end

  defp do_detach(state) do
    # Turn off radios on all sub-interfaces
    Enum.each(state.subinterfaces, fn {index, _sub} ->
      cmd = build_sel_command(index, @cmd_radio_state, encode_radio_state(@radio_state_off))
      do_write(state, cmd)
    end)

    # Send leave command
    do_write(state, build_leave_frame())

    # Close serial port
    close_port(state)

    %{state | online: false, detached: true}
  end

  @dialyzer {:nowarn_function, close_port: 1}
  defp close_port(%{backend: :circuits_uart, uart_pid: pid}) when pid != nil do
    Circuits.UART.close(pid)
    Circuits.UART.stop(pid)
  rescue
    e ->
      Logger.debug("RNodeMulti UART close failed (may already be closed): #{inspect(e)}")
      :ok
  end

  defp close_port(%{backend: :port, port_ref: ref}) when is_port(ref) do
    Port.close(ref)
  rescue
    e ->
      Logger.debug("RNodeMulti port close failed (may already be closed): #{inspect(e)}")
      :ok
  end

  defp close_port(_state), do: :ok

  # ── Announce tracking ──────────────────────────────────────────────

  @doc "Track received announce (from spawned sub-interfaces)."
  @spec received_announce(map(), boolean()) :: map()
  def received_announce(state, from_spawned \\ false) do
    if from_spawned do
      ia_freq_deque = state.ia_freq_deque ++ [System.system_time(:second)]
      %{state | ia_freq_deque: ia_freq_deque}
    else
      state
    end
  end

  @doc "Track sent announce (from spawned sub-interfaces)."
  @spec sent_announce(map(), boolean()) :: map()
  def sent_announce(state, from_spawned \\ false) do
    if from_spawned do
      oa_freq_deque = state.oa_freq_deque ++ [System.system_time(:second)]
      %{state | oa_freq_deque: oa_freq_deque}
    else
      state
    end
  end

  @doc "Should ingress limit always returns false."
  @spec should_ingress_limit(map()) :: {boolean(), map()}
  def should_ingress_limit(state), do: {false, state}

  defimpl String.Chars, for: __MODULE__ do
    def to_string(interface) do
      "RNodeMultiInterface[#{interface.name}]"
    end
  end
end

defmodule RNS.Interfaces.RNodeSubInterface do
  @moduledoc """
  Sub-interface for RNode Multi-radio LoRa interface.

  Each sub-interface represents an independent radio on an RNode device,
  with its own frequency, bandwidth, spreading factor, coding rate, and
  TX power configuration. Data is sent through the parent
  `RNodeMultiInterface` which handles serial communication.
  """

  use RNS.Interfaces.Interface

  require Logger

  # Radio frequency limits based on interface type
  @low_freq_min 137_000_000
  @low_freq_max 1_000_000_000
  @high_freq_min 2_200_000_000
  @high_freq_max 2_600_000_000

  @rssi_offset 157
  @q_snr_min_base -9
  @q_snr_max 6
  @q_snr_step 2

  @hw_mtu 508
  @default_ifac_size 8

  defstruct default_fields() ++
              [
                # Sub-interface identity
                index: 0,
                interface_type: nil,
                parent_pid: nil,

                # Radio configuration (desired)
                frequency: nil,
                bandwidth: nil,
                txpower: nil,
                sf: nil,
                cr: nil,
                state: 0x00,
                st_alock: nil,
                lt_alock: nil,
                flow_control: false,

                # Reported radio state
                r_frequency: nil,
                r_bandwidth: nil,
                r_txpower: nil,
                r_sf: nil,
                r_cr: nil,
                r_state: nil,
                r_lock: nil,
                r_stat_rx: nil,
                r_stat_tx: nil,
                r_stat_rssi: nil,
                r_stat_snr: nil,
                r_stat_q: nil,
                r_st_alock: nil,
                r_lt_alock: nil,
                r_airtime_short: 0.0,
                r_airtime_long: 0.0,
                r_channel_load_short: 0.0,
                r_channel_load_long: 0.0,
                r_symbol_time_ms: nil,
                r_symbol_rate: nil,
                r_preamble_symbols: nil,
                r_preamble_time_ms: nil,
                r_csma_slot_time_ms: nil,

                # Flow control
                interface_ready: false,
                packet_queue: :queue.new(),

                # Owner for callbacks
                owner: nil
              ]

  @doc "Returns the RSSI offset constant."
  @spec rssi_offset() :: integer()
  def rssi_offset, do: @rssi_offset

  @doc "Returns all public constants."
  def constants do
    %{
      low_freq_min: @low_freq_min,
      low_freq_max: @low_freq_max,
      high_freq_min: @high_freq_min,
      high_freq_max: @high_freq_max,
      rssi_offset: @rssi_offset,
      q_snr_min_base: @q_snr_min_base,
      q_snr_max: @q_snr_max,
      q_snr_step: @q_snr_step,
      hw_mtu: @hw_mtu,
      default_ifac_size: @default_ifac_size
    }
  end

  @doc "Create a new sub-interface."
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    name = Keyword.get(opts, :name, "RNodeSubInterface")
    index = Keyword.get(opts, :index, 0)
    interface_type = Keyword.get(opts, :interface_type, "SX127X")
    parent_interface = Keyword.get(opts, :parent_interface)
    parent_pid = Keyword.get(opts, :parent_pid)
    frequency = Keyword.get(opts, :frequency)
    bandwidth = Keyword.get(opts, :bandwidth)
    txpower = Keyword.get(opts, :txpower)
    sf = Keyword.get(opts, :sf)
    cr = Keyword.get(opts, :cr)
    flow_control = Keyword.get(opts, :flow_control, false)
    st_alock = Keyword.get(opts, :st_alock)
    lt_alock = Keyword.get(opts, :lt_alock)
    owner = Keyword.get(opts, :owner)

    hash = RNS.Interfaces.Interface.hash(%{name: name})

    %__MODULE__{
      name: name,
      hash: hash,
      index: index,
      interface_type: interface_type,
      parent_interface: parent_interface,
      parent_pid: parent_pid,
      frequency: frequency,
      bandwidth: bandwidth,
      txpower: txpower,
      sf: sf,
      cr: cr,
      flow_control: flow_control,
      st_alock: st_alock,
      lt_alock: lt_alock,
      owner: owner,
      ifac_size: @default_ifac_size,
      hw_mtu: @hw_mtu,
      online: false,
      interface_ready: false,
      created: System.system_time(:second)
    }
  end

  @doc "Validate radio parameters for a sub-interface."
  @spec validate_radio_params(%__MODULE__{}) :: :ok | {:error, String.t()}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate_radio_params(sub) do
    cond do
      sub.frequency == nil ->
        {:error, "No frequency configured"}

      sub.interface_type in ["SX126X", "SX127X"] and
          (sub.frequency < @low_freq_min or sub.frequency > @low_freq_max) ->
        {:error, "Invalid frequency for #{sub.interface_type}: #{sub.frequency}"}

      sub.interface_type == "SX128X" and
          (sub.frequency < @high_freq_min or sub.frequency > @high_freq_max) ->
        {:error, "Invalid frequency for SX128X: #{sub.frequency}"}

      sub.interface_type not in ["SX126X", "SX127X", "SX128X"] ->
        {:error, "Invalid interface type: #{sub.interface_type}"}

      sub.bandwidth == nil ->
        {:error, "No bandwidth configured"}

      sub.bandwidth < 7800 or sub.bandwidth > 1_625_000 ->
        {:error, "Invalid bandwidth: #{sub.bandwidth}"}

      sub.txpower == nil ->
        {:error, "No TX power configured"}

      sub.txpower < -9 or sub.txpower > 37 ->
        {:error, "Invalid TX power: #{sub.txpower}"}

      sub.sf == nil ->
        {:error, "No spreading factor configured"}

      sub.sf < 5 or sub.sf > 12 ->
        {:error, "Invalid spreading factor: #{sub.sf}"}

      sub.cr == nil ->
        {:error, "No coding rate configured"}

      sub.cr < 5 or sub.cr > 8 ->
        {:error, "Invalid coding rate: #{sub.cr}"}

      sub.st_alock != nil and (sub.st_alock < 0.0 or sub.st_alock > 100.0) ->
        {:error, "Invalid short-term airtime limit: #{sub.st_alock}"}

      sub.lt_alock != nil and (sub.lt_alock < 0.0 or sub.lt_alock > 100.0) ->
        {:error, "Invalid long-term airtime limit: #{sub.lt_alock}"}

      true ->
        :ok
    end
  end

  @doc "Calculate LoRa bitrate from radio parameters."
  @spec calculate_bitrate(integer(), integer(), integer()) :: float()
  def calculate_bitrate(sf, cr, bw) when sf > 0 and cr > 0 and bw > 0 do
    sf * (4.0 / cr / (:math.pow(2, sf) / (bw / 1000))) * 1000
  rescue
    e ->
      Logger.debug("Bitrate calculation failed (sf=#{sf}, cr=#{cr}, bw=#{bw}): #{inspect(e)}")
      0.0
  end

  def calculate_bitrate(_, _, _), do: 0.0

  @doc "Calculate signal quality from SNR and spreading factor."
  @spec calculate_quality(float(), integer() | nil) :: float() | nil
  def calculate_quality(_snr, nil), do: nil

  def calculate_quality(snr, sf) when is_number(sf) do
    sfs = sf - 7
    q_snr_min = @q_snr_min_base - sfs * @q_snr_step
    q_snr_span = @q_snr_max - q_snr_min

    quality = (snr - q_snr_min) / q_snr_span * 100
    quality = Float.round(quality, 1)

    cond do
      quality > 100.0 -> 100.0
      quality < 0.0 -> 0.0
      true -> quality
    end
  rescue
    e ->
      Logger.debug("Signal quality calculation failed: #{inspect(e)}")
      nil
  end

  @doc "Update bitrate based on reported radio parameters."
  @spec update_bitrate(%__MODULE__{}) :: %__MODULE__{}
  def update_bitrate(sub) do
    if sub.r_sf != nil and sub.r_cr != nil and sub.r_bandwidth != nil do
      bitrate = calculate_bitrate(sub.r_sf, sub.r_cr, sub.r_bandwidth)
      %{sub | bitrate: bitrate}
    else
      sub
    end
  end

  @doc "Validate reported radio state against desired configuration."
  @spec validate_radio_state(%__MODULE__{}) :: boolean()
  def validate_radio_state(sub) do
    freq_ok =
      sub.r_frequency == nil or
        abs(sub.frequency - sub.r_frequency) <= 100

    bw_ok = sub.r_bandwidth == nil or sub.bandwidth == sub.r_bandwidth
    txp_ok = sub.r_txpower == nil or sub.txpower == sub.r_txpower
    sf_ok = sub.r_sf == nil or sub.sf == sub.r_sf
    state_ok = sub.r_state == nil or sub.state == sub.r_state

    freq_ok and bw_ok and txp_ok and sf_ok and state_ok
  end

  @impl true
  @doc "Process incoming data on this sub-interface."
  @spec process_incoming(%__MODULE__{}, binary()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def process_incoming(sub, data) do
    sub = %{sub | rxb: sub.rxb + byte_size(data), r_stat_rssi: nil, r_stat_snr: nil}
    RNS.Interfaces.Interface.deliver_to_transport(data, sub)
    {:ok, sub}
  end

  @impl true
  @doc "Process outgoing data through parent interface."
  @spec process_outgoing(%__MODULE__{}, binary()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def process_outgoing(sub, data) do
    if sub.online do
      if sub.interface_ready do
        sub =
          if sub.flow_control do
            %{sub | interface_ready: false}
          else
            sub
          end

        sub = %{sub | txb: sub.txb + byte_size(data)}

        # Send through parent
        if sub.parent_pid do
          GenServer.call(sub.parent_pid, {:send_data, data, sub.index})
        end

        {:ok, sub}
      else
        {:ok, queue(sub, data)}
      end
    else
      {:ok, sub}
    end
  end

  @doc "Queue a packet for later transmission."
  @spec queue(%__MODULE__{}, binary()) :: %__MODULE__{}
  def queue(sub, data) do
    %{sub | packet_queue: :queue.in(data, sub.packet_queue)}
  end

  @doc "Process queued packets."
  @spec process_queue(%__MODULE__{}) :: %__MODULE__{}
  def process_queue(sub) do
    case :queue.out(sub.packet_queue) do
      {{:value, data}, remaining} ->
        sub = %{sub | packet_queue: remaining, interface_ready: true}
        {:ok, sub} = process_outgoing(sub, data)
        sub

      {:empty, _} ->
        %{sub | interface_ready: true}
    end
  end

  @impl true
  @doc "Detach the sub-interface."
  @spec detach(%__MODULE__{}) :: :ok | %__MODULE__{}
  def detach(sub) do
    %{sub | online: false, detached: true}
  end

  @doc "Should ingress limit always returns false."
  @spec should_ingress_limit(%__MODULE__{}) :: {boolean(), %__MODULE__{}}
  def should_ingress_limit(sub), do: {false, sub}

  defimpl String.Chars, for: __MODULE__ do
    def to_string(sub) do
      parent_name =
        case sub.parent_interface do
          %{name: name} -> name
          _ -> "RNodeMulti"
        end

      "#{parent_name}[#{sub.name}]"
    end
  end
end
