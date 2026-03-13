defmodule RNS.Utilities.RNProbeTest do
  @moduledoc """
  Tests for the rnprobe utility.

  Tests argument parsing, hash validation, RTT formatting,
  reception stats formatting, and CLI output.
  """

  use ExUnit.Case, async: false

  alias RNS.Utilities.RNProbe

  # ── Argument Parsing ──────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNProbe.parse_args([])

      assert opts.configdir == nil
      assert opts.size == 16
      assert opts.probes == 1
      assert opts.timeout == 12.0
      assert opts.wait == 0.0
      assert opts.verbosity == 0
      assert opts.version == false
      assert opts.help == false
      assert opts.full_name == nil
      assert opts.destination_hash == nil
    end

    test "parses --config option" do
      assert {:ok, opts} = RNProbe.parse_args(["--config", "/tmp/test_reticulum"])
      assert opts.configdir == "/tmp/test_reticulum"
    end

    test "parses -s / --size option" do
      assert {:ok, opts} = RNProbe.parse_args(["-s", "64"])
      assert opts.size == 64

      assert {:ok, opts} = RNProbe.parse_args(["--size", "128"])
      assert opts.size == 128
    end

    test "parses -n / --probes option" do
      assert {:ok, opts} = RNProbe.parse_args(["-n", "5"])
      assert opts.probes == 5

      assert {:ok, opts} = RNProbe.parse_args(["--probes", "10"])
      assert opts.probes == 10
    end

    test "parses -t / --timeout option" do
      assert {:ok, opts} = RNProbe.parse_args(["-t", "30.0"])
      assert opts.timeout == 30.0

      assert {:ok, opts} = RNProbe.parse_args(["--timeout", "5.0"])
      assert opts.timeout == 5.0
    end

    test "parses -w / --wait option" do
      assert {:ok, opts} = RNProbe.parse_args(["-w", "1.5"])
      assert opts.wait == 1.5

      assert {:ok, opts} = RNProbe.parse_args(["--wait", "2.0"])
      assert opts.wait == 2.0
    end

    test "parses -v / --verbose flag (repeatable)" do
      assert {:ok, opts} = RNProbe.parse_args(["-v"])
      assert opts.verbosity == 1

      assert {:ok, opts} = RNProbe.parse_args(["-v", "-v"])
      assert opts.verbosity == 2

      assert {:ok, opts} = RNProbe.parse_args(["-v", "-v", "-v"])
      assert opts.verbosity == 3
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNProbe.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses --help flag" do
      assert {:ok, opts} = RNProbe.parse_args(["--help"])
      assert opts.help == true
    end

    test "parses full_name and destination_hash positional args" do
      hex = String.duplicate("ab", 16)
      assert {:ok, opts} = RNProbe.parse_args(["myapp.service", hex])
      assert opts.full_name == "myapp.service"
      assert opts.destination_hash == hex
    end

    test "parses single positional arg as destination_hash" do
      hex = String.duplicate("ab", 16)
      assert {:ok, opts} = RNProbe.parse_args([hex])
      assert opts.full_name == nil
      assert opts.destination_hash == hex
    end

    test "parses combined options" do
      hex = String.duplicate("ab", 16)

      args = [
        "--config", "/tmp/rns",
        "-s", "32",
        "-n", "3",
        "-t", "10.0",
        "-w", "0.5",
        "-v",
        "myapp.echo",
        hex
      ]

      assert {:ok, opts} = RNProbe.parse_args(args)
      assert opts.configdir == "/tmp/rns"
      assert opts.size == 32
      assert opts.probes == 3
      assert opts.timeout == 10.0
      assert opts.wait == 0.5
      assert opts.verbosity == 1
      assert opts.full_name == "myapp.echo"
      assert opts.destination_hash == hex
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNProbe.parse_args(["--unknown"])
      assert msg =~ "unknown option"
    end
  end

  # ── Version Output ─────────────────────────────────────────────────

  describe "version output" do
    test "main with --version prints version" do
      output = capture_io(fn -> RNProbe.main(["--version"]) end)
      assert output =~ "rnprobe #{RNS.Version.version()}"
    end
  end

  # ── Help Output ────────────────────────────────────────────────────

  describe "help output" do
    test "main with --help prints usage" do
      output = capture_io(fn -> RNProbe.main(["--help"]) end)
      assert output =~ "Reticulum Probe Utility"
      assert output =~ "--config"
      assert output =~ "--size"
      assert output =~ "--probes"
      assert output =~ "--timeout"
      assert output =~ "--wait"
      assert output =~ "full_name"
      assert output =~ "destination_hash"
    end

    test "main with no args shows usage" do
      output = capture_io(fn -> RNProbe.main([]) end)
      assert output =~ "Reticulum Probe Utility"
    end
  end

  # ── Hash Parsing ───────────────────────────────────────────────────

  describe "parse_destination_hash/1" do
    test "accepts valid 32-character hex hash" do
      hex = String.duplicate("ab", 16)
      assert {:ok, hash} = RNProbe.parse_destination_hash(hex)
      assert byte_size(hash) == 16
    end

    test "accepts mixed case hex" do
      hex = "AbCdEf0123456789abcdef0123456789"
      assert {:ok, _hash} = RNProbe.parse_destination_hash(hex)
    end

    test "rejects wrong length hash" do
      assert {:error, msg} = RNProbe.parse_destination_hash("abcdef")
      assert msg =~ "Destination length is invalid"
      assert msg =~ "32 hexadecimal characters"
      assert msg =~ "16 bytes"
    end

    test "rejects too long hash" do
      hex = String.duplicate("ab", 20)
      assert {:error, msg} = RNProbe.parse_destination_hash(hex)
      assert msg =~ "Destination length is invalid"
    end

    test "rejects non-hex characters" do
      hex = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
      assert {:error, msg} = RNProbe.parse_destination_hash(hex)
      assert msg =~ "Invalid destination"
    end

    test "all-zero hash is valid" do
      hex = String.duplicate("00", 16)
      assert {:ok, hash} = RNProbe.parse_destination_hash(hex)
      assert hash == <<0::128>>
    end

    test "all-ff hash is valid" do
      hex = String.duplicate("ff", 16)
      assert {:ok, hash} = RNProbe.parse_destination_hash(hex)
      assert byte_size(hash) == 16
      assert hash == :binary.copy(<<0xFF>>, 16)
    end
  end

  # ── RTT Formatting ─────────────────────────────────────────────────

  describe "format_rtt/1" do
    test "formats time >= 1 second" do
      result = RNProbe.format_rtt(1.0)
      assert result == "1.0 seconds"
    end

    test "formats multi-second time" do
      result = RNProbe.format_rtt(2.345)
      assert result == "2.345 seconds"
    end

    test "formats sub-second time in milliseconds" do
      result = RNProbe.format_rtt(0.123)
      assert result == "123.0 milliseconds"
    end

    test "formats very small time in milliseconds" do
      result = RNProbe.format_rtt(0.001)
      assert result == "1.0 milliseconds"
    end

    test "formats exact 1 second boundary" do
      assert RNProbe.format_rtt(1) =~ "seconds"
    end

    test "formats sub-millisecond time" do
      result = RNProbe.format_rtt(0.0005)
      assert result =~ "milliseconds"
    end
  end

  # ── Reception Stats Formatting ─────────────────────────────────────

  describe "format_reception_stats/1" do
    test "returns empty string for nil proof_packet" do
      receipt = %RNS.PacketReceipt{
        hash: <<0>>,
        truncated_hash: <<0>>,
        sent: true,
        sent_at: 0,
        proved: false,
        status: 1,
        destination: %{},
        callbacks: %RNS.PacketReceipt.Callbacks{},
        concluded_at: nil,
        proof_packet: nil,
        timeout: 10
      }

      assert RNProbe.format_reception_stats(receipt) == ""
    end

    test "formats RSSI stats" do
      receipt = %RNS.PacketReceipt{
        hash: <<0>>,
        truncated_hash: <<0>>,
        sent: true,
        sent_at: 0,
        proved: false,
        status: 1,
        destination: %{},
        callbacks: %RNS.PacketReceipt.Callbacks{},
        concluded_at: nil,
        proof_packet: %{rssi: -85, snr: nil, q: nil},
        timeout: 10
      }

      result = RNProbe.format_reception_stats(receipt)
      assert result =~ "RSSI -85 dBm"
    end

    test "formats SNR stats" do
      receipt = %RNS.PacketReceipt{
        hash: <<0>>,
        truncated_hash: <<0>>,
        sent: true,
        sent_at: 0,
        proved: false,
        status: 1,
        destination: %{},
        callbacks: %RNS.PacketReceipt.Callbacks{},
        concluded_at: nil,
        proof_packet: %{rssi: nil, snr: 12.5, q: nil},
        timeout: 10
      }

      result = RNProbe.format_reception_stats(receipt)
      assert result =~ "SNR 12.5 dB"
    end

    test "formats Link Quality stats" do
      receipt = %RNS.PacketReceipt{
        hash: <<0>>,
        truncated_hash: <<0>>,
        sent: true,
        sent_at: 0,
        proved: false,
        status: 1,
        destination: %{},
        callbacks: %RNS.PacketReceipt.Callbacks{},
        concluded_at: nil,
        proof_packet: %{rssi: nil, snr: nil, q: 95},
        timeout: 10
      }

      result = RNProbe.format_reception_stats(receipt)
      assert result =~ "Link Quality 95%"
    end

    test "formats all stats together" do
      receipt = %RNS.PacketReceipt{
        hash: <<0>>,
        truncated_hash: <<0>>,
        sent: true,
        sent_at: 0,
        proved: false,
        status: 1,
        destination: %{},
        callbacks: %RNS.PacketReceipt.Callbacks{},
        concluded_at: nil,
        proof_packet: %{rssi: -90, snr: 8.0, q: 80},
        timeout: 10
      }

      result = RNProbe.format_reception_stats(receipt)
      assert result =~ "RSSI -90 dBm"
      assert result =~ "SNR 8.0 dB"
      assert result =~ "Link Quality 80%"
    end
  end

  # ── Default Constants ──────────────────────────────────────────────

  describe "constants" do
    test "default probe size is 16" do
      assert {:ok, opts} = RNProbe.parse_args([])
      assert opts.size == 16
    end

    test "default timeout is 12" do
      assert {:ok, opts} = RNProbe.parse_args([])
      assert opts.timeout == 12.0
    end

    test "default probes is 1" do
      assert {:ok, opts} = RNProbe.parse_args([])
      assert opts.probes == 1
    end

    test "default wait is 0" do
      assert {:ok, opts} = RNProbe.parse_args([])
      assert opts.wait == 0.0
    end
  end

  # ── Helper ─────────────────────────────────────────────────────────

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
