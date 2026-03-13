defmodule RNS.Interfaces.RNodeInterface do
  @moduledoc """
  RNode LoRa radio interface for RNS.

  Communicates with RNode hardware via serial port using a KISS-based
  command protocol. Supports configurable radio parameters (frequency,
  bandwidth, spreading factor, coding rate, TX power), firmware detection,
  flow control, and automatic reconnection.

  The RNode KISS protocol extends standard KISS with radio-specific
  commands for configuration, telemetry, and device management.

  Matches `python/RNS/Interfaces/RNodeInterface.py`.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  import Bitwise

  # ── RNode KISS command constants ──────────────────────────────────

  # Frame delimiters (same as standard KISS)
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
  @cmd_stat_rx 0x21
  @cmd_stat_tx 0x22
  @cmd_stat_rssi 0x23
  @cmd_stat_snr 0x24
  @cmd_stat_chtm 0x25
  @cmd_stat_phyprm 0x26
  @cmd_stat_bat 0x27
  @cmd_stat_csma 0x28
  @cmd_stat_temp 0x29
  @cmd_blink 0x30
  @cmd_random 0x40
  @cmd_fb_ext 0x41
  @cmd_fb_read 0x42
  @cmd_fb_write 0x43
  @cmd_bt_ctrl 0x46
  @cmd_platform 0x48
  @cmd_mcu 0x49
  @cmd_fw_version 0x50
  @cmd_rom_read 0x51
  @cmd_disp_read 0x66
  @cmd_reset 0x55
  @cmd_error 0x90

  # Detection protocol
  @detect_req 0x73
  @detect_resp 0x46

  # Radio states
  @radio_state_off 0x00
  @radio_state_on 0x01
  @radio_state_ask 0xFF

  # Error codes
  @error_initradio 0x01
  @error_txfailed 0x02
  @error_eeprom_locked 0x03
  @error_queue_full 0x04
  @error_memory_low 0x05
  @error_modem_timeout 0x06

  # Platform IDs
  @platform_avr 0x90
  @platform_esp32 0x80
  @platform_nrf52 0x70

  # Battery states
  @battery_state_unknown 0x00
  @battery_state_discharging 0x01
  @battery_state_charging 0x02
  @battery_state_charged 0x03

  # ── Interface constants ───────────────────────────────────────────

  @max_chunk 32_768
  @default_ifac_size 8
  @hw_mtu 508
  @reconnect_wait 5_000

  # Radio parameter limits
  @freq_min 137_000_000
  @freq_max 3_000_000_000
  @rssi_offset 157
  @callsign_max_len 32

  # Firmware version requirements
  @required_fw_ver_maj 1
  @required_fw_ver_min 52

  # Signal quality calculation constants
  @q_snr_min_base -9
  @q_snr_max 6
  @q_snr_step 2

  # Display constants
  @fb_pixel_width 64
  @fb_bits_per_pixel 1
  @fb_pixels_per_byte 8
  @fb_bytes_per_line div(@fb_pixel_width * @fb_bits_per_pixel, @fb_pixels_per_byte)

  # ── Struct ────────────────────────────────────────────────────────

  defstruct default_fields() ++
              [
                # Serial config
                port: nil,
                speed: 115_200,
                databits: 8,
                parity: :none,
                stopbits: 1,

                # Radio configuration (desired)
                frequency: nil,
                bandwidth: nil,
                txpower: nil,
                sf: nil,
                cr: nil,
                st_alock: nil,
                lt_alock: nil,

                # Reported radio state (from device, prefix r_)
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
                r_random: nil,

                # Airtime and channel load
                r_airtime_short: 0.0,
                r_airtime_long: 0.0,
                r_channel_load_short: 0.0,
                r_channel_load_long: 0.0,

                # Physical parameters
                r_symbol_time_ms: nil,
                r_symbol_rate: nil,
                r_preamble_symbols: nil,
                r_preamble_time_ms: nil,
                r_csma_slot_time_ms: nil,
                r_csma_difs_ms: nil,

                # CSMA contention window
                r_csma_cw_band: nil,
                r_csma_cw_min: nil,
                r_csma_cw_max: nil,

                # RSSI / interference
                r_current_rssi: nil,
                r_noise_floor: nil,
                r_interference: nil,

                # Battery
                r_battery_state: @battery_state_unknown,
                r_battery_percent: 0,

                # Temperature
                r_temperature: nil,
                cpu_temp: nil,

                # Framebuffer / display
                r_framebuffer: <<>>,
                r_framebuffer_readtime: 0,
                r_framebuffer_latency: 0,
                r_disp: <<>>,
                r_disp_readtime: 0,
                r_disp_latency: 0,

                # Device info
                platform: nil,
                mcu: nil,
                detected: false,
                firmware_ok: false,
                maj_version: 0,
                min_version: 0,
                display: nil,
                hw_errors: [],

                # Flow control
                flow_control: false,
                interface_ready: true,
                flow_control_locked: 0,

                # Packet queue
                packet_queue: :queue.new(),

                # ID beacon
                id_interval: nil,
                id_callsign: nil,
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

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────

  # Command constant accessors
  def cmd_unknown, do: @cmd_unknown
  def cmd_data, do: @cmd_data
  def cmd_frequency, do: @cmd_frequency
  def cmd_bandwidth, do: @cmd_bandwidth
  def cmd_txpower, do: @cmd_txpower
  def cmd_sf, do: @cmd_sf
  def cmd_cr, do: @cmd_cr
  def cmd_radio_state, do: @cmd_radio_state
  def cmd_radio_lock, do: @cmd_radio_lock
  def cmd_detect, do: @cmd_detect
  def cmd_leave, do: @cmd_leave
  def cmd_st_alock, do: @cmd_st_alock
  def cmd_lt_alock, do: @cmd_lt_alock
  def cmd_ready, do: @cmd_ready
  def cmd_stat_rx, do: @cmd_stat_rx
  def cmd_stat_tx, do: @cmd_stat_tx
  def cmd_stat_rssi, do: @cmd_stat_rssi
  def cmd_stat_snr, do: @cmd_stat_snr
  def cmd_stat_chtm, do: @cmd_stat_chtm
  def cmd_stat_phyprm, do: @cmd_stat_phyprm
  def cmd_stat_bat, do: @cmd_stat_bat
  def cmd_stat_csma, do: @cmd_stat_csma
  def cmd_stat_temp, do: @cmd_stat_temp
  def cmd_blink, do: @cmd_blink
  def cmd_random, do: @cmd_random
  def cmd_fb_ext, do: @cmd_fb_ext
  def cmd_fb_read, do: @cmd_fb_read
  def cmd_fb_write, do: @cmd_fb_write
  def cmd_bt_ctrl, do: @cmd_bt_ctrl
  def cmd_platform, do: @cmd_platform
  def cmd_mcu, do: @cmd_mcu
  def cmd_fw_version, do: @cmd_fw_version
  def cmd_rom_read, do: @cmd_rom_read
  def cmd_disp_read, do: @cmd_disp_read
  def cmd_reset, do: @cmd_reset
  def cmd_error, do: @cmd_error

  def detect_req, do: @detect_req
  def detect_resp, do: @detect_resp

  def radio_state_off, do: @radio_state_off
  def radio_state_on, do: @radio_state_on
  def radio_state_ask, do: @radio_state_ask

  def error_initradio, do: @error_initradio
  def error_txfailed, do: @error_txfailed
  def error_eeprom_locked, do: @error_eeprom_locked
  def error_queue_full, do: @error_queue_full
  def error_memory_low, do: @error_memory_low
  def error_modem_timeout, do: @error_modem_timeout

  def platform_avr, do: @platform_avr
  def platform_esp32, do: @platform_esp32
  def platform_nrf52, do: @platform_nrf52

  def battery_state_unknown, do: @battery_state_unknown
  def battery_state_discharging, do: @battery_state_discharging
  def battery_state_charging, do: @battery_state_charging
  def battery_state_charged, do: @battery_state_charged

  @doc "Returns the maximum chunk size for serial writes."
  @spec max_chunk() :: pos_integer()
  def max_chunk, do: @max_chunk

  @doc "Returns the default IFAC size."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns the hardware MTU (508 bytes)."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu

  @doc "Returns the reconnect wait time in milliseconds."
  @spec reconnect_wait() :: pos_integer()
  def reconnect_wait, do: @reconnect_wait

  @doc "Returns the minimum valid frequency in Hz."
  @spec freq_min() :: pos_integer()
  def freq_min, do: @freq_min

  @doc "Returns the maximum valid frequency in Hz."
  @spec freq_max() :: pos_integer()
  def freq_max, do: @freq_max

  @doc "Returns the RSSI offset (157)."
  @spec rssi_offset() :: pos_integer()
  def rssi_offset, do: @rssi_offset

  @doc "Returns the maximum callsign length."
  @spec callsign_max_len() :: pos_integer()
  def callsign_max_len, do: @callsign_max_len

  @doc "Returns the required firmware major version."
  @spec required_fw_ver_maj() :: pos_integer()
  def required_fw_ver_maj, do: @required_fw_ver_maj

  @doc "Returns the required firmware minor version."
  @spec required_fw_ver_min() :: pos_integer()
  def required_fw_ver_min, do: @required_fw_ver_min

  @doc "Returns the Q SNR min base value."
  @spec q_snr_min_base() :: integer()
  def q_snr_min_base, do: @q_snr_min_base

  @doc "Returns the Q SNR max value."
  @spec q_snr_max() :: integer()
  def q_snr_max, do: @q_snr_max

  @doc "Returns the Q SNR step value."
  @spec q_snr_step() :: integer()
  def q_snr_step, do: @q_snr_step

  @doc "Returns the framebuffer bytes per line."
  @spec fb_bytes_per_line() :: pos_integer()
  def fb_bytes_per_line, do: @fb_bytes_per_line

  @doc "Checks if `circuits_uart` is available."
  @spec circuits_uart_available?() :: boolean()
  def circuits_uart_available? do
    Code.ensure_loaded?(Circuits.UART)
  end

  # ── KISS escape/unescape (RNode-specific: does NOT strip port nibble) ──

  @doc """
  Escapes KISS special bytes in data for RNode protocol.

  Replaces FESC (0xDB) with FESC+TFESC, then FEND (0xC0) with FESC+TFEND.
  Order matters: escape 0xDB first to prevent double-escaping.
  """
  @spec kiss_escape(binary()) :: binary()
  def kiss_escape(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.flat_map(fn
      byte when byte == @fesc -> [@fesc, @tfesc]
      byte when byte == @fend -> [@fesc, @tfend]
      byte -> [byte]
    end)
    |> :binary.list_to_bin()
  end

  @doc """
  Unescapes KISS escape sequences in data.
  """
  @spec kiss_unescape(binary()) :: binary()
  def kiss_unescape(data) do
    data
    |> :binary.bin_to_list()
    |> unescape_list([])
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  defp unescape_list([], acc), do: acc
  defp unescape_list([@fesc, @tfend | rest], acc), do: unescape_list(rest, [@fend | acc])
  defp unescape_list([@fesc, @tfesc | rest], acc), do: unescape_list(rest, [@fesc | acc])
  defp unescape_list([byte | rest], acc), do: unescape_list(rest, [byte | acc])

  # ── Radio parameter validation ──────────────────────────────────

  @doc """
  Validates radio parameters for an RNode interface.

  Returns `:ok` if all parameters are valid, or `{:error, reason}`.

  ## Valid ranges
    * `:frequency` — 137,000,000 to 3,000,000,000 Hz
    * `:bandwidth` — 7,800 to 1,625,000 Hz
    * `:txpower` — 0 to 37 dBm
    * `:sf` — 5 to 12
    * `:cr` — 5 to 8
    * `:st_alock` — 0.0 to 100.0 (or nil)
    * `:lt_alock` — 0.0 to 100.0 (or nil)
    * `:id_callsign` — max 32 bytes UTF-8 (or nil)
  """
  @spec validate_radio_params(keyword()) :: :ok | {:error, String.t()}
  def validate_radio_params(opts) do
    with :ok <- validate_frequency(Keyword.get(opts, :frequency)),
         :ok <- validate_bandwidth(Keyword.get(opts, :bandwidth)),
         :ok <- validate_txpower(Keyword.get(opts, :txpower)),
         :ok <- validate_sf(Keyword.get(opts, :sf)),
         :ok <- validate_cr(Keyword.get(opts, :cr)),
         :ok <- validate_alock(Keyword.get(opts, :st_alock), "st_alock"),
         :ok <- validate_alock(Keyword.get(opts, :lt_alock), "lt_alock"),
         :ok <- validate_callsign(Keyword.get(opts, :id_callsign)) do
      :ok
    end
  end

  defp validate_frequency(nil), do: {:error, "frequency is required"}

  defp validate_frequency(freq) when is_integer(freq) do
    if freq >= @freq_min and freq <= @freq_max,
      do: :ok,
      else: {:error, "frequency #{freq} Hz out of range (#{@freq_min}-#{@freq_max} Hz)"}
  end

  defp validate_frequency(_), do: {:error, "frequency must be an integer in Hz"}

  defp validate_bandwidth(nil), do: {:error, "bandwidth is required"}

  defp validate_bandwidth(bw) when is_integer(bw) do
    if bw >= 7_800 and bw <= 1_625_000,
      do: :ok,
      else: {:error, "bandwidth #{bw} Hz out of range (7800-1625000 Hz)"}
  end

  defp validate_bandwidth(_), do: {:error, "bandwidth must be an integer in Hz"}

  defp validate_txpower(nil), do: {:error, "txpower is required"}

  defp validate_txpower(power) when is_integer(power) do
    if power >= 0 and power <= 37,
      do: :ok,
      else: {:error, "txpower #{power} dBm out of range (0-37)"}
  end

  defp validate_txpower(_), do: {:error, "txpower must be an integer in dBm"}

  defp validate_sf(nil), do: {:error, "spreading factor is required"}

  defp validate_sf(sf) when is_integer(sf) do
    if sf >= 5 and sf <= 12,
      do: :ok,
      else: {:error, "spreading factor #{sf} out of range (5-12)"}
  end

  defp validate_sf(_), do: {:error, "spreading factor must be an integer"}

  defp validate_cr(nil), do: {:error, "coding rate is required"}

  defp validate_cr(cr) when is_integer(cr) do
    if cr >= 5 and cr <= 8,
      do: :ok,
      else: {:error, "coding rate #{cr} out of range (5-8)"}
  end

  defp validate_cr(_), do: {:error, "coding rate must be an integer"}

  defp validate_alock(nil, _name), do: :ok

  defp validate_alock(value, name) when is_number(value) do
    if value >= 0.0 and value <= 100.0,
      do: :ok,
      else: {:error, "#{name} #{value}% out of range (0.0-100.0%)"}
  end

  defp validate_alock(_, name), do: {:error, "#{name} must be a number"}

  defp validate_callsign(nil), do: :ok

  defp validate_callsign(callsign) when is_binary(callsign) do
    if byte_size(callsign) <= @callsign_max_len,
      do: :ok,
      else: {:error, "callsign exceeds #{@callsign_max_len} bytes"}
  end

  defp validate_callsign(_), do: {:error, "callsign must be a string"}

  # ── Radio configuration commands ─────────────────────────────────

  @doc """
  Builds a KISS command frame with the given command byte and escaped payload.
  """
  @spec build_kiss_command(byte(), binary()) :: binary()
  def build_kiss_command(command, payload) do
    <<@fend, command>> <> kiss_escape(payload) <> <<@fend>>
  end

  @doc """
  Builds a KISS command frame for a single byte value (no escaping needed).
  """
  @spec build_kiss_command_byte(byte(), byte()) :: binary()
  def build_kiss_command_byte(command, value) do
    <<@fend, command, value, @fend>>
  end

  @doc "Encodes a frequency (Hz) as a 4-byte big-endian KISS command."
  @spec encode_frequency(non_neg_integer()) :: binary()
  def encode_frequency(freq) do
    build_kiss_command(@cmd_frequency, <<freq::unsigned-big-32>>)
  end

  @doc "Encodes a bandwidth (Hz) as a 4-byte big-endian KISS command."
  @spec encode_bandwidth(non_neg_integer()) :: binary()
  def encode_bandwidth(bw) do
    build_kiss_command(@cmd_bandwidth, <<bw::unsigned-big-32>>)
  end

  @doc "Encodes TX power (dBm) as a 1-byte KISS command."
  @spec encode_txpower(non_neg_integer()) :: binary()
  def encode_txpower(power) do
    build_kiss_command_byte(@cmd_txpower, power)
  end

  @doc "Encodes spreading factor as a 1-byte KISS command."
  @spec encode_sf(non_neg_integer()) :: binary()
  def encode_sf(sf) do
    build_kiss_command_byte(@cmd_sf, sf)
  end

  @doc "Encodes coding rate as a 1-byte KISS command."
  @spec encode_cr(non_neg_integer()) :: binary()
  def encode_cr(cr) do
    build_kiss_command_byte(@cmd_cr, cr)
  end

  @doc "Encodes radio state as a 1-byte KISS command."
  @spec encode_radio_state(byte()) :: binary()
  def encode_radio_state(radio_state) do
    build_kiss_command_byte(@cmd_radio_state, radio_state)
  end

  @doc "Encodes short-term airtime lock as a 2-byte KISS command."
  @spec encode_st_alock(float()) :: binary()
  def encode_st_alock(value) do
    encoded = trunc(value * 100)
    build_kiss_command(@cmd_st_alock, <<encoded::unsigned-big-16>>)
  end

  @doc "Encodes long-term airtime lock as a 2-byte KISS command."
  @spec encode_lt_alock(float()) :: binary()
  def encode_lt_alock(value) do
    encoded = trunc(value * 100)
    build_kiss_command(@cmd_lt_alock, <<encoded::unsigned-big-16>>)
  end

  @doc "Builds the detect request frame sequence."
  @spec build_detect_frame() :: binary()
  def build_detect_frame do
    <<@fend, @cmd_detect, @detect_req, @fend, @cmd_fw_version, 0x00, @fend, @cmd_platform, 0x00,
      @fend, @cmd_mcu, 0x00, @fend>>
  end

  @doc "Builds the leave/disconnect frame."
  @spec build_leave_frame() :: binary()
  def build_leave_frame do
    <<@fend, @cmd_leave, 0xFF, @fend>>
  end

  # ── Bitrate calculation ──────────────────────────────────────────

  @doc """
  Calculates the LoRa bitrate from radio parameters.

  Formula: `sf * ((4.0 / cr) / (2^sf / (bw / 1000))) * 1000`

  Returns the bitrate in bits per second.
  """
  @spec calculate_bitrate(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: float()
  def calculate_bitrate(sf, cr, bw) when sf > 0 and cr > 0 and bw > 0 do
    sf * (4.0 / cr / (:math.pow(2, sf) / (bw / 1000))) * 1000
  end

  def calculate_bitrate(_, _, _), do: 0.0

  # ── Signal quality calculation ───────────────────────────────────

  @doc """
  Calculates signal quality percentage from SNR and spreading factor.

  Uses the formula from Python: q_snr_min depends on SF, quality is
  a linear interpolation between q_snr_min and Q_SNR_MAX, clamped to [0, 100].
  """
  @spec calculate_quality(float(), non_neg_integer()) :: float()
  def calculate_quality(snr, sf) when is_number(snr) and is_integer(sf) do
    q_snr_min = @q_snr_min_base - (sf - 7) * @q_snr_step
    range = @q_snr_max - q_snr_min

    if range > 0 do
      ((snr - q_snr_min) / range * 100)
      |> max(0.0)
      |> min(100.0)
    else
      0.0
    end
  end

  def calculate_quality(_, _), do: 0.0

  # ── Firmware validation ──────────────────────────────────────────

  @doc """
  Validates firmware version against minimum requirements.

  Returns `true` if firmware is acceptable, `false` otherwise.
  Requires at least version #{@required_fw_ver_maj}.#{@required_fw_ver_min}.
  """
  @spec validate_firmware(non_neg_integer(), non_neg_integer()) :: boolean()
  def validate_firmware(maj, min) do
    maj > @required_fw_ver_maj or
      (maj == @required_fw_ver_maj and min >= @required_fw_ver_min)
  end

  # ── KISS frame parsing for RNode ─────────────────────────────────

  @doc """
  Extracts complete KISS frames from a buffer for RNode protocol.

  Unlike standard KISS, RNode uses the full command byte (no port nibble
  stripping). Returns `{frames, remaining_buffer}` where `frames` is a
  list of `{command, data}` tuples.
  """
  @spec deframe(binary()) :: {[{byte(), binary()}], binary()}
  def deframe(buffer) do
    deframe_acc(buffer, [], false, @cmd_unknown, <<>>)
  end

  defp deframe_acc(<<>>, frames, false, _cmd, _current) do
    {Enum.reverse(frames), <<>>}
  end

  defp deframe_acc(<<>>, frames, true, @cmd_unknown, _current) do
    {Enum.reverse(frames), <<@fend>>}
  end

  defp deframe_acc(<<>>, frames, true, cmd, current) do
    remaining = <<@fend, cmd>> <> current
    {Enum.reverse(frames), remaining}
  end

  defp deframe_acc(<<@fend, rest::binary>>, frames, true, cmd, current)
       when byte_size(current) > 0 do
    frame_data = kiss_unescape(current)
    deframe_acc(rest, [{cmd, frame_data} | frames], false, @cmd_unknown, <<>>)
  end

  defp deframe_acc(<<@fend, rest::binary>>, frames, _in_frame, _cmd, _current) do
    deframe_acc(rest, frames, true, @cmd_unknown, <<>>)
  end

  defp deframe_acc(<<byte, rest::binary>>, frames, true, @cmd_unknown, <<>>) do
    # First byte after FEND is the command — use full byte (no nibble stripping)
    deframe_acc(rest, frames, true, byte, <<>>)
  end

  defp deframe_acc(<<byte, rest::binary>>, frames, true, cmd, current) do
    deframe_acc(rest, frames, true, cmd, current <> <<byte>>)
  end

  defp deframe_acc(<<_byte, rest::binary>>, frames, false, cmd, current) do
    deframe_acc(rest, frames, false, cmd, current)
  end

  # ── Command response parsing ─────────────────────────────────────

  @doc """
  Parses an RNode command response and updates the state accordingly.

  Returns the updated state struct.
  """
  @spec handle_command(t(), byte(), binary()) :: t()
  def handle_command(state, @cmd_detect, <<byte>>) do
    %{state | detected: byte == @detect_resp}
  end

  def handle_command(state, @cmd_fw_version, <<maj, min>>) do
    firmware_ok = validate_firmware(maj, min)

    if not firmware_ok do
      Logger.error(
        "RNode #{state.name} firmware #{maj}.#{min} is below required " <>
          "#{@required_fw_ver_maj}.#{@required_fw_ver_min}"
      )
    end

    %{state | maj_version: maj, min_version: min, firmware_ok: firmware_ok}
  end

  def handle_command(state, @cmd_platform, <<platform>>) do
    %{state | platform: platform}
  end

  def handle_command(state, @cmd_mcu, <<mcu>>) do
    %{state | mcu: mcu}
  end

  def handle_command(state, @cmd_frequency, <<freq::unsigned-big-32>>) do
    state = %{state | r_frequency: freq}
    update_bitrate(state)
  end

  def handle_command(state, @cmd_bandwidth, <<bw::unsigned-big-32>>) do
    state = %{state | r_bandwidth: bw}
    update_bitrate(state)
  end

  def handle_command(state, @cmd_txpower, <<power>>) do
    %{state | r_txpower: power}
  end

  def handle_command(state, @cmd_sf, <<sf>>) do
    state = %{state | r_sf: sf}
    update_bitrate(state)
  end

  def handle_command(state, @cmd_cr, <<cr>>) do
    state = %{state | r_cr: cr}
    update_bitrate(state)
  end

  def handle_command(state, @cmd_radio_state, <<radio_state>>) do
    %{state | r_state: radio_state}
  end

  def handle_command(state, @cmd_radio_lock, <<lock>>) do
    %{state | r_lock: lock}
  end

  def handle_command(state, @cmd_stat_rx, <<a, b, c, d>>) do
    %{state | r_stat_rx: (a <<< 24) + (b <<< 16) + (c <<< 8) + d}
  end

  def handle_command(state, @cmd_stat_tx, <<a, b, c, d>>) do
    %{state | r_stat_tx: (a <<< 24) + (b <<< 16) + (c <<< 8) + d}
  end

  def handle_command(state, @cmd_stat_rssi, <<byte>>) do
    %{state | r_stat_rssi: byte - @rssi_offset}
  end

  def handle_command(state, @cmd_stat_snr, <<byte>>) do
    # SNR is a signed byte multiplied by 0.25
    snr_raw = if byte > 127, do: byte - 256, else: byte
    snr = snr_raw * 0.25
    sf = state.r_sf || 7
    quality = calculate_quality(snr, sf)
    %{state | r_stat_snr: snr, r_stat_q: quality}
  end

  def handle_command(state, @cmd_st_alock, <<value::unsigned-big-16>>) do
    %{state | r_st_alock: value / 100.0}
  end

  def handle_command(state, @cmd_lt_alock, <<value::unsigned-big-16>>) do
    %{state | r_lt_alock: value / 100.0}
  end

  def handle_command(state, @cmd_stat_chtm, data) when byte_size(data) >= 11 do
    <<as::unsigned-big-16, al::unsigned-big-16, cls::unsigned-big-16, cll::unsigned-big-16,
      rssi_byte, nf_byte, intf_byte, _rest::binary>> = data

    interference =
      if intf_byte == 0xFF, do: nil, else: intf_byte - @rssi_offset

    %{
      state
      | r_airtime_short: as / 100.0,
        r_airtime_long: al / 100.0,
        r_channel_load_short: cls / 100.0,
        r_channel_load_long: cll / 100.0,
        r_current_rssi: rssi_byte - @rssi_offset,
        r_noise_floor: nf_byte - @rssi_offset,
        r_interference: interference
    }
  end

  def handle_command(state, @cmd_stat_phyprm, data) when byte_size(data) >= 12 do
    <<sym_time::unsigned-big-16, sym_rate::unsigned-big-16, pre_sym::unsigned-big-16,
      pre_time::unsigned-big-16, csma_slot::unsigned-big-16, csma_difs::unsigned-big-16,
      _rest::binary>> = data

    %{
      state
      | r_symbol_time_ms: sym_time / 1000.0,
        r_symbol_rate: sym_rate,
        r_preamble_symbols: pre_sym,
        r_preamble_time_ms: pre_time,
        r_csma_slot_time_ms: csma_slot,
        r_csma_difs_ms: csma_difs
    }
  end

  def handle_command(state, @cmd_stat_csma, <<cw_band, cw_min, cw_max>>) do
    %{state | r_csma_cw_band: cw_band, r_csma_cw_min: cw_min, r_csma_cw_max: cw_max}
  end

  def handle_command(state, @cmd_stat_bat, <<bat_state, bat_percent>>) do
    percent = bat_percent |> max(0) |> min(100)
    %{state | r_battery_state: bat_state, r_battery_percent: percent}
  end

  def handle_command(state, @cmd_stat_temp, <<byte>>) do
    temp = byte - 120

    if temp >= -30 and temp <= 90 do
      %{state | r_temperature: temp, cpu_temp: temp}
    else
      %{state | r_temperature: nil, cpu_temp: nil}
    end
  end

  def handle_command(state, @cmd_random, <<byte>>) do
    %{state | r_random: byte}
  end

  def handle_command(state, @cmd_error, <<error_code>>) do
    hw_error = %{code: error_code, time: System.system_time(:second)}

    case error_code do
      @error_initradio ->
        Logger.error("RNode #{state.name}: radio initialization error (fatal)")
        %{state | hw_errors: [hw_error | state.hw_errors]}

      @error_txfailed ->
        Logger.error("RNode #{state.name}: TX failed error (fatal)")
        %{state | hw_errors: [hw_error | state.hw_errors]}

      @error_memory_low ->
        Logger.warning("RNode #{state.name}: low memory warning")
        %{state | hw_errors: [hw_error | state.hw_errors]}

      @error_modem_timeout ->
        Logger.warning("RNode #{state.name}: modem timeout warning")
        %{state | hw_errors: [hw_error | state.hw_errors]}

      @error_eeprom_locked ->
        Logger.warning("RNode #{state.name}: EEPROM locked")
        %{state | hw_errors: [hw_error | state.hw_errors]}

      @error_queue_full ->
        Logger.warning("RNode #{state.name}: queue full")
        %{state | hw_errors: [hw_error | state.hw_errors]}

      _ ->
        Logger.error("RNode #{state.name}: unknown error code #{error_code}")
        %{state | hw_errors: [hw_error | state.hw_errors]}
    end
  end

  def handle_command(state, @cmd_fb_read, data) when byte_size(data) == 512 do
    latency =
      if state.r_framebuffer_readtime > 0 do
        System.monotonic_time(:millisecond) - state.r_framebuffer_readtime
      else
        0
      end

    %{state | r_framebuffer: data, r_framebuffer_latency: latency}
  end

  def handle_command(state, @cmd_disp_read, data) when byte_size(data) == 1024 do
    latency =
      if state.r_disp_readtime > 0 do
        System.monotonic_time(:millisecond) - state.r_disp_readtime
      else
        0
      end

    %{state | r_disp: data, r_disp_latency: latency}
  end

  # Catch-all for unrecognized/incomplete commands
  def handle_command(state, _cmd, _data), do: state

  # ── Radio state validation ───────────────────────────────────────

  @doc """
  Validates that the reported radio state matches desired configuration.

  Compares reported vs desired values for frequency (within 100 Hz),
  bandwidth, TX power, spreading factor, and radio state.
  """
  @spec validate_radio_state(t()) :: boolean()
  def validate_radio_state(state) do
    freq_ok =
      state.r_frequency != nil and state.frequency != nil and
        abs(state.r_frequency - state.frequency) <= 100

    bw_ok = state.r_bandwidth == state.bandwidth
    power_ok = state.r_txpower == state.txpower
    sf_ok = state.r_sf == state.sf
    state_ok = state.r_state == @radio_state_on

    freq_ok and bw_ok and power_ok and sf_ok and state_ok
  end

  @doc """
  Resets all reported radio state fields to nil.
  """
  @spec reset_radio_state(t()) :: t()
  def reset_radio_state(state) do
    %{
      state
      | r_frequency: nil,
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
        detected: false
    }
  end

  # ── Battery helpers ──────────────────────────────────────────────

  @doc "Returns the battery state."
  @spec get_battery_state(t()) :: byte()
  def get_battery_state(%{r_battery_state: state}), do: state

  @doc "Returns a human-readable battery state string."
  @spec get_battery_state_string(t()) :: String.t()
  def get_battery_state_string(%{r_battery_state: @battery_state_charging}), do: "charging"
  def get_battery_state_string(%{r_battery_state: @battery_state_charged}), do: "charged"
  def get_battery_state_string(%{r_battery_state: @battery_state_discharging}), do: "discharging"
  def get_battery_state_string(_), do: "unknown"

  @doc "Returns the battery percentage (0-100)."
  @spec get_battery_percent(t()) :: non_neg_integer()
  def get_battery_percent(%{r_battery_percent: percent}), do: percent

  # ── GenServer start ─────────────────────────────────────────────

  @doc """
  Starts an RNode interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:port` — serial port path (required unless skip_open)
    * `:frequency` — radio frequency in Hz (required)
    * `:bandwidth` — radio bandwidth in Hz (required)
    * `:txpower` — TX power in dBm (required)
    * `:sf` — spreading factor 5-12 (required)
    * `:cr` — coding rate 5-8 (required)
    * `:speed` — serial baud rate (default: 115200)
    * `:flow_control` — enable flow control (default: false)
    * `:st_alock` — short-term airtime lock percentage (optional)
    * `:lt_alock` — long-term airtime lock percentage (optional)
    * `:id_interval` — beacon ID interval in seconds (optional)
    * `:id_callsign` — beacon callsign string (optional)
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

  @doc "Sends data out through this RNode interface."
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

        # KISS escape and frame for RNode CMD_DATA
        escaped = kiss_escape(data)
        frame = <<@fend, @cmd_data>> <> escaped <> <<@fend>>

        case do_write(state, frame) do
          :ok ->
            state = %{state | txb: state.txb + byte_size(data)}

            # ID beacon tracking
            state =
              if state.id_callsign != nil and data == state.id_callsign do
                %{state | first_tx: nil}
              else
                if state.first_tx == nil do
                  %{state | first_tx: System.system_time(:second)}
                else
                  state
                end
              end

            {:ok, state}

          {:error, reason} ->
            Logger.error("RNode #{state.name} write error: #{inspect(reason)}")
            {:error, reason}
        end
      else
        {:ok, queue_packet(state, data)}
      end
    else
      {:error, :offline}
    end
  end

  @impl RNS.Interfaces.Interface
  def process_incoming(state, data) do
    updated = %{state | rxb: state.rxb + byte_size(data), r_stat_rssi: nil, r_stat_snr: nil}

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
    skip_open = Keyword.get(opts, :skip_open, false)

    # Radio params — validate unless skip_open (testing mode)
    frequency = Keyword.get(opts, :frequency)
    bandwidth = Keyword.get(opts, :bandwidth)
    txpower = Keyword.get(opts, :txpower)
    sf = Keyword.get(opts, :sf)
    cr = Keyword.get(opts, :cr)

    unless skip_open do
      case validate_radio_params(opts) do
        :ok -> :ok
        {:error, reason} -> raise ArgumentError, reason
      end
    end

    serial_port = Keyword.get(opts, :port)
    speed = Keyword.get(opts, :speed, 115_200)
    owner = Keyword.get(opts, :owner)
    flow_control = Keyword.get(opts, :flow_control, false)
    st_alock = Keyword.get(opts, :st_alock)
    lt_alock = Keyword.get(opts, :lt_alock)
    id_interval = Keyword.get(opts, :id_interval)
    id_callsign = Keyword.get(opts, :id_callsign)

    state = %__MODULE__{
      name: name,
      port: serial_port,
      speed: speed,
      frequency: frequency,
      bandwidth: bandwidth,
      txpower: txpower,
      sf: sf,
      cr: cr,
      st_alock: st_alock,
      lt_alock: lt_alock,
      owner: owner,
      in: true,
      out: true,
      online: false,
      hw_mtu: @hw_mtu,
      ifac_size: @default_ifac_size,
      created: System.system_time(:second),
      skip_open: skip_open,
      backend: detect_backend(),
      flow_control: flow_control,
      interface_ready: !flow_control,
      id_interval: id_interval,
      id_callsign: id_callsign
    }

    state = %{state | hash: RNS.Interfaces.Interface.get_hash(state)}

    if skip_open do
      # Set bitrate from desired radio params if available
      state =
        if sf && cr && bandwidth do
          bitrate = calculate_bitrate(sf, cr, bandwidth)
          %{state | bitrate: bitrate}
        else
          state
        end

      {:ok, %{state | online: true, interface_ready: true}}
    else
      if serial_port == nil do
        {:stop, {:error, :no_port_specified}}
      else
        case open_port(state) do
          {:ok, new_state} ->
            Logger.info("RNode serial port #{serial_port} is now open")
            {:ok, %{new_state | online: true, interface_ready: true}}

          {:error, reason} ->
            Logger.error("Could not open RNode serial port #{serial_port}: #{inspect(reason)}")
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
    # Send leave command before closing
    if state.online do
      do_write(state, encode_radio_state(@radio_state_off))
      do_write(state, build_leave_frame())
    end

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
    state = handle_serial_data(state, data)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    if not state.online and not state.detached do
      Logger.info("Attempting to reconnect RNode #{state.name}...")

      case open_port(state) do
        {:ok, new_state} ->
          Logger.info("Reconnected RNode #{state.name}")
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
    Logger.error("RNode #{state.name} serial port closed unexpectedly")
    handle_port_error(state)
  end

  def handle_info({:EXIT, _port, reason}, state) do
    Logger.error("RNode #{state.name} serial port exited: #{inspect(reason)}")
    handle_port_error(state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.online do
      do_write(state, encode_radio_state(@radio_state_off))
      do_write(state, build_leave_frame())
    end

    close_port(state)
    :ok
  end

  # ── should_ingress_limit ─────────────────────────────────────────

  @doc """
  RNode interfaces never limit ingress.
  Matches Python's `should_ingress_limit` returning `False`.
  """
  @spec should_ingress_limit(t()) :: {false, t()}
  def should_ingress_limit(%__MODULE__{} = state), do: {false, state}

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
    try do
      stty_cmd =
        "stty -F #{state.port} #{state.speed} cs#{state.databits} " <>
          "-parenb -cstopb -echo raw"

      case System.cmd("stty", String.split(stty_cmd), stderr_to_stdout: true) do
        {_, 0} -> :ok
        _ -> :ok
      end

      port_ref = Port.open({:spawn, "cat #{state.port}"}, [:binary, :stream, :exit_status])
      {:ok, %{state | port_ref: port_ref}}
    rescue
      e -> {:error, e}
    end
  end

  defp do_write(%{backend: :circuits_uart, uart_pid: pid}, data) when pid != nil do
    Circuits.UART.write(pid, data)
  end

  defp do_write(%{backend: :port, port_ref: ref}, data) when ref != nil do
    try do
      Port.command(ref, data)
      :ok
    rescue
      _ -> {:error, :write_failed}
    end
  end

  defp do_write(%{skip_open: true}, _data), do: :ok

  defp do_write(_, _data), do: {:error, :no_port}

  defp close_port(%{backend: :circuits_uart, uart_pid: pid}) when pid != nil do
    try do
      Circuits.UART.close(pid)
      Circuits.UART.stop(pid)
    rescue
      _ -> :ok
    end
  end

  defp close_port(%{backend: :port, port_ref: ref}) when ref != nil do
    try do
      Port.close(ref)
    rescue
      _ -> :ok
    end
  end

  defp close_port(_), do: :ok

  defp handle_serial_data(state, data) do
    buffer = state.frame_buffer <> data
    {frames, remaining} = deframe(buffer)
    state = %{state | frame_buffer: remaining}

    Enum.reduce(frames, state, fn {cmd, frame_data}, acc ->
      dispatch_frame(acc, cmd, frame_data)
    end)
  end

  defp dispatch_frame(state, @cmd_data, data)
       when byte_size(data) > 0 and byte_size(data) <= @hw_mtu do
    {:ok, updated} = process_incoming(state, data)
    updated
  end

  defp dispatch_frame(state, @cmd_data, _data), do: state

  defp dispatch_frame(state, @cmd_ready, _data) do
    process_queue(state)
  end

  defp dispatch_frame(state, cmd, data) do
    handle_command(state, cmd, data)
  end

  defp update_bitrate(state) do
    if state.r_sf && state.r_cr && state.r_bandwidth do
      bitrate = calculate_bitrate(state.r_sf, state.r_cr, state.r_bandwidth)
      %{state | bitrate: bitrate}
    else
      state
    end
  end

  defp handle_port_error(state) do
    close_port(state)
    updated = %{state | online: false, uart_pid: nil, port_ref: nil}

    if not state.detached do
      Logger.error("RNode #{state.name} is now offline. Will attempt reconnection.")
      schedule_reconnect()
      {:noreply, %{updated | reconnecting: true}}
    else
      {:noreply, updated}
    end
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, @reconnect_wait)
  end

  defp notify_owner(owner, data, interface) when is_pid(owner) do
    send(owner, {:rnode_interface_data, data, interface})
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
      "RNodeInterface[#{name}]"
    end
  end
end
