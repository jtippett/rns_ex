defmodule RNS.Interfaces.RNodeMultiInterfaceTest do
  use ExUnit.Case, async: true

  alias RNS.Interfaces.RNodeMultiInterface, as: Multi
  alias RNS.Interfaces.RNodeSubInterface, as: Sub

  # ── Constants ────────────────────────────────────────────────────

  describe "constants" do
    test "interface constants" do
      c = Multi.constants()
      assert c.max_chunk == 32_768
      assert c.default_ifac_size == 8
      assert c.hw_mtu == 508
      assert c.reconnect_wait == 5_000
      assert c.max_subinterfaces == 11
      assert c.callsign_max_len == 32
    end

    test "firmware version requirements" do
      c = Multi.constants()
      assert c.required_fw_ver_maj == 1
      assert c.required_fw_ver_min == 74
    end

    test "KISS interface selection command" do
      c = Multi.constants()
      assert c.cmd_sel_int == 0x1F
      assert c.cmd_interfaces == 0x71
    end

    test "display constants" do
      c = Multi.constants()
      assert c.fb_pixel_width == 64
      assert c.fb_bytes_per_line == 8
    end

    test "sub-interface constants" do
      c = Sub.constants()
      assert c.low_freq_min == 137_000_000
      assert c.low_freq_max == 1_000_000_000
      assert c.high_freq_min == 2_200_000_000
      assert c.high_freq_max == 2_600_000_000
      assert c.rssi_offset == 157
      assert c.q_snr_min_base == -9
      assert c.q_snr_max == 6
      assert c.q_snr_step == 2
      assert c.hw_mtu == 508
      assert c.default_ifac_size == 8
    end
  end

  # ── Struct ───────────────────────────────────────────────────────

  describe "struct" do
    test "default struct fields" do
      s = %Multi{}
      assert s.name == nil
      assert s.speed == 115_200
      assert s.databits == 8
      assert s.parity == :none
      assert s.stopbits == 1
      assert s.detected == false
      assert s.firmware_ok == false
      assert s.selected_index == 0
      assert s.subinterfaces == %{}
      assert s.subinterface_types == []
      assert s.clients == 0
      assert s.online == false
      assert s.detached == false
    end

    test "sub-interface struct fields" do
      s = Sub.new(name: "test", index: 0)
      assert s.name == "test"
      assert s.index == 0
      assert s.interface_ready == false
      assert s.flow_control == false
      assert s.online == false
      assert s.r_frequency == nil
      assert s.r_bandwidth == nil
    end
  end

  # ── Interface type mapping ─────────────────────────────────────

  describe "interface_type_to_str/1" do
    test "SX126X types" do
      assert Multi.interface_type_to_str(0x10) == "SX126X"
      assert Multi.interface_type_to_str(0x11) == "SX126X"
    end

    test "SX127X types" do
      assert Multi.interface_type_to_str(0x00) == "SX127X"
      assert Multi.interface_type_to_str(0x01) == "SX127X"
      assert Multi.interface_type_to_str(0x02) == "SX127X"
    end

    test "SX128X types" do
      assert Multi.interface_type_to_str(0x20) == "SX128X"
      assert Multi.interface_type_to_str(0x21) == "SX128X"
    end

    test "unknown defaults to SX127X" do
      assert Multi.interface_type_to_str(0xFF) == "SX127X"
    end
  end

  # ── Data command mapping ───────────────────────────────────────

  describe "data_command_for_index/1" do
    test "maps indices to data commands" do
      assert Multi.data_command_for_index(0) == 0x00
      assert Multi.data_command_for_index(1) == 0x10
      assert Multi.data_command_for_index(2) == 0x20
      assert Multi.data_command_for_index(3) == 0x70
      assert Multi.data_command_for_index(4) == 0x75
      assert Multi.data_command_for_index(5) == 0x90
      assert Multi.data_command_for_index(6) == 0xA0
      assert Multi.data_command_for_index(7) == 0xB0
      assert Multi.data_command_for_index(8) == 0xC0
      assert Multi.data_command_for_index(9) == 0xD0
      assert Multi.data_command_for_index(10) == 0xE0
      assert Multi.data_command_for_index(11) == 0xF0
    end
  end

  describe "index_for_data_command/1" do
    test "maps data commands back to indices" do
      assert Multi.index_for_data_command(0x00) == 0
      assert Multi.index_for_data_command(0x10) == 1
      assert Multi.index_for_data_command(0x20) == 2
      assert Multi.index_for_data_command(0x70) == 3
      assert Multi.index_for_data_command(0xF0) == 11
    end

    test "returns nil for unknown command" do
      assert Multi.index_for_data_command(0x99) == nil
    end
  end

  # ── KISS escape/unescape ───────────────────────────────────────

  describe "kiss_escape/1" do
    test "escapes FEND bytes" do
      assert Multi.kiss_escape(<<0xC0>>) == <<0xDB, 0xDC>>
    end

    test "escapes FESC bytes" do
      assert Multi.kiss_escape(<<0xDB>>) == <<0xDB, 0xDD>>
    end

    test "passes through normal bytes" do
      assert Multi.kiss_escape(<<0x01, 0x02, 0x03>>) == <<0x01, 0x02, 0x03>>
    end

    test "escapes mixed data" do
      assert Multi.kiss_escape(<<0x01, 0xC0, 0x02, 0xDB, 0x03>>) ==
               <<0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03>>
    end

    test "handles empty data" do
      assert Multi.kiss_escape(<<>>) == <<>>
    end
  end

  describe "kiss_unescape/1" do
    test "unescapes FEND bytes" do
      assert Multi.kiss_unescape(<<0xDB, 0xDC>>) == <<0xC0>>
    end

    test "unescapes FESC bytes" do
      assert Multi.kiss_unescape(<<0xDB, 0xDD>>) == <<0xDB>>
    end

    test "roundtrip escape/unescape" do
      data = :crypto.strong_rand_bytes(100)
      assert Multi.kiss_unescape(Multi.kiss_escape(data)) == data
    end
  end

  # ── KISS deframe ───────────────────────────────────────────────

  describe "deframe/1" do
    test "extracts simple data frame" do
      frame = <<0xC0, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xC0>>
      {frames, _rest} = Multi.deframe(frame)
      assert length(frames) == 1
      [{cmd, data}] = frames
      assert cmd == 0x00
      assert data == "Hello"
    end

    test "extracts command with escaped bytes" do
      # Frequency command with escaped data
      escaped = Multi.kiss_escape(<<0xC0, 0x01, 0x02, 0x03>>)
      frame = <<0xC0, 0x01>> <> escaped <> <<0xC0>>
      {frames, _rest} = Multi.deframe(frame)
      assert length(frames) == 1
      [{cmd, data}] = frames
      assert cmd == 0x01
      assert Multi.kiss_unescape(data) == <<0xC0, 0x01, 0x02, 0x03>>
    end

    test "preserves full command byte (no port nibble stripping)" do
      # INT1_DATA = 0x10 should remain as 0x10
      frame = <<0xC0, 0x10, 0x48, 0x69, 0xC0>>
      {frames, _rest} = Multi.deframe(frame)
      assert length(frames) == 1
      [{cmd, _data}] = frames
      assert cmd == 0x10
    end

    test "extracts multiple frames" do
      frame = <<0xC0, 0x00, 0x41, 0xC0, 0xC0, 0x00, 0x42, 0xC0>>
      {frames, _rest} = Multi.deframe(frame)
      assert length(frames) == 2
    end

    test "handles partial frame" do
      # Incomplete frame (no closing FEND for data command)
      partial = <<0xC0, 0x48, 0x01, 0x02>>
      {frames, _rest} = Multi.deframe(partial)
      assert frames == []
    end

    test "handles empty buffer" do
      {frames, rest} = Multi.deframe(<<>>)
      assert frames == []
      assert rest == <<>>
    end

    test "handles fragmented delivery" do
      # First part
      {frames1, rest1} = Multi.deframe(<<0xC0, 0x00, 0x48>>)
      assert frames1 == []
      # Second part with remaining
      {frames2, _rest2} = Multi.deframe(rest1 <> <<0x65, 0x6C, 0xC0>>)
      assert length(frames2) == 1
    end
  end

  # ── Command building ───────────────────────────────────────────

  describe "build_sel_command/3" do
    test "builds select + command frame" do
      frame = Multi.build_sel_command(1, 0x01, <<0x00, 0x01, 0x00, 0x00>>)
      # Should be: FEND SEL_INT 1 FEND FEND CMD_FREQ escaped_data FEND
      assert <<0xC0, 0x1F, 1, 0xC0, 0xC0, 0x01, _rest::binary>> = frame
    end
  end

  describe "build_detect_frame/0" do
    test "builds detect frame with multiple commands" do
      frame = Multi.build_detect_frame()
      assert <<0xC0, 0x08, 0x73, 0xC0, _rest::binary>> = frame
      assert byte_size(frame) > 10
    end
  end

  describe "build_leave_frame/0" do
    test "builds leave frame" do
      frame = Multi.build_leave_frame()
      assert frame == <<0xC0, 0x0A, 0xFF, 0xC0>>
    end
  end

  # ── Encoding ───────────────────────────────────────────────────

  describe "encode_frequency/1" do
    test "encodes frequency as 4-byte big-endian" do
      assert Multi.encode_frequency(868_000_000) == <<0x33, 0xBC, 0xA1, 0x00>>
    end
  end

  describe "encode_bandwidth/1" do
    test "encodes bandwidth as 4-byte big-endian" do
      assert Multi.encode_bandwidth(125_000) == <<0x00, 0x01, 0xE8, 0x48>>
    end
  end

  describe "encode_txpower/1" do
    test "encodes positive TX power" do
      assert Multi.encode_txpower(17) == <<17>>
    end

    test "encodes negative TX power" do
      <<byte>> = Multi.encode_txpower(-3)
      # -3 as signed byte = 0xFD (253 unsigned)
      assert byte == 253
    end
  end

  describe "encode_sf/1" do
    test "encodes spreading factor" do
      assert Multi.encode_sf(7) == <<7>>
      assert Multi.encode_sf(12) == <<12>>
    end
  end

  describe "encode_cr/1" do
    test "encodes coding rate" do
      assert Multi.encode_cr(5) == <<5>>
      assert Multi.encode_cr(8) == <<8>>
    end
  end

  describe "encode_alock/1" do
    test "encodes airtime lock as 2-byte value" do
      assert Multi.encode_alock(50.0) == <<0x13, 0x88>>
    end

    test "encodes zero airtime lock" do
      assert Multi.encode_alock(0.0) == <<0x00, 0x00>>
    end
  end

  # ── Firmware validation ────────────────────────────────────────

  describe "validate_firmware/2" do
    test "valid firmware" do
      assert Multi.validate_firmware(1, 74) == true
      assert Multi.validate_firmware(1, 80) == true
      assert Multi.validate_firmware(2, 0) == true
    end

    test "invalid firmware" do
      assert Multi.validate_firmware(1, 73) == false
      assert Multi.validate_firmware(0, 99) == false
    end
  end

  # ── Handle command ─────────────────────────────────────────────

  describe "handle_command/3" do
    setup do
      sub =
        Sub.new(
          name: "sub0",
          index: 0,
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 5
        )

      state = %Multi{subinterfaces: %{0 => sub}, selected_index: 0}
      {:ok, state: state}
    end

    test "detect response", %{state: state} do
      state = Multi.handle_command(state, 0x08, <<0x46>>)
      assert state.detected == true
    end

    test "detect invalid response", %{state: state} do
      state = Multi.handle_command(state, 0x08, <<0x00>>)
      assert state.detected == false
    end

    test "firmware version", %{state: state} do
      state = Multi.handle_command(state, 0x50, <<1, 74>>)
      assert state.maj_version == 1
      assert state.min_version == 74
      assert state.firmware_ok == true
    end

    test "firmware version invalid", %{state: state} do
      state = Multi.handle_command(state, 0x50, <<1, 50>>)
      assert state.firmware_ok == false
    end

    test "platform ESP32", %{state: state} do
      state = Multi.handle_command(state, 0x48, <<0x80>>)
      assert state.platform == 0x80
      assert state.display == true
    end

    test "MCU", %{state: state} do
      state = Multi.handle_command(state, 0x49, <<0x42>>)
      assert state.mcu == 0x42
    end

    test "interface types", %{state: state} do
      state = Multi.handle_command(state, 0x71, <<0, 0x00>>)
      assert state.subinterface_types == ["SX127X"]
      state = Multi.handle_command(state, 0x71, <<1, 0x10>>)
      assert state.subinterface_types == ["SX127X", "SX126X"]
    end

    test "select interface", %{state: state} do
      state = Multi.handle_command(state, 0x1F, <<3>>)
      assert state.selected_index == 3
    end

    test "frequency update on sub-interface", %{state: state} do
      state = Multi.handle_command(state, 0x01, <<0x33, 0xBC, 0xA1, 0x00>>)
      assert state.subinterfaces[0].r_frequency == 868_000_000
    end

    test "bandwidth update on sub-interface", %{state: state} do
      state = Multi.handle_command(state, 0x02, <<0x00, 0x01, 0xE8, 0x48>>)
      assert state.subinterfaces[0].r_bandwidth == 125_000
    end

    test "TX power update on sub-interface", %{state: state} do
      state = Multi.handle_command(state, 0x03, <<17>>)
      assert state.subinterfaces[0].r_txpower == 17
    end

    test "TX power negative on sub-interface", %{state: state} do
      state = Multi.handle_command(state, 0x03, <<253>>)
      assert state.subinterfaces[0].r_txpower == -3
    end

    test "spreading factor update", %{state: state} do
      state = Multi.handle_command(state, 0x04, <<12>>)
      assert state.subinterfaces[0].r_sf == 12
    end

    test "coding rate update", %{state: state} do
      state = Multi.handle_command(state, 0x05, <<8>>)
      assert state.subinterfaces[0].r_cr == 8
    end

    test "radio state update", %{state: state} do
      state = Multi.handle_command(state, 0x06, <<1>>)
      assert state.subinterfaces[0].r_state == 1
    end

    test "radio lock update", %{state: state} do
      state = Multi.handle_command(state, 0x07, <<1>>)
      assert state.subinterfaces[0].r_lock == 1
    end

    test "RSSI update on sub-interface", %{state: state} do
      state = Multi.handle_command(state, 0x23, <<100>>)
      assert state.subinterfaces[0].r_stat_rssi == 100 - 157
    end

    test "SNR update on sub-interface", %{state: state} do
      # Set r_sf first for quality calc
      state = put_in(state, [Access.key(:subinterfaces), Access.key(0), Access.key(:r_sf)], 7)
      state = Multi.handle_command(state, 0x24, <<40>>)
      assert state.subinterfaces[0].r_stat_snr == 40 * 0.25
      assert state.subinterfaces[0].r_stat_q != nil
    end

    test "short-term airtime lock", %{state: state} do
      state = Multi.handle_command(state, 0x0B, <<0x13, 0x88>>)
      assert state.subinterfaces[0].r_st_alock == 50.0
    end

    test "long-term airtime lock", %{state: state} do
      state = Multi.handle_command(state, 0x0C, <<0x09, 0xC4>>)
      assert state.subinterfaces[0].r_lt_alock == 25.0
    end

    test "channel timing", %{state: state} do
      data = <<0x00, 0x64, 0x00, 0xC8, 0x01, 0x2C, 0x01, 0x90>>
      state = Multi.handle_command(state, 0x25, data)
      assert state.r_airtime_short == 1.0
      assert state.r_airtime_long == 2.0
      assert state.r_channel_load_short == 3.0
      assert state.r_channel_load_long == 4.0
    end

    test "physical parameters", %{state: state} do
      data = <<0x00, 0x0A, 0x00, 0x14, 0x00, 0x1E, 0x00, 0x28, 0x00, 0x32>>
      state = Multi.handle_command(state, 0x26, data)
      assert state.subinterfaces[0].r_symbol_time_ms == 10 / 1000.0
      assert state.subinterfaces[0].r_symbol_rate == 20
      assert state.subinterfaces[0].r_preamble_symbols == 30
      assert state.subinterfaces[0].r_preamble_time_ms == 40
      assert state.subinterfaces[0].r_csma_slot_time_ms == 50
    end

    test "random byte", %{state: state} do
      state = Multi.handle_command(state, 0x40, <<0xAB>>)
      assert state.r_random == 0xAB
    end

    test "error handling", %{state: state} do
      # Should not crash
      state = Multi.handle_command(state, 0x90, <<0x01>>)
      assert state.detected == false
    end

    test "ready processes queue", %{state: state} do
      state = Multi.handle_command(state, 0x0F, <<>>)
      assert state.subinterfaces[0].interface_ready == true
    end

    test "unrecognized command is no-op", %{state: state} do
      state2 = Multi.handle_command(state, 0xFE, <<0x01>>)
      assert state2 == state
    end
  end

  # ── Sub-interface radio param validation ───────────────────────

  describe "Sub.validate_radio_params/1" do
    test "valid SX127X params" do
      sub =
        Sub.new(
          interface_type: "SX127X",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 5
        )

      assert Sub.validate_radio_params(sub) == :ok
    end

    test "valid SX128X params" do
      sub =
        Sub.new(
          interface_type: "SX128X",
          frequency: 2_400_000_000,
          bandwidth: 125_000,
          txpower: 10,
          sf: 7,
          cr: 5
        )

      assert Sub.validate_radio_params(sub) == :ok
    end

    test "invalid frequency for SX127X" do
      sub =
        Sub.new(
          interface_type: "SX127X",
          frequency: 50_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 5
        )

      assert {:error, _} = Sub.validate_radio_params(sub)
    end

    test "invalid frequency for SX128X" do
      sub =
        Sub.new(
          interface_type: "SX128X",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 10,
          sf: 7,
          cr: 5
        )

      assert {:error, _} = Sub.validate_radio_params(sub)
    end

    test "missing frequency" do
      sub = Sub.new(interface_type: "SX127X", bandwidth: 125_000, txpower: 17, sf: 7, cr: 5)
      assert {:error, "No frequency configured"} = Sub.validate_radio_params(sub)
    end

    test "invalid bandwidth" do
      sub =
        Sub.new(
          interface_type: "SX127X",
          frequency: 868_000_000,
          bandwidth: 5000,
          txpower: 17,
          sf: 7,
          cr: 5
        )

      assert {:error, _} = Sub.validate_radio_params(sub)
    end

    test "invalid TX power" do
      sub =
        Sub.new(
          interface_type: "SX127X",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 50,
          sf: 7,
          cr: 5
        )

      assert {:error, _} = Sub.validate_radio_params(sub)
    end

    test "invalid spreading factor" do
      sub =
        Sub.new(
          interface_type: "SX127X",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 13,
          cr: 5
        )

      assert {:error, _} = Sub.validate_radio_params(sub)
    end

    test "invalid coding rate" do
      sub =
        Sub.new(
          interface_type: "SX127X",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 9
        )

      assert {:error, _} = Sub.validate_radio_params(sub)
    end

    test "invalid airtime limits" do
      sub =
        Sub.new(
          interface_type: "SX127X",
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 5,
          st_alock: 150.0
        )

      assert {:error, _} = Sub.validate_radio_params(sub)
    end
  end

  # ── Sub-interface bitrate calculation ──────────────────────────

  describe "Sub.calculate_bitrate/3" do
    test "calculates LoRa bitrate" do
      # SF 7, CR 5, BW 125000
      bitrate = Sub.calculate_bitrate(7, 5, 125_000)
      assert is_float(bitrate)
      assert bitrate > 0
    end

    test "matches Python formula" do
      # sf * (4.0/cr / (2^sf / (bw/1000))) * 1000
      bitrate = Sub.calculate_bitrate(7, 5, 125_000)
      expected = 7 * (4.0 / 5 / (:math.pow(2, 7) / (125_000 / 1000))) * 1000
      assert_in_delta bitrate, expected, 0.001
    end

    test "returns 0 for zero values" do
      assert Sub.calculate_bitrate(0, 5, 125_000) == 0.0
      assert Sub.calculate_bitrate(7, 0, 125_000) == 0.0
      assert Sub.calculate_bitrate(7, 5, 0) == 0.0
    end
  end

  # ── Sub-interface quality calculation ──────────────────────────

  describe "Sub.calculate_quality/2" do
    test "returns nil for nil sf" do
      assert Sub.calculate_quality(5.0, nil) == nil
    end

    test "clamps to 0-100" do
      # Very low SNR
      q = Sub.calculate_quality(-20.0, 7)
      assert q == 0.0

      # Very high SNR
      q = Sub.calculate_quality(20.0, 7)
      assert q == 100.0
    end

    test "mid-range quality" do
      q = Sub.calculate_quality(0.0, 7)
      assert q > 0.0
      assert q < 100.0
    end
  end

  # ── Sub-interface update_bitrate ───────────────────────────────

  describe "Sub.update_bitrate/1" do
    test "updates bitrate when reported params available" do
      sub = Sub.new(name: "test")
      sub = %{sub | r_sf: 7, r_cr: 5, r_bandwidth: 125_000}
      updated = Sub.update_bitrate(sub)
      assert updated.bitrate > 0
    end

    test "does not update with missing params" do
      sub = Sub.new(name: "test")
      updated = Sub.update_bitrate(sub)
      assert updated.bitrate == sub.bitrate
    end
  end

  # ── Sub-interface validate_radio_state ─────────────────────────

  describe "Sub.validate_radio_state/1" do
    test "validates matching state" do
      sub =
        Sub.new(
          frequency: 868_000_000,
          bandwidth: 125_000,
          txpower: 17,
          sf: 7,
          cr: 5
        )

      sub = %{
        sub
        | r_frequency: 868_000_000,
          r_bandwidth: 125_000,
          r_txpower: 17,
          r_sf: 7,
          r_state: 0
      }

      assert Sub.validate_radio_state(sub) == true
    end

    test "allows nil reported values" do
      sub = Sub.new(frequency: 868_000_000, bandwidth: 125_000, txpower: 17, sf: 7, cr: 5)
      assert Sub.validate_radio_state(sub) == true
    end

    test "detects frequency mismatch" do
      sub = Sub.new(frequency: 868_000_000, bandwidth: 125_000, txpower: 17, sf: 7, cr: 5)
      sub = %{sub | r_frequency: 915_000_000}
      assert Sub.validate_radio_state(sub) == false
    end

    test "allows small frequency tolerance" do
      sub = Sub.new(frequency: 868_000_000, bandwidth: 125_000, txpower: 17, sf: 7, cr: 5)
      sub = %{sub | r_frequency: 868_000_050}
      assert Sub.validate_radio_state(sub) == true
    end
  end

  # ── Sub-interface flow control ─────────────────────────────────

  describe "Sub.queue/2 and Sub.process_queue/1" do
    test "queues and processes packets" do
      sub = Sub.new(name: "test")
      sub = Sub.queue(sub, "packet1")
      sub = Sub.queue(sub, "packet2")
      assert :queue.len(sub.packet_queue) == 2

      sub = Sub.process_queue(sub)
      assert sub.interface_ready == true
    end

    test "empty queue sets interface_ready" do
      sub = Sub.new(name: "test")
      sub = Sub.process_queue(sub)
      assert sub.interface_ready == true
    end
  end

  # ── Sub-interface process_incoming ─────────────────────────────

  describe "Sub.process_incoming/2" do
    test "updates rxb and clears RSSI/SNR" do
      sub = Sub.new(name: "test", owner: self())
      sub = %{sub | r_stat_rssi: -80, r_stat_snr: 5.0}
      {:ok, updated} = Sub.process_incoming(sub, "test data")
      assert updated.rxb == 9
      assert updated.r_stat_rssi == nil
      assert updated.r_stat_snr == nil
    end

    test "notifies owner pid" do
      sub = Sub.new(name: "test", owner: self())
      Sub.process_incoming(sub, "hello")
      assert_receive {:interface_data, "hello", _}
    end
  end

  # ── GenServer ──────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts with skip_open" do
      {:ok, pid} = Multi.start_link(name: "TestMulti", skip_open: true)
      state = GenServer.call(pid, :get_state)
      assert state.name == "TestMulti"
      assert state.online == false
      GenServer.stop(pid)
    end

    test "fails without port when not skipping" do
      Process.flag(:trap_exit, true)
      assert {:error, :no_port} = Multi.start_link(name: "TestMulti", skip_open: false)
    end

    test "computes hash" do
      {:ok, pid} = Multi.start_link(name: "TestMulti", skip_open: true)
      state = GenServer.call(pid, :get_state)
      assert state.hash != nil
      assert is_binary(state.hash)
      GenServer.stop(pid)
    end

    test "configures ID callsign" do
      {:ok, pid} =
        Multi.start_link(
          name: "TestMulti",
          skip_open: true,
          id_interval: 600,
          id_callsign: "VK2ABC"
        )

      state = GenServer.call(pid, :get_state)
      assert state.should_id == true
      assert state.id_callsign == "VK2ABC"
      GenServer.stop(pid)
    end

    test "server_name registration" do
      {:ok, pid} = Multi.start_link(name: "TestMulti", skip_open: true, server_name: :test_multi)
      assert Process.whereis(:test_multi) == pid
      GenServer.stop(pid)
    end
  end

  # ── Serial data injection ──────────────────────────────────────

  describe "serial data processing" do
    test "processes injected serial data with sub-interface" do
      {:ok, pid} = Multi.start_link(name: "TestMulti", skip_open: true, owner: self())

      # Add a sub-interface to state
      sub = Sub.new(name: "sub0", index: 0, owner: self())
      sub = %{sub | online: true}

      :sys.replace_state(pid, fn state ->
        %{state | subinterfaces: %{0 => sub}}
      end)

      # Send a data frame for INT0 (0x00)
      data = <<0xC0, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xC0>>
      send(pid, {:serial_data, data})

      assert_receive {:rnode_multi_data, "Hello", 0}, 1000
    end

    test "processes detect response" do
      {:ok, pid} = Multi.start_link(name: "TestMulti", skip_open: true)

      # Send detect response
      data = <<0xC0, 0x08, 0x46, 0xC0>>
      send(pid, {:serial_data, data})
      Process.sleep(50)

      state = GenServer.call(pid, :get_state)
      assert state.detected == true
      GenServer.stop(pid)
    end

    test "processes firmware version" do
      {:ok, pid} = Multi.start_link(name: "TestMulti", skip_open: true)

      data = <<0xC0, 0x50, 1, 74, 0xC0>>
      send(pid, {:serial_data, data})
      Process.sleep(50)

      state = GenServer.call(pid, :get_state)
      assert state.maj_version == 1
      assert state.min_version == 74
      assert state.firmware_ok == true
      GenServer.stop(pid)
    end

    test "processes interface types" do
      {:ok, pid} = Multi.start_link(name: "TestMulti", skip_open: true)

      # Two interface type reports
      data = <<0xC0, 0x71, 0, 0x00, 0xC0, 0xC0, 0x71, 1, 0x10, 0xC0>>
      send(pid, {:serial_data, data})
      Process.sleep(50)

      state = GenServer.call(pid, :get_state)
      assert state.subinterface_types == ["SX127X", "SX126X"]
      GenServer.stop(pid)
    end
  end

  # ── Announce tracking ──────────────────────────────────────────

  describe "announce tracking" do
    test "received_announce from spawned" do
      state = %Multi{ia_freq_deque: []}
      state = Multi.received_announce(state, true)
      assert length(state.ia_freq_deque) == 1
    end

    test "received_announce not from spawned is no-op" do
      state = %Multi{ia_freq_deque: []}
      state = Multi.received_announce(state, false)
      assert state.ia_freq_deque == []
    end

    test "sent_announce from spawned" do
      state = %Multi{oa_freq_deque: []}
      state = Multi.sent_announce(state, true)
      assert length(state.oa_freq_deque) == 1
    end
  end

  # ── should_ingress_limit ───────────────────────────────────────

  describe "should_ingress_limit/1" do
    test "always returns false" do
      state = %Multi{}
      assert {false, ^state} = Multi.should_ingress_limit(state)
    end
  end

  # ── String.Chars ───────────────────────────────────────────────

  describe "String.Chars" do
    test "RNodeMultiInterface" do
      iface = %Multi{name: "LoRa Multi"}
      assert to_string(iface) == "RNodeMultiInterface[LoRa Multi]"
    end

    test "RNodeSubInterface" do
      parent = %Multi{name: "LoRa Multi"}
      sub = Sub.new(name: "Radio 1", parent_interface: parent)
      assert to_string(sub) == "LoRa Multi[Radio 1]"
    end

    test "RNodeSubInterface without parent" do
      sub = Sub.new(name: "Radio 1")
      assert to_string(sub) == "RNodeMulti[Radio 1]"
    end
  end

  # ── Interface behaviour ────────────────────────────────────────

  describe "Interface behaviour" do
    test "process_outgoing on parent is no-op" do
      state = %Multi{txb: 0}
      {:ok, result} = Multi.process_outgoing(state, "test")
      assert result.txb == 0
    end

    test "process_incoming updates rxb" do
      state = %Multi{rxb: 0}
      {:ok, result} = Multi.process_incoming(state, "test data")
      assert result.rxb == 9
    end

    test "sub should_ingress_limit always false" do
      sub = Sub.new(name: "test")
      assert {false, ^sub} = Sub.should_ingress_limit(sub)
    end
  end
end
