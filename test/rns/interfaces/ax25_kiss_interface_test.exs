defmodule RNS.Interfaces.AX25KISSInterfaceTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias RNS.Interfaces.AX25KISSInterface
  alias RNS.Interfaces.Interface.KISS

  # ── AX.25 Constants ─────────────────────────────────────────────

  describe "AX.25 constants" do
    test "header size is 16" do
      assert AX25KISSInterface.ax25_header_size() == 16
    end

    test "PID no layer 3 is 0xF0" do
      assert AX25KISSInterface.ax25_pid_nolayer3() == 0xF0
    end

    test "CTRL UI is 0x03" do
      assert AX25KISSInterface.ax25_ctrl_ui() == 0x03
    end
  end

  # ── Interface Constants ─────────────────────────────────────────

  describe "interface constants" do
    test "max_chunk is 32768" do
      assert AX25KISSInterface.max_chunk() == 32_768
    end

    test "default_ifac_size is 8" do
      assert AX25KISSInterface.default_ifac_size() == 8
    end

    test "hw_mtu is 564" do
      assert AX25KISSInterface.hw_mtu() == 564
    end

    test "bitrate_guess is 1200" do
      assert AX25KISSInterface.bitrate_guess() == 1_200
    end

    test "reconnect_wait is 5000ms" do
      assert AX25KISSInterface.reconnect_wait() == 5_000
    end
  end

  # ── Struct fields ──────────────────────────────────────────────

  describe "struct" do
    test "has default interface fields" do
      iface = %AX25KISSInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has AX.25-specific fields with defaults" do
      iface = %AX25KISSInterface{}
      assert iface.src_call == <<>>
      assert iface.src_ssid == 0
      assert iface.dst_call == "APZRNS"
      assert iface.dst_ssid == 0
      assert iface.preamble == 350
      assert iface.txtail == 20
      assert iface.persistence == 64
      assert iface.slottime == 20
      assert iface.flow_control == false
      assert iface.interface_ready == true
    end
  end

  # ── Callsign/SSID validation ────────────────────────────────────

  describe "valid_callsign?/1" do
    test "accepts valid callsigns (3-6 chars)" do
      assert AX25KISSInterface.valid_callsign?("ABC") == true
      assert AX25KISSInterface.valid_callsign?("N0CALL") == true
      assert AX25KISSInterface.valid_callsign?("W1AW") == true
      assert AX25KISSInterface.valid_callsign?("ABCDEF") == true
    end

    test "rejects too short callsigns" do
      assert AX25KISSInterface.valid_callsign?("AB") == false
      assert AX25KISSInterface.valid_callsign?("A") == false
      assert AX25KISSInterface.valid_callsign?("") == false
    end

    test "rejects too long callsigns" do
      assert AX25KISSInterface.valid_callsign?("ABCDEFG") == false
      assert AX25KISSInterface.valid_callsign?("TOOLONGCALL") == false
    end

    test "rejects non-binary input" do
      assert AX25KISSInterface.valid_callsign?(nil) == false
      assert AX25KISSInterface.valid_callsign?(42) == false
    end
  end

  describe "valid_ssid?/1" do
    test "accepts valid SSIDs (0-15)" do
      for ssid <- 0..15 do
        assert AX25KISSInterface.valid_ssid?(ssid) == true
      end
    end

    test "rejects negative SSIDs" do
      assert AX25KISSInterface.valid_ssid?(-1) == false
      assert AX25KISSInterface.valid_ssid?(-100) == false
    end

    test "rejects SSIDs > 15" do
      assert AX25KISSInterface.valid_ssid?(16) == false
      assert AX25KISSInterface.valid_ssid?(255) == false
    end

    test "rejects non-integer input" do
      assert AX25KISSInterface.valid_ssid?(nil) == false
    end
  end

  # ── AX.25 address encoding ─────────────────────────────────────

  describe "encode_address/3" do
    test "encodes destination address" do
      addr = AX25KISSInterface.encode_address("APZRNS", 0, :dst)
      assert byte_size(addr) == 7

      # Each character is shifted left by 1 bit
      assert :binary.at(addr, 0) == ?A <<< 1
      assert :binary.at(addr, 1) == ?P <<< 1
      assert :binary.at(addr, 2) == ?Z <<< 1
      assert :binary.at(addr, 3) == ?R <<< 1
      assert :binary.at(addr, 4) == ?N <<< 1
      assert :binary.at(addr, 5) == ?S <<< 1

      # Destination SSID byte: 0x60 | (ssid << 1)
      assert :binary.at(addr, 6) == 0x60
    end

    test "encodes source address with extension bit" do
      addr = AX25KISSInterface.encode_address("N0CALL", 7, :src)
      assert byte_size(addr) == 7

      assert :binary.at(addr, 0) == ?N <<< 1
      assert :binary.at(addr, 1) == ?0 <<< 1
      assert :binary.at(addr, 2) == ?C <<< 1
      assert :binary.at(addr, 3) == ?A <<< 1
      assert :binary.at(addr, 4) == ?L <<< 1
      assert :binary.at(addr, 5) == ?L <<< 1

      # Source SSID byte: 0x60 | (ssid << 1) | 0x01
      expected_ssid = 0x60 ||| 7 <<< 1 ||| 0x01
      assert :binary.at(addr, 6) == expected_ssid
    end

    test "pads short callsigns with spaces" do
      addr = AX25KISSInterface.encode_address("W1A", 0, :dst)
      assert byte_size(addr) == 7

      assert :binary.at(addr, 0) == ?W <<< 1
      assert :binary.at(addr, 1) == ?1 <<< 1
      assert :binary.at(addr, 2) == ?A <<< 1
      # Padded positions are 0x20 (space, but NOT shifted since it's already the pad value)
      assert :binary.at(addr, 3) == 0x20
      assert :binary.at(addr, 4) == 0x20
      assert :binary.at(addr, 5) == 0x20
    end
  end

  # ── AX.25 header building ───────────────────────────────────────

  describe "build_ax25_header/4" do
    test "builds 16-byte header" do
      header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 7)
      assert byte_size(header) == 16
    end

    test "header contains dst + src + ctrl + pid" do
      header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 7)

      # Last two bytes are CTRL_UI and PID_NOLAYER3
      assert :binary.at(header, 14) == 0x03
      assert :binary.at(header, 15) == 0xF0
    end

    test "destination comes first in header" do
      header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 7)

      # First byte should be 'A' shifted left
      assert :binary.at(header, 0) == ?A <<< 1
      # Byte 7 should be start of source ('N' shifted left)
      assert :binary.at(header, 7) == ?N <<< 1
    end
  end

  # ── Parity parsing ─────────────────────────────────────────────

  describe "parse_parity/1" do
    test "parses parity strings" do
      assert AX25KISSInterface.parse_parity("N") == :none
      assert AX25KISSInterface.parse_parity("E") == :even
      assert AX25KISSInterface.parse_parity("O") == :odd
      assert AX25KISSInterface.parse_parity("even") == :even
      assert AX25KISSInterface.parse_parity("odd") == :odd
    end
  end

  # ── GenServer lifecycle with skip_open ──────────────────────────

  describe "start_link/1 with skip_open" do
    test "starts successfully with valid callsign and SSID" do
      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_ax25",
          port: "/dev/ttyAX25",
          callsign: "N0CALL",
          ssid: 7,
          skip_open: true
        )

      state = AX25KISSInterface.get_state(pid)
      assert state.name == "test_ax25"
      assert state.src_call == "N0CALL"
      assert state.src_ssid == 7
      assert state.dst_call == "APZRNS"
      assert state.dst_ssid == 0
      assert state.online == true
      assert state.bitrate == 1_200
      assert state.hw_mtu == 564

      GenServer.stop(pid)
    end

    test "uppercases callsign" do
      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_upper",
          port: "/dev/ttyAX25",
          callsign: "n0call",
          ssid: 0,
          skip_open: true
        )

      state = AX25KISSInterface.get_state(pid)
      assert state.src_call == "N0CALL"

      GenServer.stop(pid)
    end

    test "fails with invalid callsign (too short)" do
      Process.flag(:trap_exit, true)

      result =
        AX25KISSInterface.start_link(
          name: "test_bad_call",
          port: "/dev/ttyAX25",
          callsign: "AB",
          ssid: 0,
          skip_open: true
        )

      assert {:error, {:error, :invalid_callsign}} = result
    end

    test "fails with invalid callsign (too long)" do
      Process.flag(:trap_exit, true)

      result =
        AX25KISSInterface.start_link(
          name: "test_long_call",
          port: "/dev/ttyAX25",
          callsign: "TOOLONG",
          ssid: 0,
          skip_open: true
        )

      assert {:error, {:error, :invalid_callsign}} = result
    end

    test "fails with invalid SSID (negative)" do
      Process.flag(:trap_exit, true)

      result =
        AX25KISSInterface.start_link(
          name: "test_bad_ssid",
          port: "/dev/ttyAX25",
          callsign: "N0CALL",
          ssid: -1,
          skip_open: true
        )

      assert {:error, {:error, :invalid_ssid}} = result
    end

    test "fails with invalid SSID (> 15)" do
      Process.flag(:trap_exit, true)

      result =
        AX25KISSInterface.start_link(
          name: "test_big_ssid",
          port: "/dev/ttyAX25",
          callsign: "N0CALL",
          ssid: 16,
          skip_open: true
        )

      assert {:error, {:error, :invalid_ssid}} = result
    end

    test "starts with custom TNC parameters" do
      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_tnc",
          port: "/dev/ttyAX25",
          callsign: "W1AW",
          ssid: 1,
          preamble: 500,
          txtail: 50,
          persistence: 128,
          slottime: 40,
          skip_open: true
        )

      state = AX25KISSInterface.get_state(pid)
      assert state.preamble == 500
      assert state.txtail == 50
      assert state.persistence == 128
      assert state.slottime == 40

      GenServer.stop(pid)
    end
  end

  # ── AX.25 KISS framing roundtrip ────────────────────────────────

  describe "AX.25 KISS framing roundtrip" do
    test "incoming data has AX.25 header stripped" do
      test_pid = self()

      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_ax25_in",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          owner: test_pid,
          skip_open: true
        )

      # Build a KISS frame with AX.25 header + payload
      payload = "Hello AX.25"
      ax25_header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 0)
      ax25_frame = ax25_header <> payload
      kiss_frame = KISS.frame(ax25_frame)

      send(pid, {:serial_data, kiss_frame})

      # Should receive just the payload, with AX.25 header stripped
      assert_receive {:ax25_kiss_interface_data, ^payload, _iface}, 1000

      GenServer.stop(pid)
    end

    test "packets smaller than header are ignored" do
      test_pid = self()

      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_ax25_small",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          owner: test_pid,
          skip_open: true
        )

      # Send a KISS frame with data smaller than the AX.25 header
      small_data = :crypto.strong_rand_bytes(10)
      kiss_frame = KISS.frame(small_data)

      send(pid, {:serial_data, kiss_frame})

      refute_receive {:ax25_kiss_interface_data, _, _}, 200

      GenServer.stop(pid)
    end

    test "outgoing data gets AX.25 header prepended" do
      state = %AX25KISSInterface{
        name: "tx_test",
        online: true,
        skip_open: true,
        src_call: "N0CALL",
        src_ssid: 7,
        dst_call: "APZRNS",
        dst_ssid: 0
      }

      {:ok, updated} = AX25KISSInterface.process_outgoing(state, "outgoing data")
      # txb tracks the original data size (without AX.25 header)
      assert updated.txb == byte_size("outgoing data")
    end

    test "multiple frames received" do
      test_pid = self()

      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_ax25_multi",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          owner: test_pid,
          skip_open: true
        )

      ax25_header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 0)

      msg1 = "first"
      msg2 = "second"

      combined =
        KISS.frame(ax25_header <> msg1) <> KISS.frame(ax25_header <> msg2)

      send(pid, {:serial_data, combined})

      assert_receive {:ax25_kiss_interface_data, ^msg1, _}, 1000
      assert_receive {:ax25_kiss_interface_data, ^msg2, _}, 1000

      GenServer.stop(pid)
    end

    test "KISS special bytes in payload are handled" do
      test_pid = self()

      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_ax25_special",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          owner: test_pid,
          skip_open: true
        )

      # Payload containing KISS special bytes
      payload = <<0xC0, 0xDB, 0x00, 0xFF>>
      ax25_header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 0)
      kiss_frame = KISS.frame(ax25_header <> payload)

      send(pid, {:serial_data, kiss_frame})

      assert_receive {:ax25_kiss_interface_data, ^payload, _iface}, 1000

      GenServer.stop(pid)
    end

    test "fragmented frame delivery" do
      test_pid = self()

      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_ax25_frag",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          owner: test_pid,
          skip_open: true
        )

      payload = "fragmented AX.25 test"
      ax25_header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 0)
      kiss_frame = KISS.frame(ax25_header <> payload)

      mid = div(byte_size(kiss_frame), 2)
      part1 = binary_part(kiss_frame, 0, mid)
      part2 = binary_part(kiss_frame, mid, byte_size(kiss_frame) - mid)

      send(pid, {:serial_data, part1})
      Process.sleep(10)
      send(pid, {:serial_data, part2})

      assert_receive {:ax25_kiss_interface_data, ^payload, _iface}, 1000

      GenServer.stop(pid)
    end
  end

  # ── process_outgoing ────────────────────────────────────────────

  describe "process_outgoing/2" do
    test "returns error when offline" do
      state = %AX25KISSInterface{name: "offline", online: false}
      assert {:error, :offline} = AX25KISSInterface.process_outgoing(state, "test")
    end

    test "queues data when interface_ready is false" do
      state = %AX25KISSInterface{
        name: "queue_test",
        online: true,
        skip_open: true,
        interface_ready: false,
        src_call: "N0CALL",
        src_ssid: 0
      }

      {:ok, updated} = AX25KISSInterface.process_outgoing(state, "queued")
      assert :queue.len(updated.packet_queue) == 1
    end
  end

  # ── Flow control ───────────────────────────────────────────────

  describe "flow control" do
    test "queue_packet adds to packet queue" do
      state = %AX25KISSInterface{name: "fc_test"}
      state = AX25KISSInterface.queue_packet(state, "p1")
      state = AX25KISSInterface.queue_packet(state, "p2")
      assert :queue.len(state.packet_queue) == 2
    end

    test "process_queue sends next packet and restores interface_ready" do
      state = %AX25KISSInterface{
        name: "pq_test",
        online: true,
        skip_open: true,
        interface_ready: false,
        src_call: "N0CALL",
        src_ssid: 0,
        dst_call: "APZRNS",
        dst_ssid: 0
      }

      state = AX25KISSInterface.queue_packet(state, "queued_data")
      updated = AX25KISSInterface.process_queue(state)
      assert updated.interface_ready == true
      assert updated.txb == byte_size("queued_data")
    end

    test "process_queue sets interface_ready when empty" do
      state = %AX25KISSInterface{
        name: "pq_empty",
        online: true,
        skip_open: true,
        interface_ready: false
      }

      updated = AX25KISSInterface.process_queue(state)
      assert updated.interface_ready == true
    end
  end

  # ── Byte counters ──────────────────────────────────────────────

  describe "byte counters" do
    test "rxb accumulates including AX.25 header" do
      test_pid = self()

      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_rxb_ax25",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          owner: test_pid,
          skip_open: true
        )

      ax25_header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 0)

      msg = "count"
      full = ax25_header <> msg
      send(pid, {:serial_data, KISS.frame(full)})

      assert_receive {:ax25_kiss_interface_data, ^msg, _}, 1000

      state = AX25KISSInterface.get_state(pid)
      # rxb includes the full frame (header + payload)
      assert state.rxb == byte_size(full)

      GenServer.stop(pid)
    end
  end

  # ── Detach ─────────────────────────────────────────────────────

  describe "detach" do
    test "marks interface offline and detached" do
      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_detach",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          skip_open: true
        )

      :ok = AX25KISSInterface.stop(pid)
      state = AX25KISSInterface.get_state(pid)
      assert state.online == false
      assert state.detached == true

      GenServer.stop(pid)
    end
  end

  # ── should_ingress_limit ────────────────────────────────────────

  describe "should_ingress_limit/1" do
    test "always returns false" do
      state = %AX25KISSInterface{name: "test"}
      assert {false, ^state} = AX25KISSInterface.should_ingress_limit(state)
    end
  end

  # ── String.Chars ────────────────────────────────────────────────

  describe "String.Chars" do
    test "formats as AX25KISSInterface[name]" do
      iface = %AX25KISSInterface{name: "packet_radio"}
      assert to_string(iface) == "AX25KISSInterface[packet_radio]"
    end

    test "with different name" do
      iface = %AX25KISSInterface{name: "ax25_tnc"}
      assert to_string(iface) == "AX25KISSInterface[ax25_tnc]"
    end
  end

  # ── Interface behaviour ─────────────────────────────────────────

  describe "Interface behaviour" do
    test "detach/1 returns :ok" do
      state = %AX25KISSInterface{name: "test"}
      assert :ok = AX25KISSInterface.detach(state)
    end

    test "process_incoming strips AX.25 header" do
      test_pid = self()
      ax25_header = AX25KISSInterface.build_ax25_header("APZRNS", 0, "N0CALL", 0)
      payload = "test payload"

      state = %AX25KISSInterface{name: "test_in", owner: test_pid, rxb: 0}
      {:ok, updated} = AX25KISSInterface.process_incoming(state, ax25_header <> payload)

      assert updated.rxb == byte_size(ax25_header <> payload)
      assert_receive {:ax25_kiss_interface_data, ^payload, _}, 100
    end

    test "process_incoming ignores packets smaller than header" do
      state = %AX25KISSInterface{name: "test_small", owner: self(), rxb: 0}
      {:ok, updated} = AX25KISSInterface.process_incoming(state, <<1, 2, 3, 4, 5>>)
      # rxb should NOT be updated for ignored packets
      assert updated.rxb == 0
    end
  end

  # ── Reconnection ────────────────────────────────────────────────

  describe "reconnection" do
    test "schedules reconnect on port_closed message" do
      {:ok, pid} =
        AX25KISSInterface.start_link(
          name: "test_recon",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          skip_open: true
        )

      send(pid, {:port_closed, nil})
      Process.sleep(50)

      state = AX25KISSInterface.get_state(pid)
      assert state.online == false
      assert state.reconnecting == true

      GenServer.stop(pid)
    end
  end

  # ── server_name registration ────────────────────────────────────

  describe "server_name option" do
    test "registers with given name" do
      {:ok, _pid} =
        AX25KISSInterface.start_link(
          name: "test_named",
          port: "/dev/ttyTest",
          callsign: "N0CALL",
          ssid: 0,
          skip_open: true,
          server_name: :test_ax25_named
        )

      state = AX25KISSInterface.get_state(:test_ax25_named)
      assert state.name == "test_named"

      GenServer.stop(:test_ax25_named)
    end
  end
end
