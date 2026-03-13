defmodule RNS.Interfaces.RNodeInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.RNodeInterface

  # ── Constants ─────────────────────────────────────────────────────

  describe "KISS command constants" do
    test "frame delimiters" do
      assert RNodeInterface.cmd_data() == 0x00
      assert RNodeInterface.cmd_unknown() == 0xFE
    end

    test "radio configuration commands" do
      assert RNodeInterface.cmd_frequency() == 0x01
      assert RNodeInterface.cmd_bandwidth() == 0x02
      assert RNodeInterface.cmd_txpower() == 0x03
      assert RNodeInterface.cmd_sf() == 0x04
      assert RNodeInterface.cmd_cr() == 0x05
      assert RNodeInterface.cmd_radio_state() == 0x06
      assert RNodeInterface.cmd_radio_lock() == 0x07
    end

    test "device management commands" do
      assert RNodeInterface.cmd_detect() == 0x08
      assert RNodeInterface.cmd_leave() == 0x0A
      assert RNodeInterface.cmd_ready() == 0x0F
      assert RNodeInterface.cmd_reset() == 0x55
      assert RNodeInterface.cmd_blink() == 0x30
    end

    test "airtime lock commands" do
      assert RNodeInterface.cmd_st_alock() == 0x0B
      assert RNodeInterface.cmd_lt_alock() == 0x0C
    end

    test "statistics commands" do
      assert RNodeInterface.cmd_stat_rx() == 0x21
      assert RNodeInterface.cmd_stat_tx() == 0x22
      assert RNodeInterface.cmd_stat_rssi() == 0x23
      assert RNodeInterface.cmd_stat_snr() == 0x24
      assert RNodeInterface.cmd_stat_chtm() == 0x25
      assert RNodeInterface.cmd_stat_phyprm() == 0x26
      assert RNodeInterface.cmd_stat_bat() == 0x27
      assert RNodeInterface.cmd_stat_csma() == 0x28
      assert RNodeInterface.cmd_stat_temp() == 0x29
    end

    test "framebuffer and display commands" do
      assert RNodeInterface.cmd_fb_ext() == 0x41
      assert RNodeInterface.cmd_fb_read() == 0x42
      assert RNodeInterface.cmd_fb_write() == 0x43
      assert RNodeInterface.cmd_disp_read() == 0x66
    end

    test "device info commands" do
      assert RNodeInterface.cmd_platform() == 0x48
      assert RNodeInterface.cmd_mcu() == 0x49
      assert RNodeInterface.cmd_fw_version() == 0x50
      assert RNodeInterface.cmd_rom_read() == 0x51
      assert RNodeInterface.cmd_random() == 0x40
      assert RNodeInterface.cmd_bt_ctrl() == 0x46
    end

    test "error command" do
      assert RNodeInterface.cmd_error() == 0x90
    end

    test "detection protocol" do
      assert RNodeInterface.detect_req() == 0x73
      assert RNodeInterface.detect_resp() == 0x46
    end

    test "radio states" do
      assert RNodeInterface.radio_state_off() == 0x00
      assert RNodeInterface.radio_state_on() == 0x01
      assert RNodeInterface.radio_state_ask() == 0xFF
    end

    test "error codes" do
      assert RNodeInterface.error_initradio() == 0x01
      assert RNodeInterface.error_txfailed() == 0x02
      assert RNodeInterface.error_eeprom_locked() == 0x03
      assert RNodeInterface.error_queue_full() == 0x04
      assert RNodeInterface.error_memory_low() == 0x05
      assert RNodeInterface.error_modem_timeout() == 0x06
    end

    test "platform IDs" do
      assert RNodeInterface.platform_avr() == 0x90
      assert RNodeInterface.platform_esp32() == 0x80
      assert RNodeInterface.platform_nrf52() == 0x70
    end

    test "battery states" do
      assert RNodeInterface.battery_state_unknown() == 0x00
      assert RNodeInterface.battery_state_discharging() == 0x01
      assert RNodeInterface.battery_state_charging() == 0x02
      assert RNodeInterface.battery_state_charged() == 0x03
    end
  end

  describe "interface constants" do
    test "MTU and sizes" do
      assert RNodeInterface.max_chunk() == 32_768
      assert RNodeInterface.default_ifac_size() == 8
      assert RNodeInterface.hw_mtu() == 508
    end

    test "radio limits" do
      assert RNodeInterface.freq_min() == 137_000_000
      assert RNodeInterface.freq_max() == 3_000_000_000
      assert RNodeInterface.rssi_offset() == 157
      assert RNodeInterface.callsign_max_len() == 32
    end

    test "firmware requirements" do
      assert RNodeInterface.required_fw_ver_maj() == 1
      assert RNodeInterface.required_fw_ver_min() == 52
    end

    test "signal quality constants" do
      assert RNodeInterface.q_snr_min_base() == -9
      assert RNodeInterface.q_snr_max() == 6
      assert RNodeInterface.q_snr_step() == 2
    end

    test "framebuffer constants" do
      assert RNodeInterface.fb_bytes_per_line() == 8
    end
  end

  # ── Struct ────────────────────────────────────────────────────────

  describe "struct" do
    test "has default fields from Interface" do
      s = %RNodeInterface{}
      assert s.name == nil
      assert s.rxb == 0
      assert s.txb == 0
      assert s.online == false
      assert s.created == nil
    end

    test "has RNode-specific fields with defaults" do
      s = %RNodeInterface{}
      assert s.frequency == nil
      assert s.bandwidth == nil
      assert s.txpower == nil
      assert s.sf == nil
      assert s.cr == nil
      assert s.speed == 115_200
      assert s.detected == false
      assert s.firmware_ok == false
      assert s.platform == nil
      assert s.r_battery_state == 0x00
      assert s.r_battery_percent == 0
      assert s.r_airtime_short == 0.0
      assert s.r_airtime_long == 0.0
      assert s.hw_errors == []
      assert s.flow_control == false
      assert s.interface_ready == true
    end
  end

  # ── KISS escape/unescape ──────────────────────────────────────────

  describe "kiss_escape/1" do
    test "does not modify data without special bytes" do
      assert RNodeInterface.kiss_escape(<<1, 2, 3>>) == <<1, 2, 3>>
    end

    test "escapes FESC (0xDB) to FESC+TFESC" do
      assert RNodeInterface.kiss_escape(<<0xDB>>) == <<0xDB, 0xDD>>
    end

    test "escapes FEND (0xC0) to FESC+TFEND" do
      assert RNodeInterface.kiss_escape(<<0xC0>>) == <<0xDB, 0xDC>>
    end

    test "escapes both special bytes in correct order" do
      # DB first, then C0 — order matters to prevent double-escape
      input = <<0xDB, 0xC0>>
      assert RNodeInterface.kiss_escape(input) == <<0xDB, 0xDD, 0xDB, 0xDC>>
    end

    test "handles data containing both special and normal bytes" do
      input = <<0x01, 0xC0, 0x02, 0xDB, 0x03>>
      expected = <<0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03>>
      assert RNodeInterface.kiss_escape(input) == expected
    end
  end

  describe "kiss_unescape/1" do
    test "does not modify data without escape sequences" do
      assert RNodeInterface.kiss_unescape(<<1, 2, 3>>) == <<1, 2, 3>>
    end

    test "unescapes FESC+TFEND to FEND" do
      assert RNodeInterface.kiss_unescape(<<0xDB, 0xDC>>) == <<0xC0>>
    end

    test "unescapes FESC+TFESC to FESC" do
      assert RNodeInterface.kiss_unescape(<<0xDB, 0xDD>>) == <<0xDB>>
    end

    test "roundtrip with escape" do
      original = <<0xC0, 0xDB, 0x01, 0xC0, 0xDB>>
      assert original == original |> RNodeInterface.kiss_escape() |> RNodeInterface.kiss_unescape()
    end
  end

  # ── Radio parameter validation ───────────────────────────────────

  describe "validate_radio_params/1" do
    @valid_opts [
      frequency: 868_000_000,
      bandwidth: 125_000,
      txpower: 17,
      sf: 7,
      cr: 5
    ]

    test "accepts valid parameters" do
      assert :ok = RNodeInterface.validate_radio_params(@valid_opts)
    end

    test "rejects missing frequency" do
      opts = Keyword.delete(@valid_opts, :frequency)
      assert {:error, "frequency is required"} = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects frequency below minimum" do
      opts = Keyword.put(@valid_opts, :frequency, 100_000_000)
      assert {:error, msg} = RNodeInterface.validate_radio_params(opts)
      assert msg =~ "out of range"
    end

    test "rejects frequency above maximum" do
      opts = Keyword.put(@valid_opts, :frequency, 4_000_000_000)
      assert {:error, msg} = RNodeInterface.validate_radio_params(opts)
      assert msg =~ "out of range"
    end

    test "accepts minimum valid frequency" do
      opts = Keyword.put(@valid_opts, :frequency, 137_000_000)
      assert :ok = RNodeInterface.validate_radio_params(opts)
    end

    test "accepts maximum valid frequency" do
      opts = Keyword.put(@valid_opts, :frequency, 3_000_000_000)
      assert :ok = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects missing bandwidth" do
      opts = Keyword.delete(@valid_opts, :bandwidth)
      assert {:error, "bandwidth is required"} = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects bandwidth below minimum" do
      opts = Keyword.put(@valid_opts, :bandwidth, 1_000)
      assert {:error, msg} = RNodeInterface.validate_radio_params(opts)
      assert msg =~ "out of range"
    end

    test "rejects bandwidth above maximum" do
      opts = Keyword.put(@valid_opts, :bandwidth, 2_000_000)
      assert {:error, msg} = RNodeInterface.validate_radio_params(opts)
      assert msg =~ "out of range"
    end

    test "rejects missing txpower" do
      opts = Keyword.delete(@valid_opts, :txpower)
      assert {:error, "txpower is required"} = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects txpower out of range" do
      opts = Keyword.put(@valid_opts, :txpower, 40)
      assert {:error, msg} = RNodeInterface.validate_radio_params(opts)
      assert msg =~ "out of range"
    end

    test "rejects missing spreading factor" do
      opts = Keyword.delete(@valid_opts, :sf)
      assert {:error, "spreading factor is required"} = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects SF out of range" do
      assert {:error, _} = RNodeInterface.validate_radio_params(Keyword.put(@valid_opts, :sf, 4))
      assert {:error, _} = RNodeInterface.validate_radio_params(Keyword.put(@valid_opts, :sf, 13))
    end

    test "rejects missing coding rate" do
      opts = Keyword.delete(@valid_opts, :cr)
      assert {:error, "coding rate is required"} = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects CR out of range" do
      assert {:error, _} = RNodeInterface.validate_radio_params(Keyword.put(@valid_opts, :cr, 4))
      assert {:error, _} = RNodeInterface.validate_radio_params(Keyword.put(@valid_opts, :cr, 9))
    end

    test "accepts valid airtime locks" do
      opts = @valid_opts ++ [st_alock: 50.0, lt_alock: 25.0]
      assert :ok = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects airtime lock out of range" do
      opts = @valid_opts ++ [st_alock: -1.0]
      assert {:error, _} = RNodeInterface.validate_radio_params(opts)

      opts = @valid_opts ++ [lt_alock: 101.0]
      assert {:error, _} = RNodeInterface.validate_radio_params(opts)
    end

    test "accepts valid callsign" do
      opts = @valid_opts ++ [id_callsign: "N0CALL"]
      assert :ok = RNodeInterface.validate_radio_params(opts)
    end

    test "rejects callsign exceeding max length" do
      long = String.duplicate("A", 33)
      opts = @valid_opts ++ [id_callsign: long]
      assert {:error, msg} = RNodeInterface.validate_radio_params(opts)
      assert msg =~ "exceeds"
    end
  end

  # ── Command encoding ─────────────────────────────────────────────

  describe "encode_frequency/1" do
    test "encodes 868 MHz as 4-byte big-endian" do
      frame = RNodeInterface.encode_frequency(868_000_000)
      # FEND + CMD_FREQUENCY + escaped(<<868_000_000::32>>) + FEND
      assert <<0xC0, 0x01, _rest::binary>> = frame
      assert :binary.last(frame) == 0xC0
    end

    test "roundtrip with deframe" do
      frame = RNodeInterface.encode_frequency(868_000_000)
      {[{cmd, data}], <<>>} = RNodeInterface.deframe(frame)
      assert cmd == 0x01
      <<freq::unsigned-big-32>> = data
      assert freq == 868_000_000
    end
  end

  describe "encode_bandwidth/1" do
    test "encodes 125 kHz correctly" do
      frame = RNodeInterface.encode_bandwidth(125_000)
      {[{cmd, data}], <<>>} = RNodeInterface.deframe(frame)
      assert cmd == 0x02
      <<bw::unsigned-big-32>> = data
      assert bw == 125_000
    end
  end

  describe "encode_txpower/1" do
    test "encodes single byte" do
      frame = RNodeInterface.encode_txpower(17)
      assert frame == <<0xC0, 0x03, 17, 0xC0>>
    end
  end

  describe "encode_sf/1" do
    test "encodes single byte" do
      frame = RNodeInterface.encode_sf(7)
      assert frame == <<0xC0, 0x04, 7, 0xC0>>
    end
  end

  describe "encode_cr/1" do
    test "encodes single byte" do
      frame = RNodeInterface.encode_cr(5)
      assert frame == <<0xC0, 0x05, 5, 0xC0>>
    end
  end

  describe "encode_radio_state/1" do
    test "encodes radio on" do
      frame = RNodeInterface.encode_radio_state(0x01)
      assert frame == <<0xC0, 0x06, 0x01, 0xC0>>
    end
  end

  describe "encode_st_alock/1" do
    test "encodes 50.5% as uint16 * 100" do
      frame = RNodeInterface.encode_st_alock(50.5)
      {[{cmd, data}], <<>>} = RNodeInterface.deframe(frame)
      assert cmd == 0x0B
      <<value::unsigned-big-16>> = data
      assert value == 5050
    end
  end

  describe "encode_lt_alock/1" do
    test "encodes 25.0% as uint16 * 100" do
      frame = RNodeInterface.encode_lt_alock(25.0)
      {[{cmd, data}], <<>>} = RNodeInterface.deframe(frame)
      assert cmd == 0x0C
      <<value::unsigned-big-16>> = data
      assert value == 2500
    end
  end

  describe "build_detect_frame/0" do
    test "builds correct multi-command frame" do
      frame = RNodeInterface.build_detect_frame()
      assert <<0xC0, 0x08, 0x73, 0xC0, _rest::binary>> = frame
    end
  end

  describe "build_leave_frame/0" do
    test "builds correct leave frame" do
      assert RNodeInterface.build_leave_frame() == <<0xC0, 0x0A, 0xFF, 0xC0>>
    end
  end

  # ── Bitrate calculation ──────────────────────────────────────────

  describe "calculate_bitrate/3" do
    test "calculates LoRa bitrate for SF7 CR5 125kHz" do
      bitrate = RNodeInterface.calculate_bitrate(7, 5, 125_000)
      assert is_float(bitrate)
      assert bitrate > 0
    end

    test "lower SF yields higher bitrate" do
      bw = 125_000
      cr = 5
      low_sf = RNodeInterface.calculate_bitrate(7, cr, bw)
      high_sf = RNodeInterface.calculate_bitrate(12, cr, bw)
      assert low_sf > high_sf
    end

    test "higher bandwidth yields higher bitrate" do
      sf = 7
      cr = 5
      narrow = RNodeInterface.calculate_bitrate(sf, cr, 62_500)
      wide = RNodeInterface.calculate_bitrate(sf, cr, 250_000)
      assert wide > narrow
    end

    test "returns 0 for invalid params" do
      assert RNodeInterface.calculate_bitrate(0, 5, 125_000) == 0.0
      assert RNodeInterface.calculate_bitrate(7, 0, 125_000) == 0.0
      assert RNodeInterface.calculate_bitrate(7, 5, 0) == 0.0
    end
  end

  # ── Signal quality calculation ───────────────────────────────────

  describe "calculate_quality/2" do
    test "high SNR gives 100%" do
      assert RNodeInterface.calculate_quality(10.0, 7) == 100.0
    end

    test "low SNR gives 0%" do
      assert RNodeInterface.calculate_quality(-20.0, 7) == 0.0
    end

    test "mid-range SNR gives intermediate value" do
      quality = RNodeInterface.calculate_quality(0.0, 7)
      assert quality > 0.0
      assert quality < 100.0
    end

    test "higher SF shifts minimum SNR lower" do
      # SF12 has a more negative q_snr_min, so same SNR yields better quality
      q7 = RNodeInterface.calculate_quality(-5.0, 7)
      q12 = RNodeInterface.calculate_quality(-5.0, 12)
      assert q12 > q7
    end
  end

  # ── Firmware validation ──────────────────────────────────────────

  describe "validate_firmware/2" do
    test "accepts version above required major" do
      assert RNodeInterface.validate_firmware(2, 0) == true
    end

    test "accepts matching major and sufficient minor" do
      assert RNodeInterface.validate_firmware(1, 52) == true
      assert RNodeInterface.validate_firmware(1, 99) == true
    end

    test "rejects insufficient minor with matching major" do
      assert RNodeInterface.validate_firmware(1, 51) == false
      assert RNodeInterface.validate_firmware(1, 0) == false
    end

    test "rejects lower major version" do
      assert RNodeInterface.validate_firmware(0, 99) == false
    end
  end

  # ── KISS deframe (RNode-specific, no nibble stripping) ───────────

  describe "deframe/1" do
    test "extracts a simple frame" do
      frame = <<0xC0, 0x01, 0xAA, 0xBB, 0xC0>>
      {[{cmd, data}], <<>>} = RNodeInterface.deframe(frame)
      assert cmd == 0x01
      assert data == <<0xAA, 0xBB>>
    end

    test "preserves full command byte (no nibble stripping)" do
      # Standard KISS would strip 0x21 to 0x01, RNode keeps 0x21
      frame = <<0xC0, 0x21, 0xAA, 0xC0>>
      {[{cmd, _data}], <<>>} = RNodeInterface.deframe(frame)
      assert cmd == 0x21
    end

    test "handles KISS escape sequences" do
      # Data contains escaped FEND (0xC0)
      frame = <<0xC0, 0x00, 0xDB, 0xDC, 0xC0>>
      {[{0x00, data}], <<>>} = RNodeInterface.deframe(frame)
      assert data == <<0xC0>>
    end

    test "extracts multiple frames" do
      frames = <<0xC0, 0x01, 0xAA, 0xC0, 0xC0, 0x02, 0xBB, 0xC0>>
      {result, <<>>} = RNodeInterface.deframe(frames)
      assert length(result) == 2
      assert {0x01, <<0xAA>>} = Enum.at(result, 0)
      assert {0x02, <<0xBB>>} = Enum.at(result, 1)
    end

    test "returns partial frames as remaining buffer" do
      partial = <<0xC0, 0x01, 0xAA>>
      {[], remaining} = RNodeInterface.deframe(partial)
      assert remaining != <<>>
    end

    test "handles empty buffer" do
      {[], <<>>} = RNodeInterface.deframe(<<>>)
    end

    test "handles fragmented delivery" do
      # Split a frame across two deliveries
      full = <<0xC0, 0x01, 0xAA, 0xBB, 0xCC, 0xC0>>
      first_half = binary_part(full, 0, 3)
      second_half = binary_part(full, 3, byte_size(full) - 3)

      {[], remaining} = RNodeInterface.deframe(first_half)
      {[{0x01, data}], <<>>} = RNodeInterface.deframe(remaining <> second_half)
      assert data == <<0xAA, 0xBB, 0xCC>>
    end
  end

  # ── Command response parsing ─────────────────────────────────────

  describe "handle_command/3" do
    setup do
      state = %RNodeInterface{name: "test"}
      {:ok, state: state}
    end

    test "CMD_DETECT with valid response", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x08, <<0x46>>)
      assert result.detected == true
    end

    test "CMD_DETECT with invalid response", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x08, <<0x00>>)
      assert result.detected == false
    end

    test "CMD_FW_VERSION with valid firmware", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x50, <<1, 52>>)
      assert result.maj_version == 1
      assert result.min_version == 52
      assert result.firmware_ok == true
    end

    test "CMD_FW_VERSION with invalid firmware", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x50, <<1, 10>>)
      assert result.maj_version == 1
      assert result.min_version == 10
      assert result.firmware_ok == false
    end

    test "CMD_PLATFORM", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x48, <<0x80>>)
      assert result.platform == 0x80
    end

    test "CMD_MCU", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x49, <<0x42>>)
      assert result.mcu == 0x42
    end

    test "CMD_FREQUENCY", %{state: state} do
      # 868_000_000 = 0x33BCA100
      result = RNodeInterface.handle_command(state, 0x01, <<0x33, 0xBC, 0xA1, 0x00>>)
      assert result.r_frequency == 868_000_000
    end

    test "CMD_BANDWIDTH", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x02, <<0x00, 0x01, 0xE8, 0x48>>)
      assert result.r_bandwidth == 125_000
    end

    test "CMD_TXPOWER", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x03, <<17>>)
      assert result.r_txpower == 17
    end

    test "CMD_SF", %{state: state} do
      state = %{state | r_cr: 5, r_bandwidth: 125_000}
      result = RNodeInterface.handle_command(state, 0x04, <<7>>)
      assert result.r_sf == 7
      assert result.bitrate > 0
    end

    test "CMD_CR", %{state: state} do
      state = %{state | r_sf: 7, r_bandwidth: 125_000}
      result = RNodeInterface.handle_command(state, 0x05, <<5>>)
      assert result.r_cr == 5
      assert result.bitrate > 0
    end

    test "CMD_RADIO_STATE", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x06, <<0x01>>)
      assert result.r_state == 0x01
    end

    test "CMD_RADIO_LOCK", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x07, <<0x01>>)
      assert result.r_lock == 0x01
    end

    test "CMD_STAT_RX", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x21, <<0x00, 0x00, 0x01, 0x00>>)
      assert result.r_stat_rx == 256
    end

    test "CMD_STAT_TX", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x22, <<0x00, 0x00, 0x00, 0x0A>>)
      assert result.r_stat_tx == 10
    end

    test "CMD_STAT_RSSI", %{state: state} do
      # byte=100, RSSI = 100 - 157 = -57
      result = RNodeInterface.handle_command(state, 0x23, <<100>>)
      assert result.r_stat_rssi == -57
    end

    test "CMD_STAT_SNR positive", %{state: state} do
      state = %{state | r_sf: 7}
      # byte=40, signed=40, snr = 40 * 0.25 = 10.0
      result = RNodeInterface.handle_command(state, 0x24, <<40>>)
      assert result.r_stat_snr == 10.0
      assert result.r_stat_q == 100.0
    end

    test "CMD_STAT_SNR negative", %{state: state} do
      state = %{state | r_sf: 7}
      # byte=240 (> 127), signed = 240 - 256 = -16, snr = -16 * 0.25 = -4.0
      result = RNodeInterface.handle_command(state, 0x24, <<240>>)
      assert result.r_stat_snr == -4.0
      assert result.r_stat_q >= 0.0
      assert result.r_stat_q <= 100.0
    end

    test "CMD_ST_ALOCK", %{state: state} do
      # 5050 / 100.0 = 50.5
      result = RNodeInterface.handle_command(state, 0x0B, <<0x13, 0xBA>>)
      assert_in_delta result.r_st_alock, 50.5, 0.01
    end

    test "CMD_LT_ALOCK", %{state: state} do
      # 2500 / 100.0 = 25.0
      result = RNodeInterface.handle_command(state, 0x0C, <<0x09, 0xC4>>)
      assert result.r_lt_alock == 25.0
    end

    test "CMD_STAT_CHTM", %{state: state} do
      # 11 bytes: as=100(1.0), al=200(2.0), cls=50(0.5), cll=75(0.75),
      # rssi=200(-157+200=43), nf=50(-157+50=-107), interference=100(-157+100=-57)
      data =
        <<0x00, 100, 0x00, 200, 0x00, 50, 0x00, 75, 200, 50, 100>>

      result = RNodeInterface.handle_command(state, 0x25, data)
      assert_in_delta result.r_airtime_short, 1.0, 0.01
      assert_in_delta result.r_airtime_long, 2.0, 0.01
      assert_in_delta result.r_channel_load_short, 0.5, 0.01
      assert_in_delta result.r_channel_load_long, 0.75, 0.01
      assert result.r_current_rssi == 200 - 157
      assert result.r_noise_floor == 50 - 157
      assert result.r_interference == 100 - 157
    end

    test "CMD_STAT_CHTM with no interference (0xFF)", %{state: state} do
      data = <<0x00, 100, 0x00, 200, 0x00, 50, 0x00, 75, 200, 50, 0xFF>>
      result = RNodeInterface.handle_command(state, 0x25, data)
      assert result.r_interference == nil
    end

    test "CMD_STAT_PHYPRM", %{state: state} do
      # 12 bytes: 6 uint16 values
      data =
        <<0x00, 10, 0x00, 20, 0x00, 30, 0x00, 40, 0x00, 50, 0x00, 60>>

      result = RNodeInterface.handle_command(state, 0x26, data)
      assert_in_delta result.r_symbol_time_ms, 10 / 1000.0, 0.001
      assert result.r_symbol_rate == 20
      assert result.r_preamble_symbols == 30
      assert result.r_preamble_time_ms == 40
      assert result.r_csma_slot_time_ms == 50
      assert result.r_csma_difs_ms == 60
    end

    test "CMD_STAT_CSMA", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x28, <<10, 20, 30>>)
      assert result.r_csma_cw_band == 10
      assert result.r_csma_cw_min == 20
      assert result.r_csma_cw_max == 30
    end

    test "CMD_STAT_BAT", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x27, <<0x02, 85>>)
      assert result.r_battery_state == 0x02
      assert result.r_battery_percent == 85
    end

    test "CMD_STAT_BAT clamps percent to 0-100", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x27, <<0x01, 200>>)
      assert result.r_battery_percent == 100
    end

    test "CMD_STAT_TEMP valid", %{state: state} do
      # byte=140, temp = 140 - 120 = 20°C
      result = RNodeInterface.handle_command(state, 0x29, <<140>>)
      assert result.r_temperature == 20
      assert result.cpu_temp == 20
    end

    test "CMD_STAT_TEMP out of range", %{state: state} do
      # byte=10, temp = 10 - 120 = -110 (< -30, out of range)
      result = RNodeInterface.handle_command(state, 0x29, <<10>>)
      assert result.r_temperature == nil
      assert result.cpu_temp == nil
    end

    test "CMD_RANDOM", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x40, <<42>>)
      assert result.r_random == 42
    end

    test "CMD_ERROR records hardware error", %{state: state} do
      result = RNodeInterface.handle_command(state, 0x90, <<0x05>>)
      assert length(result.hw_errors) == 1
      assert hd(result.hw_errors).code == 0x05
    end

    test "CMD_ERROR accumulates errors", %{state: state} do
      state = RNodeInterface.handle_command(state, 0x90, <<0x05>>)
      state = RNodeInterface.handle_command(state, 0x90, <<0x06>>)
      assert length(state.hw_errors) == 2
    end

    test "unrecognized command returns state unchanged", %{state: state} do
      result = RNodeInterface.handle_command(state, 0xFF, <<0x01>>)
      assert result == state
    end
  end

  # ── Radio state validation ───────────────────────────────────────

  describe "validate_radio_state/1" do
    test "returns true when all params match" do
      state = %RNodeInterface{
        frequency: 868_000_000,
        bandwidth: 125_000,
        txpower: 17,
        sf: 7,
        r_frequency: 868_000_050,
        r_bandwidth: 125_000,
        r_txpower: 17,
        r_sf: 7,
        r_state: 0x01
      }

      assert RNodeInterface.validate_radio_state(state) == true
    end

    test "returns true with frequency within 100 Hz tolerance" do
      state = %RNodeInterface{
        frequency: 868_000_000,
        bandwidth: 125_000,
        txpower: 17,
        sf: 7,
        r_frequency: 868_000_100,
        r_bandwidth: 125_000,
        r_txpower: 17,
        r_sf: 7,
        r_state: 0x01
      }

      assert RNodeInterface.validate_radio_state(state) == true
    end

    test "returns false when frequency differs by more than 100 Hz" do
      state = %RNodeInterface{
        frequency: 868_000_000,
        bandwidth: 125_000,
        txpower: 17,
        sf: 7,
        r_frequency: 868_000_200,
        r_bandwidth: 125_000,
        r_txpower: 17,
        r_sf: 7,
        r_state: 0x01
      }

      assert RNodeInterface.validate_radio_state(state) == false
    end

    test "returns false when radio is off" do
      state = %RNodeInterface{
        frequency: 868_000_000,
        bandwidth: 125_000,
        txpower: 17,
        sf: 7,
        r_frequency: 868_000_000,
        r_bandwidth: 125_000,
        r_txpower: 17,
        r_sf: 7,
        r_state: 0x00
      }

      assert RNodeInterface.validate_radio_state(state) == false
    end

    test "returns false when reported params are nil" do
      state = %RNodeInterface{
        frequency: 868_000_000,
        bandwidth: 125_000,
        txpower: 17,
        sf: 7
      }

      assert RNodeInterface.validate_radio_state(state) == false
    end
  end

  # ── Reset radio state ────────────────────────────────────────────

  describe "reset_radio_state/1" do
    test "clears all reported fields" do
      state = %RNodeInterface{
        r_frequency: 868_000_000,
        r_bandwidth: 125_000,
        r_txpower: 17,
        r_sf: 7,
        r_cr: 5,
        r_state: 1,
        r_lock: 1,
        r_stat_rx: 100,
        r_stat_tx: 50,
        r_stat_rssi: -80,
        r_stat_snr: 5.0,
        r_stat_q: 80.0,
        detected: true
      }

      result = RNodeInterface.reset_radio_state(state)
      assert result.r_frequency == nil
      assert result.r_bandwidth == nil
      assert result.r_txpower == nil
      assert result.r_sf == nil
      assert result.r_cr == nil
      assert result.r_state == nil
      assert result.r_lock == nil
      assert result.r_stat_rx == nil
      assert result.r_stat_tx == nil
      assert result.r_stat_rssi == nil
      assert result.r_stat_snr == nil
      assert result.r_stat_q == nil
      assert result.detected == false
    end
  end

  # ── Battery helpers ──────────────────────────────────────────────

  describe "battery helpers" do
    test "get_battery_state/1" do
      state = %RNodeInterface{r_battery_state: 0x02}
      assert RNodeInterface.get_battery_state(state) == 0x02
    end

    test "get_battery_state_string/1" do
      assert RNodeInterface.get_battery_state_string(%RNodeInterface{r_battery_state: 0x01}) == "discharging"
      assert RNodeInterface.get_battery_state_string(%RNodeInterface{r_battery_state: 0x02}) == "charging"
      assert RNodeInterface.get_battery_state_string(%RNodeInterface{r_battery_state: 0x03}) == "charged"
      assert RNodeInterface.get_battery_state_string(%RNodeInterface{r_battery_state: 0x00}) == "unknown"
    end

    test "get_battery_percent/1" do
      assert RNodeInterface.get_battery_percent(%RNodeInterface{r_battery_percent: 85}) == 85
    end
  end

  # ── GenServer start_link ─────────────────────────────────────────

  describe "start_link/1 with skip_open" do
    test "starts successfully with skip_open" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          skip_open: true
        )

      state = RNodeInterface.get_state(pid)
      assert state.name == "test_rnode"
      assert state.online == true
      assert state.interface_ready == true
      assert state.skip_open == true
      GenServer.stop(pid)
    end

    test "sets radio parameters" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 5,
          skip_open: true
        )

      state = RNodeInterface.get_state(pid)
      assert state.frequency == 868_000_000
      assert state.bandwidth == 125_000
      assert state.txpower == 17
      assert state.sf == 7
      assert state.cr == 5
      assert state.bitrate > 0
      GenServer.stop(pid)
    end

    test "sets flow control" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          flow_control: true,
          skip_open: true
        )

      state = RNodeInterface.get_state(pid)
      # skip_open forces interface_ready: true
      assert state.flow_control == true
      assert state.interface_ready == true
      GenServer.stop(pid)
    end

    test "sets airtime locks" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          st_alock: 50.0,
          lt_alock: 25.0,
          skip_open: true
        )

      state = RNodeInterface.get_state(pid)
      assert state.st_alock == 50.0
      assert state.lt_alock == 25.0
      GenServer.stop(pid)
    end

    test "sets ID beacon config" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          id_interval: 600,
          id_callsign: "N0CALL",
          skip_open: true
        )

      state = RNodeInterface.get_state(pid)
      assert state.id_interval == 600
      assert state.id_callsign == "N0CALL"
      GenServer.stop(pid)
    end

    test "computes hash" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          skip_open: true
        )

      state = RNodeInterface.get_state(pid)
      assert is_binary(state.hash) and byte_size(state.hash) == 32
      GenServer.stop(pid)
    end

    test "sets owner" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          owner: self(),
          skip_open: true
        )

      state = RNodeInterface.get_state(pid)
      assert state.owner == self()
      GenServer.stop(pid)
    end

    test "fails without port when skip_open is false" do
      Process.flag(:trap_exit, true)

      result =
        RNodeInterface.start_link(
          name: "test_rnode",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 5
        )

      assert {:error, {:error, :no_port_specified}} = result
    end

    test "registers with server_name" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          server_name: :test_rnode_server,
          skip_open: true
        )

      assert Process.whereis(:test_rnode_server) == pid
      GenServer.stop(pid)
    end
  end

  # ── KISS framing roundtrip via GenServer ─────────────────────────

  describe "KISS framing roundtrip" do
    setup do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          owner: self(),
          skip_open: true
        )

      on_exit(fn -> catch_exit(GenServer.stop(pid)) end)
      {:ok, pid: pid}
    end

    test "simple data", %{pid: pid} do
      original = <<1, 2, 3, 4, 5>>
      escaped = RNodeInterface.kiss_escape(original)
      frame = <<0xC0, 0x00>> <> escaped <> <<0xC0>>
      send(pid, {:serial_data, frame})
      assert_receive {:rnode_interface_data, ^original, _iface}, 1000
    end

    test "data with special KISS bytes", %{pid: pid} do
      original = <<0xC0, 0xDB, 0x42>>
      escaped = RNodeInterface.kiss_escape(original)
      frame = <<0xC0, 0x00>> <> escaped <> <<0xC0>>
      send(pid, {:serial_data, frame})
      assert_receive {:rnode_interface_data, ^original, _iface}, 1000
    end

    test "multiple frames", %{pid: pid} do
      data1 = <<0xAA>>
      data2 = <<0xBB>>
      frame1 = <<0xC0, 0x00>> <> RNodeInterface.kiss_escape(data1) <> <<0xC0>>
      frame2 = <<0xC0, 0x00>> <> RNodeInterface.kiss_escape(data2) <> <<0xC0>>
      send(pid, {:serial_data, frame1 <> frame2})
      assert_receive {:rnode_interface_data, ^data1, _}, 1000
      assert_receive {:rnode_interface_data, ^data2, _}, 1000
    end

    test "fragmented delivery", %{pid: pid} do
      original = <<1, 2, 3, 4, 5>>
      escaped = RNodeInterface.kiss_escape(original)
      frame = <<0xC0, 0x00>> <> escaped <> <<0xC0>>

      first_half = binary_part(frame, 0, 3)
      second_half = binary_part(frame, 3, byte_size(frame) - 3)

      send(pid, {:serial_data, first_half})
      refute_receive {:rnode_interface_data, _, _}, 100
      send(pid, {:serial_data, second_half})
      assert_receive {:rnode_interface_data, ^original, _}, 1000
    end

    test "oversized frames are dropped", %{pid: pid} do
      data = :crypto.strong_rand_bytes(600)
      escaped = RNodeInterface.kiss_escape(data)
      frame = <<0xC0, 0x00>> <> escaped <> <<0xC0>>
      send(pid, {:serial_data, frame})
      refute_receive {:rnode_interface_data, _, _}, 200
    end

    test "empty data frames are dropped", %{pid: pid} do
      frame = <<0xC0, 0x00, 0xC0>>
      send(pid, {:serial_data, frame})
      refute_receive {:rnode_interface_data, _, _}, 200
    end

    test "command responses update state via serial data", %{pid: pid} do
      # Send a detect response frame
      frame = <<0xC0, 0x08, 0x46, 0xC0>>
      send(pid, {:serial_data, frame})
      :timer.sleep(50)
      state = RNodeInterface.get_state(pid)
      assert state.detected == true
    end

    test "firmware version response", %{pid: pid} do
      frame = <<0xC0, 0x50, 1, 55, 0xC0>>
      send(pid, {:serial_data, frame})
      :timer.sleep(50)
      state = RNodeInterface.get_state(pid)
      assert state.maj_version == 1
      assert state.min_version == 55
      assert state.firmware_ok == true
    end

    test "RSSI and SNR cleared after process_incoming", %{pid: pid} do
      # First set RSSI/SNR
      rssi_frame = <<0xC0, 0x23, 100, 0xC0>>
      snr_frame = <<0xC0, 0x24, 40, 0xC0>>
      send(pid, {:serial_data, rssi_frame <> snr_frame})
      :timer.sleep(50)

      state = RNodeInterface.get_state(pid)
      assert state.r_stat_rssi == -57
      assert state.r_stat_snr == 10.0

      # Now receive data — RSSI/SNR should be cleared
      data_frame = <<0xC0, 0x00, 0x42, 0xC0>>
      send(pid, {:serial_data, data_frame})
      assert_receive {:rnode_interface_data, <<0x42>>, _}, 1000

      state = RNodeInterface.get_state(pid)
      assert state.r_stat_rssi == nil
      assert state.r_stat_snr == nil
    end
  end

  # ── process_outgoing ─────────────────────────────────────────────

  describe "process_outgoing/2" do
    test "returns error when offline" do
      state = %RNodeInterface{name: "test", online: false}
      assert {:error, :offline} = RNodeInterface.process_outgoing(state, <<1, 2, 3>>)
    end

    test "increments txb on success" do
      state = %RNodeInterface{name: "test", online: true, interface_ready: true, skip_open: true}
      {:ok, updated} = RNodeInterface.process_outgoing(state, <<1, 2, 3>>)
      assert updated.txb == 3
    end

    test "queues when flow control active and not ready" do
      state = %RNodeInterface{
        name: "test",
        online: true,
        interface_ready: false,
        flow_control: true,
        skip_open: true
      }

      {:ok, updated} = RNodeInterface.process_outgoing(state, <<1, 2, 3>>)
      assert :queue.len(updated.packet_queue) == 1
    end
  end

  # ── Flow control ─────────────────────────────────────────────────

  describe "flow control" do
    setup do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          owner: self(),
          flow_control: true,
          skip_open: true
        )

      on_exit(fn -> catch_exit(GenServer.stop(pid)) end)
      {:ok, pid: pid}
    end

    test "CMD_READY dequeues packets", %{pid: pid} do
      # Send first packet — goes through
      :ok = RNodeInterface.send_data(pid, <<0xAA>>)

      # Second packet should be queued
      state = RNodeInterface.get_state(pid)
      assert state.interface_ready == false

      # Enqueue another
      :ok = RNodeInterface.send_data(pid, <<0xBB>>)
      state = RNodeInterface.get_state(pid)
      assert :queue.len(state.packet_queue) == 1

      # Send CMD_READY
      ready_frame = <<0xC0, 0x0F, 0x01, 0xC0>>
      send(pid, {:serial_data, ready_frame})
      :timer.sleep(50)

      state = RNodeInterface.get_state(pid)
      # Queue should be empty now (packet was dequeued and sent)
      assert :queue.len(state.packet_queue) == 0
    end
  end

  # ── Byte counters ────────────────────────────────────────────────

  describe "byte counters" do
    test "rxb accumulates across multiple receives" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          owner: self(),
          skip_open: true
        )

      data1 = <<1, 2, 3>>
      data2 = <<4, 5>>
      frame1 = <<0xC0, 0x00>> <> RNodeInterface.kiss_escape(data1) <> <<0xC0>>
      frame2 = <<0xC0, 0x00>> <> RNodeInterface.kiss_escape(data2) <> <<0xC0>>

      send(pid, {:serial_data, frame1})
      assert_receive {:rnode_interface_data, _, _}, 1000
      send(pid, {:serial_data, frame2})
      assert_receive {:rnode_interface_data, _, _}, 1000

      state = RNodeInterface.get_state(pid)
      assert state.rxb == 5
      GenServer.stop(pid)
    end
  end

  # ── Detach ───────────────────────────────────────────────────────

  describe "detach" do
    test "sets offline and detached" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          skip_open: true
        )

      :ok = RNodeInterface.stop(pid)
    end
  end

  # ── should_ingress_limit ─────────────────────────────────────────

  describe "should_ingress_limit/1" do
    test "always returns false" do
      state = %RNodeInterface{name: "test"}
      assert {false, ^state} = RNodeInterface.should_ingress_limit(state)
    end
  end

  # ── String.Chars ─────────────────────────────────────────────────

  describe "String.Chars" do
    test "formats as RNodeInterface[name]" do
      state = %RNodeInterface{name: "LoRa_868"}
      assert to_string(state) == "RNodeInterface[LoRa_868]"
    end

    test "handles nil name" do
      state = %RNodeInterface{}
      assert to_string(state) == "RNodeInterface[]"
    end
  end

  # ── Interface behaviour ──────────────────────────────────────────

  describe "Interface behaviour" do
    test "process_incoming with pid owner" do
      state = %RNodeInterface{name: "test", owner: self()}
      {:ok, updated} = RNodeInterface.process_incoming(state, <<1, 2, 3>>)
      assert updated.rxb == 3
      assert_receive {:rnode_interface_data, <<1, 2, 3>>, _}
    end

    test "process_incoming with function owner" do
      test_pid = self()
      fun = fn data, _iface -> send(test_pid, {:fun_called, data}) end
      state = %RNodeInterface{name: "test", owner: fun}
      {:ok, _} = RNodeInterface.process_incoming(state, <<1, 2, 3>>)
      assert_receive {:fun_called, <<1, 2, 3>>}
    end

    test "process_incoming with MFA owner" do
      defmodule TestCallback do
        def handle(data, _iface) do
          send(Process.get(:test_pid), {:mfa_called, data})
        end
      end

      Process.put(:test_pid, self())
      state = %RNodeInterface{name: "test", owner: {TestCallback, :handle}}
      {:ok, _} = RNodeInterface.process_incoming(state, <<1, 2, 3>>)
      assert_receive {:mfa_called, <<1, 2, 3>>}
    end
  end

  # ── Reconnection ─────────────────────────────────────────────────

  describe "reconnection" do
    test "port closed triggers reconnection" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          skip_open: true
        )

      send(pid, {:port_closed, nil})
      :timer.sleep(50)

      state = RNodeInterface.get_state(pid)
      assert state.online == false
      assert state.reconnecting == true
      GenServer.stop(pid)
    end
  end

  # ── circuits_uart_available? ─────────────────────────────────────

  describe "circuits_uart_available?/0" do
    test "returns a boolean" do
      result = RNodeInterface.circuits_uart_available?()
      assert is_boolean(result)
    end
  end

  # ── Mixed command and data frames ────────────────────────────────

  describe "mixed command and data frames via GenServer" do
    test "interleaved command responses and data frames" do
      {:ok, pid} =
        RNodeInterface.start_link(
          name: "test_rnode",
          owner: self(),
          skip_open: true
        )

      # Send detect response, platform, and data all in one stream
      stream =
        <<0xC0, 0x08, 0x46, 0xC0>> <>
          <<0xC0, 0x48, 0x80, 0xC0>> <>
          <<0xC0, 0x00, 0xAA, 0xBB, 0xC0>>

      send(pid, {:serial_data, stream})
      assert_receive {:rnode_interface_data, <<0xAA, 0xBB>>, _}, 1000

      :timer.sleep(50)
      state = RNodeInterface.get_state(pid)
      assert state.detected == true
      assert state.platform == 0x80
      GenServer.stop(pid)
    end
  end

  # ── ID beacon tracking ──────────────────────────────────────────

  describe "ID beacon tracking" do
    test "first_tx set on first non-callsign transmission" do
      state = %RNodeInterface{
        name: "test",
        online: true,
        interface_ready: true,
        skip_open: true,
        id_callsign: "N0CALL",
        id_interval: 600
      }

      {:ok, updated} = RNodeInterface.process_outgoing(state, <<1, 2, 3>>)
      assert updated.first_tx != nil
    end

    test "first_tx cleared on callsign transmission" do
      state = %RNodeInterface{
        name: "test",
        online: true,
        interface_ready: true,
        skip_open: true,
        id_callsign: "N0CALL",
        id_interval: 600,
        first_tx: System.system_time(:second) - 700
      }

      {:ok, updated} = RNodeInterface.process_outgoing(state, "N0CALL")
      assert updated.first_tx == nil
    end
  end
end
