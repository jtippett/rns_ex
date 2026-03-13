defmodule RNS.Utilities.RNSDTest do
  @moduledoc """
  Tests for the rnsd daemon utility.

  Tests argument parsing, example config output, version output,
  and daemon start/stop lifecycle.
  """

  use ExUnit.Case, async: true

  alias RNS.Utilities.RNSD

  # ── Argument Parsing ──────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNSD.parse_args([])

      assert opts.configdir == nil
      assert opts.verbosity == 0
      assert opts.quietness == 0
      assert opts.service == false
      assert opts.exampleconfig == false
      assert opts.version == false
    end

    test "parses --config option" do
      assert {:ok, opts} = RNSD.parse_args(["--config", "/tmp/test_reticulum"])
      assert opts.configdir == "/tmp/test_reticulum"
    end

    test "parses -v verbose flag (single)" do
      assert {:ok, opts} = RNSD.parse_args(["-v"])
      assert opts.verbosity == 1
    end

    test "parses -v verbose flag (multiple)" do
      assert {:ok, opts} = RNSD.parse_args(["-v", "-v", "-v"])
      assert opts.verbosity == 3
    end

    test "parses --verbose long form" do
      assert {:ok, opts} = RNSD.parse_args(["--verbose"])
      assert opts.verbosity == 1
    end

    test "parses -q quiet flag (single)" do
      assert {:ok, opts} = RNSD.parse_args(["-q"])
      assert opts.quietness == 1
    end

    test "parses -q quiet flag (multiple)" do
      assert {:ok, opts} = RNSD.parse_args(["-q", "-q"])
      assert opts.quietness == 2
    end

    test "parses --quiet long form" do
      assert {:ok, opts} = RNSD.parse_args(["--quiet"])
      assert opts.quietness == 1
    end

    test "parses -s service flag" do
      assert {:ok, opts} = RNSD.parse_args(["-s"])
      assert opts.service == true
    end

    test "parses --service long form" do
      assert {:ok, opts} = RNSD.parse_args(["--service"])
      assert opts.service == true
    end

    test "parses --exampleconfig flag" do
      assert {:ok, opts} = RNSD.parse_args(["--exampleconfig"])
      assert opts.exampleconfig == true
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNSD.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses combined verbose and quiet flags" do
      assert {:ok, opts} = RNSD.parse_args(["-v", "-v", "-q"])
      assert opts.verbosity == 2
      assert opts.quietness == 1
    end

    test "parses all options together" do
      args = ["--config", "/tmp/rns", "-v", "-v", "-q", "--service"]
      assert {:ok, opts} = RNSD.parse_args(args)
      assert opts.configdir == "/tmp/rns"
      assert opts.verbosity == 2
      assert opts.quietness == 1
      assert opts.service == true
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNSD.parse_args(["--unknown"])
      assert msg =~ "unknown option"
    end

    test "returns error for unexpected positional arguments" do
      assert {:error, msg} = RNSD.parse_args(["some_arg"])
      assert msg =~ "unexpected argument"
    end
  end

  # ── Version Output ────────────────────────────────────────────────

  describe "version output" do
    test "main with --version prints version and exits" do
      output = capture_io(fn -> RNSD.main(["--version"]) end)
      assert output =~ "rnsd #{RNS.Version.version()}"
    end
  end

  # ── Example Config ────────────────────────────────────────────────

  describe "example config" do
    test "example_rns_config returns a non-empty string" do
      config = RNSD.example_rns_config()
      assert is_binary(config)
      assert byte_size(config) > 0
    end

    test "example config contains required sections" do
      config = RNSD.example_rns_config()
      assert config =~ "[reticulum]"
      assert config =~ "[logging]"
      assert config =~ "[interfaces]"
    end

    test "example config contains key settings" do
      config = RNSD.example_rns_config()
      assert config =~ "enable_transport"
      assert config =~ "share_instance"
      assert config =~ "loglevel"
      assert config =~ "AutoInterface"
    end

    test "example config contains interface examples" do
      config = RNSD.example_rns_config()
      assert config =~ "UDPInterface"
      assert config =~ "TCPServerInterface"
      assert config =~ "TCPClientInterface"
      assert config =~ "I2PInterface"
      assert config =~ "RNodeInterface"
      assert config =~ "KISSInterface"
      assert config =~ "AX25KISSInterface"
    end

    test "main with --exampleconfig prints the example config" do
      output = capture_io(fn -> RNSD.main(["--exampleconfig"]) end)
      assert output =~ "[reticulum]"
      assert output =~ "[interfaces]"
    end
  end

  # ── Daemon Start/Stop ─────────────────────────────────────────────

  describe "daemon lifecycle" do
    test "daemon_loop responds to :stop message" do
      pid =
        spawn(fn ->
          RNSD.daemon_loop()
        end)

      # Give it a moment to start the loop
      Process.sleep(50)
      assert Process.alive?(pid)

      # Send stop message
      RNSD.stop(pid)

      # Wait for process to exit
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "stop/1 sends :stop message to pid" do
      test_pid = self()

      pid =
        spawn(fn ->
          receive do
            :stop -> send(test_pid, :got_stop)
          end
        end)

      RNSD.stop(pid)

      assert_receive :got_stop, 500
    end
  end

  # ── Verbosity Calculation ─────────────────────────────────────────

  describe "verbosity calculation" do
    test "effective verbosity is verbose minus quiet" do
      assert {:ok, opts} = RNSD.parse_args(["-v", "-v", "-v", "-q"])
      target = opts.verbosity - opts.quietness
      assert target == 2
    end

    test "quiet can exceed verbose for negative verbosity" do
      assert {:ok, opts} = RNSD.parse_args(["-q", "-q"])
      target = opts.verbosity - opts.quietness
      assert target == -2
    end
  end

  # ── Helper ────────────────────────────────────────────────────────

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
