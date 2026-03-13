defmodule RNS.Interfaces.SerialInterfaceTest do
  use ExUnit.Case, async: false

  alias RNS.Interfaces.Interface.HDLC
  alias RNS.Interfaces.SerialInterface

  # ── Constants ──────────────────────────────────────────────────

  describe "constants" do
    test "max_chunk is 32768" do
      assert SerialInterface.max_chunk() == 32_768
    end

    test "default_ifac_size is 8" do
      assert SerialInterface.default_ifac_size() == 8
    end

    test "hw_mtu is 564" do
      assert SerialInterface.hw_mtu() == 564
    end

    test "reconnect_wait is 5000ms" do
      assert SerialInterface.reconnect_wait() == 5_000
    end
  end

  # ── Struct fields ──────────────────────────────────────────────

  describe "struct" do
    test "has default interface fields" do
      iface = %SerialInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.online == false
      assert iface.bitrate == 62_500
      assert iface.mode == RNS.Interfaces.Interface.mode_full()
    end

    test "has serial-specific fields with defaults" do
      iface = %SerialInterface{}
      assert iface.port == nil
      assert iface.speed == 9600
      assert iface.databits == 8
      assert iface.parity == :none
      assert iface.stopbits == 1
      assert iface.timeout == 100
      assert iface.uart_pid == nil
      assert iface.port_ref == nil
      assert iface.frame_buffer == <<>>
      assert iface.reconnecting == false
      assert iface.owner == nil
      assert iface.skip_open == false
    end
  end

  # ── Parity parsing ─────────────────────────────────────────────

  describe "parse_parity/1" do
    test "parses none variants" do
      assert SerialInterface.parse_parity("N") == :none
      assert SerialInterface.parse_parity("n") == :none
      assert SerialInterface.parse_parity("none") == :none
      assert SerialInterface.parse_parity("NONE") == :none
    end

    test "parses even variants" do
      assert SerialInterface.parse_parity("E") == :even
      assert SerialInterface.parse_parity("e") == :even
      assert SerialInterface.parse_parity("even") == :even
      assert SerialInterface.parse_parity("EVEN") == :even
      assert SerialInterface.parse_parity("Even") == :even
    end

    test "parses odd variants" do
      assert SerialInterface.parse_parity("O") == :odd
      assert SerialInterface.parse_parity("o") == :odd
      assert SerialInterface.parse_parity("odd") == :odd
      assert SerialInterface.parse_parity("ODD") == :odd
    end

    test "defaults to none for unknown" do
      assert SerialInterface.parse_parity("X") == :none
      assert SerialInterface.parse_parity("") == :none
      assert SerialInterface.parse_parity("mark") == :none
    end

    test "handles non-string input" do
      assert SerialInterface.parse_parity(nil) == :none
      assert SerialInterface.parse_parity(42) == :none
    end
  end

  # ── GenServer lifecycle with skip_open ──────────────────────────

  describe "start_link/1 with skip_open" do
    test "starts successfully without hardware" do
      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_serial",
          port: "/dev/ttyUSB0",
          skip_open: true
        )

      state = SerialInterface.get_state(pid)
      assert state.name == "test_serial"
      assert state.port == "/dev/ttyUSB0"
      assert state.online == true
      assert state.speed == 9600
      assert state.databits == 8
      assert state.parity == :none
      assert state.stopbits == 1
      assert state.bitrate == 9600
      assert state.hw_mtu == 564
      assert state.ifac_size == 8
      assert is_binary(state.hash)

      GenServer.stop(pid)
    end

    test "starts with custom serial parameters" do
      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_custom",
          port: "/dev/ttyS0",
          speed: 115_200,
          databits: 7,
          parity: "E",
          stopbits: 2,
          skip_open: true
        )

      state = SerialInterface.get_state(pid)
      assert state.speed == 115_200
      assert state.databits == 7
      assert state.parity == :even
      assert state.stopbits == 2
      assert state.bitrate == 115_200

      GenServer.stop(pid)
    end

    test "starts with atom parity" do
      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_atom_parity",
          port: "/dev/ttyS0",
          parity: :odd,
          skip_open: true
        )

      state = SerialInterface.get_state(pid)
      assert state.parity == :odd

      GenServer.stop(pid)
    end

    test "starts with owner pid" do
      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_with_owner",
          port: "/dev/ttyUSB0",
          owner: self(),
          skip_open: true
        )

      state = SerialInterface.get_state(pid)
      assert state.owner == self()

      GenServer.stop(pid)
    end

    test "fails without port when not skipping open" do
      Process.flag(:trap_exit, true)

      result =
        SerialInterface.start_link(name: "test_no_port")

      assert {:error, {:error, :no_port_specified}} = result
    end
  end

  # ── HDLC framing roundtrip ─────────────────────────────────────

  describe "HDLC framing roundtrip via serial interface" do
    test "simple data roundtrip" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_hdlc_rt",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Simulate receiving an HDLC-framed packet
      original = "Hello serial world"
      framed = HDLC.frame(original)

      # Inject the framed data as if it came from the serial port
      send(pid, {:serial_data, framed})

      assert_receive {:serial_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end

    test "binary data roundtrip" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_hdlc_bin",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      original = :crypto.strong_rand_bytes(100)
      framed = HDLC.frame(original)

      send(pid, {:serial_data, framed})

      assert_receive {:serial_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end

    test "data with HDLC special bytes" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_hdlc_special",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Data containing FLAG (0x7E) and ESC (0x7D) bytes
      original = <<0x7E, 0x7D, 0x00, 0xFF, 0x7E, 0x7D, 0x5E, 0x5D>>
      framed = HDLC.frame(original)

      send(pid, {:serial_data, framed})

      assert_receive {:serial_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end

    test "multiple frames in single delivery" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_hdlc_multi",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      msg1 = "first message"
      msg2 = "second message"
      msg3 = "third message"

      # Send all frames concatenated (as might happen with buffered serial)
      combined = HDLC.frame(msg1) <> HDLC.frame(msg2) <> HDLC.frame(msg3)
      send(pid, {:serial_data, combined})

      assert_receive {:serial_interface_data, ^msg1, _}, 1000
      assert_receive {:serial_interface_data, ^msg2, _}, 1000
      assert_receive {:serial_interface_data, ^msg3, _}, 1000

      GenServer.stop(pid)
    end

    test "fragmented frame delivery" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_hdlc_frag",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      original = "fragmented frame test"
      framed = HDLC.frame(original)

      # Split the frame into parts and deliver separately
      mid = div(byte_size(framed), 2)
      part1 = binary_part(framed, 0, mid)
      part2 = binary_part(framed, mid, byte_size(framed) - mid)

      send(pid, {:serial_data, part1})
      # Small delay to ensure first message is processed
      Process.sleep(10)
      send(pid, {:serial_data, part2})

      assert_receive {:serial_interface_data, ^original, _iface}, 1000

      GenServer.stop(pid)
    end

    test "empty frames are ignored" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_hdlc_empty",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Empty frame (consecutive flags) followed by a real frame
      real_msg = "after empty"
      data = <<0x7E, 0x7E>> <> HDLC.frame(real_msg)
      send(pid, {:serial_data, data})

      assert_receive {:serial_interface_data, ^real_msg, _}, 1000
      refute_receive {:serial_interface_data, <<>>, _}, 100

      GenServer.stop(pid)
    end

    test "oversized frames are dropped" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_hdlc_oversize",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      # Create frame larger than HW_MTU (564)
      oversized = :crypto.strong_rand_bytes(600)
      framed_oversized = HDLC.frame(oversized)

      valid_msg = "valid"
      framed_valid = HDLC.frame(valid_msg)

      send(pid, {:serial_data, framed_oversized <> framed_valid})

      # Should only receive the valid message, not the oversized one
      assert_receive {:serial_interface_data, ^valid_msg, _}, 1000
      refute_receive {:serial_interface_data, ^oversized, _}, 100

      GenServer.stop(pid)
    end
  end

  # ── process_outgoing ────────────────────────────────────────────

  describe "process_outgoing/2" do
    test "returns error when offline" do
      state = %SerialInterface{name: "offline_test", online: false}
      assert {:error, :offline} = SerialInterface.process_outgoing(state, "test")
    end

    test "HDLC-frames data for transmission" do
      state = %SerialInterface{name: "tx_test", online: true, skip_open: true}
      {:ok, updated} = SerialInterface.process_outgoing(state, "outgoing data")
      # txb should include the HDLC framing overhead
      framed = HDLC.frame("outgoing data")
      assert updated.txb == byte_size(framed)
    end
  end

  # ── Byte counter tracking ──────────────────────────────────────

  describe "byte counters" do
    test "rxb accumulates on incoming data" do
      test_pid = self()

      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_rxb",
          port: "/dev/ttyTest",
          owner: test_pid,
          skip_open: true
        )

      msg1 = "hello"
      msg2 = "world!"
      send(pid, {:serial_data, HDLC.frame(msg1)})
      assert_receive {:serial_interface_data, ^msg1, _}, 1000

      send(pid, {:serial_data, HDLC.frame(msg2)})
      assert_receive {:serial_interface_data, ^msg2, _}, 1000

      state = SerialInterface.get_state(pid)
      assert state.rxb == byte_size(msg1) + byte_size(msg2)

      GenServer.stop(pid)
    end
  end

  # ── Detach ─────────────────────────────────────────────────────

  describe "detach" do
    test "marks interface offline and detached" do
      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_detach",
          port: "/dev/ttyTest",
          skip_open: true
        )

      state_before = SerialInterface.get_state(pid)
      assert state_before.online == true

      :ok = SerialInterface.stop(pid)

      state_after = SerialInterface.get_state(pid)
      assert state_after.online == false
      assert state_after.detached == true

      GenServer.stop(pid)
    end
  end

  # ── should_ingress_limit ────────────────────────────────────────

  describe "should_ingress_limit/1" do
    test "always returns false" do
      state = %SerialInterface{name: "test_limit"}
      assert {false, ^state} = SerialInterface.should_ingress_limit(state)
    end
  end

  # ── String.Chars ────────────────────────────────────────────────

  describe "String.Chars" do
    test "formats as SerialInterface[name]" do
      iface = %SerialInterface{name: "ttyUSB0"}
      assert to_string(iface) == "SerialInterface[ttyUSB0]"
    end

    test "with different name" do
      iface = %SerialInterface{name: "serial0"}
      assert to_string(iface) == "SerialInterface[serial0]"
    end
  end

  # ── Interface behaviour ─────────────────────────────────────────

  describe "Interface behaviour" do
    test "process_incoming/2 updates rxb and notifies owner" do
      test_pid = self()

      state = %SerialInterface{
        name: "test_incoming",
        owner: test_pid,
        rxb: 0
      }

      {:ok, updated} = SerialInterface.process_incoming(state, "incoming_data")
      assert updated.rxb == byte_size("incoming_data")

      assert_receive {:serial_interface_data, "incoming_data", _}, 100
    end

    test "process_incoming/2 with function callback" do
      test_pid = self()

      callback = fn data, _iface ->
        send(test_pid, {:callback_received, data})
      end

      state = %SerialInterface{
        name: "test_fn_callback",
        owner: callback,
        rxb: 0
      }

      {:ok, _updated} = SerialInterface.process_incoming(state, "fn_test_data")
      assert_receive {:callback_received, "fn_test_data"}, 100
    end

    test "process_incoming/2 with MFA callback" do
      state = %SerialInterface{
        name: "test_mfa",
        owner: {RNS.Interfaces.SerialInterfaceTest.Helper, :handle},
        rxb: 0
      }

      # This just tests it doesn't crash - the MFA module doesn't need to exist
      # for the pattern match to work, but it will raise if the module doesn't exist.
      # In production, the module would be the Transport module.
      assert_raise UndefinedFunctionError, fn ->
        SerialInterface.process_incoming(state, "mfa_data")
      end
    end
  end

  # ── Reconnection ────────────────────────────────────────────────

  describe "reconnection" do
    test "schedules reconnect on port_closed message" do
      {:ok, pid} =
        SerialInterface.start_link(
          name: "test_reconnect",
          port: "/dev/ttyTest",
          skip_open: true
        )

      # Simulate port closure
      send(pid, {:port_closed, nil})

      # Give it a moment to process
      Process.sleep(50)

      state = SerialInterface.get_state(pid)
      assert state.online == false
      assert state.reconnecting == true

      GenServer.stop(pid)
    end
  end

  # ── server_name registration ────────────────────────────────────

  describe "server_name option" do
    test "registers with given name" do
      {:ok, _pid} =
        SerialInterface.start_link(
          name: "test_named_serial",
          port: "/dev/ttyTest",
          skip_open: true,
          server_name: :test_serial_named
        )

      state = SerialInterface.get_state(:test_serial_named)
      assert state.name == "test_named_serial"

      GenServer.stop(:test_serial_named)
    end
  end

  # ── circuits_uart availability ──────────────────────────────────

  describe "circuits_uart_available?/0" do
    test "returns a boolean" do
      result = SerialInterface.circuits_uart_available?()
      assert is_boolean(result)
    end
  end
end
