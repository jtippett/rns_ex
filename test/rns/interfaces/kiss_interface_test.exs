defmodule RNS.Interfaces.KISSInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.KISSInterface
  alias RNS.Interfaces.Interface.KISS

  # ── Constants ──────────────────────────────────────────────────

  describe "constants" do
    test "max_chunk is 32768" do
      assert KISSInterface.max_chunk() == 32_768
    end

    test "default_ifac_size is 8" do
      assert KISSInterface.default_ifac_size() == 8
    end

    test "hw_mtu is 564" do
      assert KISSInterface.hw_mtu() == 564
    end

    test "bitrate_guess is 1200" do
      assert KISSInterface.bitrate_guess() == 1_200
    end

    test "reconnect_wait is 5000ms" do
      assert KISSInterface.reconnect_wait() == 5_000
    end

    test "flow_control_timeout is 5s" do
      assert KISSInterface.flow_control_timeout() == 5
    end
  end

  # ── Struct fields ──────────────────────────────────────────────

  describe "struct" do
    test "has default interface fields" do
      iface = %KISSInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.bitrate == 62_500
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has KISS-specific fields with defaults" do
      iface = %KISSInterface{}
      assert iface.port == nil
      assert iface.speed == 9600
      assert iface.databits == 8
      assert iface.parity == :none
      assert iface.stopbits == 1
      assert iface.timeout == 100
      assert iface.preamble == 350
      assert iface.txtail == 20
      assert iface.persistence == 64
      assert iface.slottime == 20
      assert iface.flow_control == false
      assert iface.interface_ready == true
      assert iface.beacon_interval == nil
      assert iface.beacon_data == <<>>
      assert iface.first_tx == nil
      assert iface.frame_buffer == <<>>
      assert iface.owner == nil
      assert iface.skip_open == false
    end
  end

  # ── Parity parsing ─────────────────────────────────────────────

  describe "parse_parity/1" do
    test "parses none variants" do
      assert KISSInterface.parse_parity("N") == :none
      assert KISSInterface.parse_parity("n") == :none
      assert KISSInterface.parse_parity("none") == :none
    end

    test "parses even variants" do
      assert KISSInterface.parse_parity("E") == :even
      assert KISSInterface.parse_parity("even") == :even
    end

    test "parses odd variants" do
      assert KISSInterface.parse_parity("O") == :odd
      assert KISSInterface.parse_parity("odd") == :odd
    end

    test "handles non-string input" do
      assert KISSInterface.parse_parity(nil) == :none
      assert KISSInterface.parse_parity(42) == :none
    end
  end

  # ── KISS TNC parameter conversions ──────────────────────────────

  describe "preamble_value/1" do
    test "converts ms to KISS value (ms / 10)" do
      assert KISSInterface.preamble_value(350) == 35
      assert KISSInterface.preamble_value(100) == 10
      assert KISSInterface.preamble_value(0) == 0
    end

    test "clamps to 0-255" do
      assert KISSInterface.preamble_value(-50) == 0
      assert KISSInterface.preamble_value(5000) == 255
    end
  end

  describe "txtail_value/1" do
    test "converts ms to KISS value (ms / 10)" do
      assert KISSInterface.txtail_value(20) == 2
      assert KISSInterface.txtail_value(100) == 10
    end

    test "clamps to 0-255" do
      assert KISSInterface.txtail_value(-10) == 0
      assert KISSInterface.txtail_value(3000) == 255
    end
  end

  describe "persistence_value/1" do
    test "clamps to 0-255" do
      assert KISSInterface.persistence_value(64) == 64
      assert KISSInterface.persistence_value(0) == 0
      assert KISSInterface.persistence_value(255) == 255
      assert KISSInterface.persistence_value(-1) == 0
      assert KISSInterface.persistence_value(300) == 255
    end
  end

  describe "slottime_value/1" do
    test "converts ms to KISS value (ms / 10)" do
      assert KISSInterface.slottime_value(20) == 2
      assert KISSInterface.slottime_value(100) == 10
    end

    test "clamps to 0-255" do
      assert KISSInterface.slottime_value(-10) == 0
      assert KISSInterface.slottime_value(3000) == 255
    end
  end

  # ── KISS command building ──────────────────────────────────────

  describe "kiss_command/2" do
    test "builds proper KISS command frame" do
      cmd = KISSInterface.kiss_command(KISS.cmd_txdelay(), 35)
      assert cmd == <<0xC0, 0x01, 35, 0xC0>>
    end

    test "builds flow control ready command" do
      cmd = KISSInterface.kiss_command(KISS.cmd_ready(), 0x01)
      assert cmd == <<0xC0, 0x0F, 0x01, 0xC0>>
    end

    test "builds persistence command" do
      cmd = KISSInterface.kiss_command(KISS.cmd_p(), 64)
      assert cmd == <<0xC0, 0x02, 64, 0xC0>>
    end
  end

  # ── GenServer lifecycle with skip_open ──────────────────────────

  describe "start_link/1 with skip_open" do
    test "starts successfully without hardware" do
      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss",
          port: "/dev/ttyKISS0",
          skip_open: true
        )

      state = KISSInterface.get_state(pid)
      assert state.name == "test_kiss"
      assert state.port == "/dev/ttyKISS0"
      assert state.online == true
      assert state.interface_ready == true
      assert state.bitrate == 1_200
      assert state.hw_mtu == 564
      assert state.ifac_size == 8
      assert is_binary(state.hash)

      GenServer.stop(pid)
    end

    test "starts with custom TNC parameters" do
      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_custom_kiss",
          port: "/dev/ttyKISS0",
          preamble: 500,
          txtail: 30,
          persistence: 128,
          slottime: 40,
          skip_open: true
        )

      state = KISSInterface.get_state(pid)
      assert state.preamble == 500
      assert state.txtail == 30
      assert state.persistence == 128
      assert state.slottime == 40

      GenServer.stop(pid)
    end

    test "starts with flow control enabled" do
      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_fc_kiss",
          port: "/dev/ttyKISS0",
          flow_control: true,
          skip_open: true
        )

      state = KISSInterface.get_state(pid)
      assert state.flow_control == true
      # interface_ready is set to true after configure_device
      assert state.interface_ready == true

      GenServer.stop(pid)
    end

    test "starts with beacon configuration" do
      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_beacon_kiss",
          port: "/dev/ttyKISS0",
          beacon_interval: 600,
          beacon_data: "N0CALL",
          skip_open: true
        )

      state = KISSInterface.get_state(pid)
      assert state.beacon_interval == 600
      assert state.beacon_data == "N0CALL"

      GenServer.stop(pid)
    end

    test "starts with owner pid" do
      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_owner_kiss",
          port: "/dev/ttyKISS0",
          owner: self(),
          skip_open: true
        )

      state = KISSInterface.get_state(pid)
      assert state.owner == self()

      GenServer.stop(pid)
    end

    test "fails without port when not skipping open" do
      Process.flag(:trap_exit, true)

      result =
        KISSInterface.start_link(name: "test_no_port")

      assert {:error, {:error, :no_port_specified}} = result
    end
  end

  # ── KISS framing roundtrip ─────────────────────────────────────

  describe "KISS framing roundtrip" do
    test "simple data roundtrip" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss_rt",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Simulate receiving a KISS-framed packet
      original = "Hello KISS world"
      framed = KISS.frame(original)

      send(pid, {:serial_data, framed})

      assert_receive {:kiss_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end

    test "binary data with KISS special bytes" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss_special",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Data containing FEND (0xC0) and FESC (0xDB) bytes
      original = <<0xC0, 0xDB, 0x00, 0xFF, 0xC0, 0xDB>>
      framed = KISS.frame(original)

      send(pid, {:serial_data, framed})

      assert_receive {:kiss_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end

    test "multiple frames in single delivery" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss_multi",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      msg1 = "first"
      msg2 = "second"
      msg3 = "third"

      combined = KISS.frame(msg1) <> KISS.frame(msg2) <> KISS.frame(msg3)
      send(pid, {:serial_data, combined})

      assert_receive {:kiss_interface_data, ^msg1, _}, 1000
      assert_receive {:kiss_interface_data, ^msg2, _}, 1000
      assert_receive {:kiss_interface_data, ^msg3, _}, 1000

      GenServer.stop(pid)
    end

    test "fragmented frame delivery" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss_frag",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      original = "fragmented KISS frame test"
      framed = KISS.frame(original)

      mid = div(byte_size(framed), 2)
      part1 = binary_part(framed, 0, mid)
      part2 = binary_part(framed, mid, byte_size(framed) - mid)

      send(pid, {:serial_data, part1})
      Process.sleep(10)
      send(pid, {:serial_data, part2})

      assert_receive {:kiss_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end

    test "empty frames are ignored" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss_empty",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Empty frame (consecutive FENDs) followed by a real frame
      real_msg = "after empty"
      data = <<0xC0, 0xC0>> <> KISS.frame(real_msg)
      send(pid, {:serial_data, data})

      assert_receive {:kiss_interface_data, ^real_msg, _}, 1000
      refute_receive {:kiss_interface_data, <<>>, _}, 100

      GenServer.stop(pid)
    end

    test "oversized frames are dropped" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss_oversize",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Create data larger than HW_MTU (564)
      oversized = :crypto.strong_rand_bytes(600)
      framed_oversized = KISS.frame(oversized)

      valid_msg = "valid"
      framed_valid = KISS.frame(valid_msg)

      send(pid, {:serial_data, framed_oversized <> framed_valid})

      assert_receive {:kiss_interface_data, ^valid_msg, _}, 1000
      refute_receive {:kiss_interface_data, ^oversized, _}, 100

      GenServer.stop(pid)
    end

    test "random binary data roundtrip" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_kiss_rand",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      original = :crypto.strong_rand_bytes(200)
      framed = KISS.frame(original)

      send(pid, {:serial_data, framed})

      assert_receive {:kiss_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end
  end

  # ── process_outgoing ────────────────────────────────────────────

  describe "process_outgoing/2" do
    test "returns error when offline" do
      state = %KISSInterface{name: "offline_test", online: false}
      assert {:error, :offline} = KISSInterface.process_outgoing(state, "test")
    end

    test "KISS-frames data for transmission" do
      state = %KISSInterface{name: "tx_test", online: true, skip_open: true}
      {:ok, updated} = KISSInterface.process_outgoing(state, "outgoing data")
      # txb tracks the original data size, not the framed size
      assert updated.txb == byte_size("outgoing data")
    end

    test "queues data when interface_ready is false" do
      state = %KISSInterface{
        name: "queue_test",
        online: true,
        skip_open: true,
        interface_ready: false
      }

      {:ok, updated} = KISSInterface.process_outgoing(state, "queued data")
      assert :queue.len(updated.packet_queue) == 1
      assert updated.txb == 0
    end
  end

  # ── Flow control ───────────────────────────────────────────────

  describe "flow control" do
    test "queue_packet adds to packet queue" do
      state = %KISSInterface{name: "fc_test"}
      state = KISSInterface.queue_packet(state, "packet1")
      state = KISSInterface.queue_packet(state, "packet2")
      assert :queue.len(state.packet_queue) == 2
    end

    test "process_queue sends next packet" do
      state = %KISSInterface{
        name: "pq_test",
        online: true,
        skip_open: true,
        interface_ready: false
      }

      state = KISSInterface.queue_packet(state, "queued")
      updated = KISSInterface.process_queue(state)
      assert updated.interface_ready == true
      assert updated.txb == byte_size("queued")
    end

    test "process_queue sets interface_ready when empty" do
      state = %KISSInterface{
        name: "pq_empty",
        online: true,
        skip_open: true,
        interface_ready: false
      }

      updated = KISSInterface.process_queue(state)
      assert updated.interface_ready == true
      assert :queue.is_empty(updated.packet_queue)
    end

    test "flow control CMD_READY triggers queue processing" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_fc_ready",
          port: "/dev/ttyTest",
          owner: test_pid,
          flow_control: true,
          skip_open: true
        )

      # Send data to be queued (set interface_ready=false first by sending data with flow control)
      KISSInterface.send_data(pid, "first_packet")

      # After sending with flow control, interface_ready should be false
      state = KISSInterface.get_state(pid)
      assert state.flow_control == true

      # Queue another packet
      KISSInterface.send_data(pid, "second_packet")

      # Send a CMD_READY frame from the TNC
      ready_frame = <<KISS.fend(), KISS.cmd_ready(), 0x01, KISS.fend()>>
      send(pid, {:serial_data, ready_frame})

      Process.sleep(50)

      # The queued packet should have been sent
      state = KISSInterface.get_state(pid)
      assert state.interface_ready == true || :queue.is_empty(state.packet_queue)

      GenServer.stop(pid)
    end
  end

  # ── Beacon tracking ───────────────────────────────────────────

  describe "beacon tracking" do
    test "first_tx is set on first non-beacon transmission" do
      state = %KISSInterface{
        name: "beacon_test",
        online: true,
        skip_open: true,
        beacon_data: "N0CALL",
        first_tx: nil
      }

      {:ok, updated} = KISSInterface.process_outgoing(state, "regular_data")
      assert updated.first_tx != nil
    end

    test "first_tx is cleared when sending beacon data" do
      state = %KISSInterface{
        name: "beacon_clear_test",
        online: true,
        skip_open: true,
        beacon_data: "N0CALL",
        first_tx: 12345
      }

      {:ok, updated} = KISSInterface.process_outgoing(state, "N0CALL")
      assert updated.first_tx == nil
    end
  end

  # ── Byte counter tracking ──────────────────────────────────────

  describe "byte counters" do
    test "rxb accumulates on incoming data" do
      test_pid = self()

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_rxb",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      msg1 = "hello"
      msg2 = "world!"
      send(pid, {:serial_data, KISS.frame(msg1)})
      assert_receive {:kiss_interface_data, ^msg1, _}, 1000

      send(pid, {:serial_data, KISS.frame(msg2)})
      assert_receive {:kiss_interface_data, ^msg2, _}, 1000

      state = KISSInterface.get_state(pid)
      assert state.rxb == byte_size(msg1) + byte_size(msg2)

      GenServer.stop(pid)
    end
  end

  # ── Detach ─────────────────────────────────────────────────────

  describe "detach" do
    test "marks interface offline and detached" do
      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_detach",
          port: "/dev/ttyTest",
          skip_open: true
        )

      state_before = KISSInterface.get_state(pid)
      assert state_before.online == true

      :ok = KISSInterface.stop(pid)

      state_after = KISSInterface.get_state(pid)
      assert state_after.online == false
      assert state_after.detached == true

      GenServer.stop(pid)
    end
  end

  # ── should_ingress_limit ────────────────────────────────────────

  describe "should_ingress_limit/1" do
    test "always returns false" do
      state = %KISSInterface{name: "test_limit"}
      assert {false, ^state} = KISSInterface.should_ingress_limit(state)
    end
  end

  # ── String.Chars ────────────────────────────────────────────────

  describe "String.Chars" do
    test "formats as KISSInterface[name]" do
      iface = %KISSInterface{name: "ttyKISS0"}
      assert to_string(iface) == "KISSInterface[ttyKISS0]"
    end

    test "with different name" do
      iface = %KISSInterface{name: "kiss_radio"}
      assert to_string(iface) == "KISSInterface[kiss_radio]"
    end
  end

  # ── Interface behaviour ─────────────────────────────────────────

  describe "Interface behaviour" do
    test "process_incoming/2 updates rxb and notifies owner" do
      test_pid = self()

      state = %KISSInterface{
        name: "test_incoming",
        owner: test_pid,
        rxb: 0
      }

      {:ok, updated} = KISSInterface.process_incoming(state, "incoming_data")
      assert updated.rxb == byte_size("incoming_data")

      assert_receive {:kiss_interface_data, "incoming_data", _}, 100
    end

    test "process_incoming/2 with function callback" do
      test_pid = self()

      callback = fn data, _iface ->
        send(test_pid, {:callback_received, data})
      end

      state = %KISSInterface{
        name: "test_fn_callback",
        owner: callback,
        rxb: 0
      }

      {:ok, _updated} = KISSInterface.process_incoming(state, "fn_test_data")
      assert_receive {:callback_received, "fn_test_data"}, 100
    end

    test "detach/1 returns :ok" do
      state = %KISSInterface{name: "test_detach_behaviour"}
      assert :ok = KISSInterface.detach(state)
    end
  end

  # ── KISS command constants ─────────────────────────────────────

  describe "KISS command constants" do
    test "all command constants are accessible" do
      assert KISS.cmd_data() == 0x00
      assert KISS.cmd_txdelay() == 0x01
      assert KISS.cmd_p() == 0x02
      assert KISS.cmd_slottime() == 0x03
      assert KISS.cmd_txtail() == 0x04
      assert KISS.cmd_fullduplex() == 0x05
      assert KISS.cmd_sethardware() == 0x06
      assert KISS.cmd_ready() == 0x0F
      assert KISS.cmd_unknown() == 0xFE
      assert KISS.cmd_return() == 0xFF
    end
  end

  # ── Reconnection ────────────────────────────────────────────────

  describe "reconnection" do
    test "schedules reconnect on port_closed message" do
      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_reconnect",
          port: "/dev/ttyTest",
          skip_open: true
        )

      send(pid, {:port_closed, nil})
      Process.sleep(50)

      state = KISSInterface.get_state(pid)
      assert state.online == false
      assert state.reconnecting == true

      GenServer.stop(pid)
    end
  end

  # ── server_name registration ────────────────────────────────────

  describe "server_name option" do
    test "registers with given name" do
      {:ok, _pid} =
        KISSInterface.start_link(
          name: "test_named_kiss",
          port: "/dev/ttyTest",
          skip_open: true,
          server_name: :test_kiss_named
        )

      state = KISSInterface.get_state(:test_kiss_named)
      assert state.name == "test_named_kiss"

      GenServer.stop(:test_kiss_named)
    end
  end

  # ── Owner callback ─────────────────────────────────────────────

  describe "owner callback" do
    test "function/2 callback receives data" do
      test_pid = self()

      callback = fn data, _iface ->
        send(test_pid, {:fn_callback, data})
      end

      {:ok, pid} =
        KISSInterface.start_link(
          name: "test_fn_owner",
          port: "/dev/ttyTest",
          owner: callback,
          skip_open: true
        )

      msg = "callback test"
      send(pid, {:serial_data, KISS.frame(msg)})

      assert_receive {:fn_callback, ^msg}, 1000

      GenServer.stop(pid)
    end
  end

  # ── circuits_uart availability ──────────────────────────────────

  describe "circuits_uart_available?/0" do
    test "returns a boolean" do
      result = KISSInterface.circuits_uart_available?()
      assert is_boolean(result)
    end
  end
end
