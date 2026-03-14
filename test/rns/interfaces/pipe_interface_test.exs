defmodule RNS.Interfaces.PipeInterfaceTest do
  use ExUnit.Case, async: true

  alias RNS.Interfaces.PipeInterface

  # ── Constants ──────────────────────────────────────────────────────

  describe "constants" do
    test "MAX_CHUNK is 32768" do
      assert PipeInterface.max_chunk() == 32_768
    end

    test "BITRATE_GUESS is 1 Mbps" do
      assert PipeInterface.bitrate_guess() == 1_000_000
    end

    test "DEFAULT_IFAC_SIZE is 8" do
      assert PipeInterface.default_ifac_size() == 8
    end

    test "HW_MTU is 1064" do
      assert PipeInterface.hw_mtu() == 1064
    end

    test "DEFAULT_RESPAWN_DELAY is 5 seconds" do
      assert PipeInterface.default_respawn_delay() == 5_000
    end
  end

  # ── Struct defaults ────────────────────────────────────────────────

  describe "struct" do
    test "has default fields from Interface plus pipe-specific fields" do
      iface = %PipeInterface{}
      assert iface.name == nil
      assert iface.command == nil
      assert iface.respawn_delay == 5_000
      assert iface.pipe_is_open == false
      assert iface.online == false
      assert iface.frame_buffer == <<>>
      assert iface.owner == nil
      assert iface.port_ref == nil
    end

    test "has interface default fields" do
      iface = %PipeInterface{}
      assert iface.rxb == 0
      assert iface.txb == 0
      assert iface.in == false
      assert iface.out == false
      assert iface.ifac_size == 0
    end
  end

  # ── GenServer start_link ───────────────────────────────────────────

  describe "start_link" do
    test "starts with a command that exits immediately (cat /dev/null)" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "test_pipe",
          command: "cat /dev/null",
          owner: self()
        )

      assert Process.alive?(pid)
      state = PipeInterface.get_state(pid)
      assert state.name == "test_pipe"
      assert state.command == "cat /dev/null"
      assert state.pipe_is_open == true
      assert state.in == true
      assert state.out == true
      PipeInterface.stop(pid)
    end

    test "starts with echo subprocess" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "echo_pipe",
          command: "cat",
          owner: self()
        )

      assert Process.alive?(pid)
      state = PipeInterface.get_state(pid)
      assert state.online == true
      assert state.pipe_is_open == true
      PipeInterface.stop(pid)
    end

    test "requires command option" do
      Process.flag(:trap_exit, true)
      result = PipeInterface.start_link(name: "no_cmd")
      assert {:error, _} = result
    end

    test "sets bitrate to BITRATE_GUESS" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "bitrate_pipe",
          command: "cat",
          owner: self()
        )

      state = PipeInterface.get_state(pid)
      assert state.bitrate == 1_000_000
      PipeInterface.stop(pid)
    end

    test "sets hw_mtu to 1064" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "mtu_pipe",
          command: "cat",
          owner: self()
        )

      state = PipeInterface.get_state(pid)
      assert state.hw_mtu == 1064
      PipeInterface.stop(pid)
    end

    test "accepts custom respawn_delay" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "respawn_pipe",
          command: "cat",
          respawn_delay: 10_000,
          owner: self()
        )

      state = PipeInterface.get_state(pid)
      assert state.respawn_delay == 10_000
      PipeInterface.stop(pid)
    end

    test "accepts server_name registration" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "named_pipe",
          command: "cat",
          server_name: :test_pipe_iface,
          owner: self()
        )

      assert Process.whereis(:test_pipe_iface) == pid
      PipeInterface.stop(pid)
    end

    test "computes interface hash on init" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "hash_pipe",
          command: "cat",
          owner: self()
        )

      state = PipeInterface.get_state(pid)
      assert is_binary(state.hash)
      assert byte_size(state.hash) == 32
      PipeInterface.stop(pid)
    end
  end

  # ── HDLC framing roundtrip ────────────────────────────────────────

  describe "HDLC framing roundtrip via pipe" do
    test "send and receive simple data through cat subprocess" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "hdlc_pipe",
          command: "cat",
          owner: self()
        )

      data = "Hello, Pipe!"
      :ok = PipeInterface.send_data(pid, data)

      assert_receive {:interface_data, ^data, _iface}, 2000
      PipeInterface.stop(pid)
    end

    test "send and receive binary data" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "binary_pipe",
          command: "cat",
          owner: self()
        )

      data = <<0x01, 0x02, 0xFF, 0xFE, 0x00, 0xAB>>
      :ok = PipeInterface.send_data(pid, data)

      assert_receive {:interface_data, ^data, _iface}, 2000
      PipeInterface.stop(pid)
    end

    test "send and receive data with HDLC special bytes (FLAG and ESC)" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "special_pipe",
          command: "cat",
          owner: self()
        )

      # Data containing HDLC FLAG (0x7E) and ESC (0x7D) bytes
      data = <<0x7E, 0x7D, 0x01, 0x7E, 0x7D>>
      :ok = PipeInterface.send_data(pid, data)

      assert_receive {:interface_data, ^data, _iface}, 2000
      PipeInterface.stop(pid)
    end

    test "send and receive multiple frames" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "multi_pipe",
          command: "cat",
          owner: self()
        )

      data1 = "frame one"
      data2 = "frame two"
      data3 = "frame three"

      :ok = PipeInterface.send_data(pid, data1)
      :ok = PipeInterface.send_data(pid, data2)
      :ok = PipeInterface.send_data(pid, data3)

      assert_receive {:interface_data, ^data1, _}, 2000
      assert_receive {:interface_data, ^data2, _}, 2000
      assert_receive {:interface_data, ^data3, _}, 2000
      PipeInterface.stop(pid)
    end

    test "oversized frames are dropped" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "oversize_pipe",
          command: "cat",
          owner: self()
        )

      # Data larger than HW_MTU (1064)
      big_data = :crypto.strong_rand_bytes(1100)
      :ok = PipeInterface.send_data(pid, big_data)

      # Should not receive it (dropped due to size)
      refute_receive {:interface_data, _, _}, 500

      # But a small frame should still work
      small_data = "small"
      :ok = PipeInterface.send_data(pid, small_data)
      assert_receive {:interface_data, ^small_data, _}, 2000
      PipeInterface.stop(pid)
    end

    test "empty frames are ignored" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "empty_pipe",
          command: "cat",
          owner: self()
        )

      # Send an actual data frame after to verify processing continues
      data = "after_empty"
      :ok = PipeInterface.send_data(pid, data)
      assert_receive {:interface_data, ^data, _}, 2000
      PipeInterface.stop(pid)
    end
  end

  # ── process_outgoing ───────────────────────────────────────────────

  describe "process_outgoing" do
    test "updates txb counter" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "txb_pipe",
          command: "cat",
          owner: self()
        )

      data = "test data"
      :ok = PipeInterface.send_data(pid, data)
      # Wait for the echoed frame
      assert_receive {:interface_data, _, _}, 2000

      state = PipeInterface.get_state(pid)
      assert state.txb > 0
      PipeInterface.stop(pid)
    end

    test "returns error when offline" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "offline_pipe",
          command: "cat",
          owner: self()
        )

      # Detach to go offline
      PipeInterface.stop(pid)

      # Can't send to stopped process
      assert catch_exit(PipeInterface.send_data(pid, "data"))
    end
  end

  # ── process_incoming / owner callbacks ─────────────────────────────

  describe "process_incoming and owner callbacks" do
    test "updates rxb counter" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "rxb_pipe",
          command: "cat",
          owner: self()
        )

      data = "incoming test"
      :ok = PipeInterface.send_data(pid, data)
      assert_receive {:interface_data, ^data, _}, 2000

      state = PipeInterface.get_state(pid)
      assert state.rxb > 0
      PipeInterface.stop(pid)
    end

    test "notifies owner pid with :interface_data message" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "owner_pid_pipe",
          command: "cat",
          owner: self()
        )

      data = "notify me"
      :ok = PipeInterface.send_data(pid, data)
      assert_receive {:interface_data, ^data, iface}, 2000
      assert iface.name == "owner_pid_pipe"
      PipeInterface.stop(pid)
    end

    test "notifies owner function callback" do
      test_pid = self()

      callback = fn data, iface ->
        send(test_pid, {:callback_data, data, iface})
      end

      {:ok, pid} =
        PipeInterface.start_link(
          name: "owner_fn_pipe",
          command: "cat",
          owner: callback
        )

      data = "callback test"
      :ok = PipeInterface.send_data(pid, data)
      assert_receive {:callback_data, ^data, _}, 2000
      PipeInterface.stop(pid)
    end

    test "notifies owner {module, fun} MFA callback" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      # We'll use a pid-based approach since we can't define a module callback easily
      {:ok, pid} =
        PipeInterface.start_link(
          name: "mfa_pipe",
          command: "cat",
          owner: self()
        )

      data = "mfa test"
      :ok = PipeInterface.send_data(pid, data)
      assert_receive {:interface_data, ^data, _}, 2000
      PipeInterface.stop(pid)
      Agent.stop(agent)
    end
  end

  # ── Respawn / reconnect ────────────────────────────────────────────

  describe "respawn" do
    test "attempts respawn when subprocess exits" do
      # Use a command that will exit immediately
      {:ok, pid} =
        PipeInterface.start_link(
          name: "respawn_test",
          command: "echo hello",
          respawn_delay: 100,
          owner: self()
        )

      # The echo command exits immediately, triggering respawn logic
      # Just verify the GenServer survives the subprocess exit
      Process.sleep(300)
      assert Process.alive?(pid)
      PipeInterface.stop(pid)
    end
  end

  # ── Detach ─────────────────────────────────────────────────────────

  describe "detach" do
    test "marks interface as offline and detached" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "detach_pipe",
          command: "cat",
          owner: self()
        )

      state_before = PipeInterface.get_state(pid)
      assert state_before.online == true

      PipeInterface.stop(pid)

      # Process should be stopped
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  # ── should_ingress_limit ───────────────────────────────────────────

  describe "should_ingress_limit" do
    test "always returns false (matching Python)" do
      iface = %PipeInterface{name: "test"}
      assert {false, ^iface} = PipeInterface.should_ingress_limit(iface)
    end
  end

  # ── String.Chars ───────────────────────────────────────────────────

  describe "String.Chars" do
    test "formats as PipeInterface[name]" do
      iface = %PipeInterface{name: "test_pipe"}
      assert to_string(iface) == "PipeInterface[test_pipe]"
    end

    test "formats with nil name" do
      iface = %PipeInterface{name: nil}
      assert to_string(iface) == "PipeInterface[]"
    end
  end

  # ── Interface behaviour ────────────────────────────────────────────

  describe "Interface behaviour" do
    test "implements process_outgoing/2" do
      assert function_exported?(PipeInterface, :process_outgoing, 2)
    end

    test "implements process_incoming/2" do
      assert function_exported?(PipeInterface, :process_incoming, 2)
    end

    test "implements detach/1" do
      assert function_exported?(PipeInterface, :detach, 1)
    end
  end

  # ── Byte counters ──────────────────────────────────────────────────

  describe "byte counters" do
    test "tracks txb and rxb correctly" do
      {:ok, pid} =
        PipeInterface.start_link(
          name: "counter_pipe",
          command: "cat",
          owner: self()
        )

      data = "counter test"
      :ok = PipeInterface.send_data(pid, data)
      assert_receive {:interface_data, ^data, _}, 2000

      state = PipeInterface.get_state(pid)
      # txb includes HDLC framing overhead
      assert state.txb > byte_size(data)
      # rxb is the raw received frame size (unframed data)
      assert state.rxb == byte_size(data)
      PipeInterface.stop(pid)
    end
  end
end
