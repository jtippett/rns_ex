defmodule RNS.Utilities.RNXTest do
  @moduledoc """
  Tests for the rnx utility.

  Tests argument parsing, hash validation, size formatting, time formatting,
  command execution, result formatting, and CLI output.
  """

  use ExUnit.Case, async: false

  alias RNS.Utilities.RNX

  # ── Constants ───────────────────────────────────────────────────────

  describe "constants" do
    test "app_name returns rnx" do
      assert RNX.app_name() == "rnx"
    end

    test "remote_exec_grace returns 2.0" do
      assert RNX.remote_exec_grace() == 2.0
    end

    test "stats_max returns 32" do
      assert RNX.stats_max() == 32
    end
  end

  # ── Argument Parsing ──────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNX.parse_args([])

      assert opts.configdir == nil
      assert opts.verbosity == 0
      assert opts.quietness == 0
      assert opts.print_identity == false
      assert opts.listen == false
      assert opts.identity_path == nil
      assert opts.interactive == false
      assert opts.no_announce == false
      assert opts.allowed == []
      assert opts.noauth == false
      assert opts.noid == false
      assert opts.detailed == false
      assert opts.mirror == false
      assert opts.timeout == 15.0
      assert opts.result_timeout == nil
      assert opts.stdin == nil
      assert opts.stdoutl == nil
      assert opts.stderrl == nil
      assert opts.version == false
      assert opts.help == false
      assert opts.destination == nil
      assert opts.command == nil
    end

    test "parses --config option" do
      assert {:ok, opts} = RNX.parse_args(["--config", "/tmp/test"])
      assert opts.configdir == "/tmp/test"
    end

    test "parses -v / --verbose flag (repeatable)" do
      assert {:ok, opts} = RNX.parse_args(["-v"])
      assert opts.verbosity == 1

      assert {:ok, opts} = RNX.parse_args(["-v", "-v"])
      assert opts.verbosity == 2
    end

    test "parses -q / --quiet flag (repeatable)" do
      assert {:ok, opts} = RNX.parse_args(["-q"])
      assert opts.quietness == 1
    end

    test "parses -p / --print-identity flag" do
      assert {:ok, opts} = RNX.parse_args(["-p"])
      assert opts.print_identity == true
    end

    test "parses -l / --listen flag" do
      assert {:ok, opts} = RNX.parse_args(["-l"])
      assert opts.listen == true
    end

    test "parses -i identity path" do
      assert {:ok, opts} = RNX.parse_args(["-i", "/tmp/id"])
      assert opts.identity_path == "/tmp/id"
    end

    test "parses -x / --interactive flag" do
      assert {:ok, opts} = RNX.parse_args(["-x"])
      assert opts.interactive == true
    end

    test "parses -b / --no-announce flag" do
      assert {:ok, opts} = RNX.parse_args(["-b"])
      assert opts.no_announce == true
    end

    test "parses -a allowed hashes (repeatable)" do
      assert {:ok, opts} = RNX.parse_args(["-a", "hash1", "-a", "hash2"])
      assert opts.allowed == ["hash1", "hash2"]
    end

    test "parses -n / --noauth flag" do
      assert {:ok, opts} = RNX.parse_args(["-n"])
      assert opts.noauth == true
    end

    test "parses -N / --noid flag" do
      assert {:ok, opts} = RNX.parse_args(["-N"])
      assert opts.noid == true
    end

    test "parses -d / --detailed flag" do
      assert {:ok, opts} = RNX.parse_args(["-d"])
      assert opts.detailed == true
    end

    test "parses -m mirror flag" do
      assert {:ok, opts} = RNX.parse_args(["-m"])
      assert opts.mirror == true
    end

    test "parses -w timeout" do
      assert {:ok, opts} = RNX.parse_args(["-w", "30.0"])
      assert opts.timeout == 30.0
    end

    test "parses -W result timeout" do
      assert {:ok, opts} = RNX.parse_args(["-W", "60.0"])
      assert opts.result_timeout == 60.0
    end

    test "parses --stdin option" do
      assert {:ok, opts} = RNX.parse_args(["--stdin", "hello world"])
      assert opts.stdin == "hello world"
    end

    test "parses --stdout limit" do
      assert {:ok, opts} = RNX.parse_args(["--stdout", "1024"])
      assert opts.stdoutl == 1024
    end

    test "parses --stderr limit" do
      assert {:ok, opts} = RNX.parse_args(["--stderr", "2048"])
      assert opts.stderrl == 2048
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNX.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses --help flag" do
      assert {:ok, opts} = RNX.parse_args(["--help"])
      assert opts.help == true
    end

    test "parses positional args: destination and command" do
      assert {:ok, opts} = RNX.parse_args(["abcdef0123456789abcdef0123456789", "ls -la"])
      assert opts.destination == "abcdef0123456789abcdef0123456789"
      assert opts.command == "ls -la"
    end

    test "parses only destination without command" do
      assert {:ok, opts} = RNX.parse_args(["abcdef0123456789abcdef0123456789"])
      assert opts.destination == "abcdef0123456789abcdef0123456789"
      assert opts.command == nil
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNX.parse_args(["--unknown"])
      assert msg =~ "unknown option"
    end

    test "parses combined execute options" do
      assert {:ok, opts} =
               RNX.parse_args([
                 "-v",
                 "-d",
                 "-m",
                 "-w",
                 "20.0",
                 "--stdout",
                 "4096",
                 "--stderr",
                 "1024",
                 "abcdef0123456789abcdef0123456789",
                 "uname -a"
               ])

      assert opts.verbosity == 1
      assert opts.detailed == true
      assert opts.mirror == true
      assert opts.timeout == 20.0
      assert opts.stdoutl == 4096
      assert opts.stderrl == 1024
      assert opts.destination == "abcdef0123456789abcdef0123456789"
      assert opts.command == "uname -a"
    end

    test "parses combined listen options" do
      assert {:ok, opts} =
               RNX.parse_args([
                 "-l",
                 "-n",
                 "-b",
                 "-a",
                 "abc123",
                 "-i",
                 "/tmp/id"
               ])

      assert opts.listen == true
      assert opts.noauth == true
      assert opts.no_announce == true
      assert opts.allowed == ["abc123"]
      assert opts.identity_path == "/tmp/id"
    end
  end

  # ── Version Output ────────────────────────────────────────────────

  describe "version output" do
    test "main prints version with --version flag" do
      output = capture_io(fn -> RNX.main(["--version"]) end)
      assert output =~ "rnx"
      assert output =~ RNS.Version.version()
    end
  end

  # ── Help Output ───────────────────────────────────────────────────

  describe "help output" do
    test "main prints help with --help flag" do
      output = capture_io(fn -> RNX.main(["--help"]) end)
      assert output =~ "Reticulum Remote Execution Utility"
      assert output =~ "--config"
      assert output =~ "--listen"
      assert output =~ "--interactive"
    end

    test "main prints help with no args" do
      output = capture_io(fn -> RNX.main([]) end)
      assert output =~ "Reticulum Remote Execution Utility"
    end
  end

  # ── Hash Parsing ──────────────────────────────────────────────────

  describe "parse_destination_hash/1" do
    test "parses valid 32-char hex hash" do
      hash = "abcdef0123456789abcdef0123456789"
      assert {:ok, hash_bytes} = RNX.parse_destination_hash(hash)
      assert byte_size(hash_bytes) == 16
    end

    test "parses mixed case hex hash" do
      hash = "AbCdEf0123456789aBcDeF0123456789"
      assert {:ok, _hash_bytes} = RNX.parse_destination_hash(hash)
    end

    test "returns error for wrong length hash" do
      assert {:error, msg} = RNX.parse_destination_hash("abcdef")
      assert msg =~ "invalid"
    end

    test "returns error for invalid hex characters" do
      hash = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
      assert {:error, msg} = RNX.parse_destination_hash(hash)
      assert msg =~ "Invalid"
    end

    test "returns error for empty string" do
      assert {:error, _msg} = RNX.parse_destination_hash("")
    end
  end

  # ── Size Formatting ──────────────────────────────────────────────

  describe "size_str/2" do
    test "formats zero bytes" do
      assert RNX.size_str(0) == "0 B"
    end

    test "formats small bytes" do
      assert RNX.size_str(500) == "500 B"
    end

    test "formats kilobytes" do
      result = RNX.size_str(1500)
      assert result =~ "1.5 KB"
    end

    test "formats megabytes" do
      result = RNX.size_str(1_500_000)
      assert result =~ "1.5 MB"
    end

    test "formats bits when suffix is b" do
      result = RNX.size_str(1000, "b")
      assert result =~ "8.0 Kb"
    end
  end

  # ── Pretty Time ───────────────────────────────────────────────────

  describe "pretty_time/2" do
    test "formats seconds only" do
      result = RNX.pretty_time(30.0)
      assert result == "30.0s"
    end

    test "formats minutes and seconds" do
      result = RNX.pretty_time(90.0)
      assert result =~ "1m"
      assert result =~ "30.0s"
    end

    test "formats hours, minutes and seconds" do
      result = RNX.pretty_time(3661.5)
      assert result =~ "1h"
      assert result =~ "1m"
      assert result =~ "1.5s"
    end

    test "formats days" do
      result = RNX.pretty_time(86400.0 + 3600.0 + 60.0 + 1.0)
      assert result =~ "1d"
      assert result =~ "1h"
      assert result =~ "1m"
      assert result =~ "1.0s"
    end

    test "verbose format with singular" do
      result = RNX.pretty_time(60.0 + 1.0, true)
      assert result =~ "1 minute"
      assert result =~ "1.0 second"
      refute result =~ "seconds"
      refute result =~ "minutes"
    end

    test "verbose format with plural" do
      result = RNX.pretty_time(120.0 + 2.0, true)
      assert result =~ "2 minutes"
      assert result =~ "2.0 seconds"
    end

    test "uses 'and' for last component" do
      result = RNX.pretty_time(3661.0)
      assert result =~ " and "
    end

    test "uses comma separator for multiple components" do
      result = RNX.pretty_time(86400.0 + 3600.0 + 60.0 + 1.0)
      assert result =~ ", "
      assert result =~ " and "
    end

    test "returns empty string for zero" do
      assert RNX.pretty_time(0.0) == ""
    end
  end

  # ── Build Request Data ──────────────────────────────────────────────

  describe "build_request_data/5" do
    test "builds request data with all fields" do
      result = RNX.build_request_data("ls -la", 30.0, 4096, 1024, "input data")

      assert Enum.at(result, 0) == "ls -la"
      assert Enum.at(result, 1) == 30.0
      assert Enum.at(result, 2) == 4096
      assert Enum.at(result, 3) == 1024
      assert Enum.at(result, 4) == "input data"
    end

    test "builds request data with nil stdin" do
      result = RNX.build_request_data("echo hello", 10.0, nil, nil, nil)

      assert Enum.at(result, 0) == "echo hello"
      assert Enum.at(result, 4) == nil
    end

    test "builds request data with output limits" do
      result = RNX.build_request_data("cmd", nil, 0, 0, nil)

      assert Enum.at(result, 2) == 0
      assert Enum.at(result, 3) == 0
    end
  end

  # ── Execute Received Command ───────────────────────────────────────

  describe "execute_received_command/5" do
    test "executes simple echo command" do
      data = ["echo hello", nil, nil, nil, nil]
      result = RNX.execute_received_command("command", data, <<>>, nil, 0)

      # result[0] = executed
      assert Enum.at(result, 0) == true
      # result[1] = return code
      assert Enum.at(result, 1) == 0
      # result[2] = stdout
      stdout = Enum.at(result, 2)
      assert is_binary(stdout)
      assert stdout =~ "hello"
    end

    test "captures exit code from failing command" do
      data = ["false", nil, nil, nil, nil]
      result = RNX.execute_received_command("command", data, <<>>, nil, 0)

      assert Enum.at(result, 0) == true
      assert Enum.at(result, 1) != 0
    end

    test "returns not executed for nonexistent command" do
      data = ["__nonexistent_command_xyz_#{:rand.uniform(100_000)}", nil, nil, nil, nil]
      result = RNX.execute_received_command("command", data, <<>>, nil, 0)

      # Should not have executed
      assert Enum.at(result, 0) == false
    end

    test "truncates stdout to limit" do
      # echo produces a small output, set limit to 3 bytes
      data = ["echo hello_world", nil, 3, nil, nil]
      result = RNX.execute_received_command("command", data, <<>>, nil, 0)

      assert Enum.at(result, 0) == true
      stdout = Enum.at(result, 2)
      assert byte_size(stdout) == 3
      # Total stdout length should be larger
      total = Enum.at(result, 4)
      assert total > 3
    end

    test "records timestamps" do
      data = ["echo test", nil, nil, nil, nil]
      result = RNX.execute_received_command("command", data, <<>>, nil, 0)

      started = Enum.at(result, 6)
      assert is_number(started)
      assert started > 0
    end

    test "handles command with arguments" do
      data = ["printf 'abc'", nil, nil, nil, nil]
      result = RNX.execute_received_command("command", data, <<>>, nil, 0)

      assert Enum.at(result, 0) == true
    end
  end

  # ── Format Result ──────────────────────────────────────────────────

  describe "format_result/4" do
    test "formats successful result with stdout" do
      response = [true, 0, "hello\n", "", 6, 0, 1000.0, 1001.0]
      {stdout, stderr, detail_lines} = RNX.format_result(response, false, nil, nil)

      assert stdout == "hello\n"
      assert stderr == nil
      assert detail_lines == []
    end

    test "formats failed execution" do
      response = [false, nil, nil, nil, nil, nil, 1000.0, nil]
      {stdout, stderr, detail_lines} = RNX.format_result(response, false, nil, nil)

      assert stdout == nil
      assert stderr == nil
      assert Enum.any?(detail_lines, &(&1 =~ "could not execute"))
    end

    test "formats detailed result with timestamps" do
      response = [true, 0, "output", "err", 6, 3, 1000.0, 1001.5]
      {stdout, stderr, detail_lines} = RNX.format_result(response, true, nil, nil)

      assert stdout == "output"
      assert stderr == "err"
      assert Enum.any?(detail_lines, &(&1 =~ "End of remote output"))
      assert Enum.any?(detail_lines, &(&1 =~ "execution took"))
    end

    test "shows truncation info in non-detailed mode" do
      # stdout was truncated (got 3 bytes, total was 10)
      response = [true, 0, "abc", "", 10, 0, 1000.0, 1001.0]
      {_stdout, _stderr, detail_lines} = RNX.format_result(response, false, nil, nil)

      assert Enum.any?(detail_lines, &(&1 =~ "truncated"))
    end

    test "shows stdout length in detailed mode" do
      response = [true, 0, "abc", "", 10, 0, 1000.0, 1001.0]
      {_stdout, _stderr, detail_lines} = RNX.format_result(response, true, nil, nil)

      assert Enum.any?(detail_lines, &(&1 =~ "stdout"))
    end
  end

  # ── Speed Calculation ──────────────────────────────────────────────

  describe "calculate_speed/1" do
    test "returns 0.0 for empty stats" do
      assert RNX.calculate_speed([]) == 0.0
    end

    test "returns 0.0 for single entry" do
      assert RNX.calculate_speed([{1.0, 100}]) == 0.0
    end

    test "calculates speed from entries" do
      stats = [{0.0, 0}, {1.0, 500}, {2.0, 1000}]
      assert RNX.calculate_speed(stats) == 500.0
    end

    test "returns 0.0 when span is zero" do
      stats = [{1.0, 0}, {1.0, 1000}]
      assert RNX.calculate_speed(stats) == 0.0
    end
  end

  # ── Identity Preparation ──────────────────────────────────────────

  describe "prepare_identity/1" do
    test "creates new identity when file doesn't exist" do
      path = Path.join(System.tmp_dir!(), "rnx_test_id_#{:rand.uniform(100_000)}")
      File.rm(path)

      identity = RNX.prepare_identity(path)
      assert %RNS.Identity{} = identity
      assert identity.pub_bytes != nil

      File.rm(path)
    end

    test "loads identity from existing file" do
      path = Path.join(System.tmp_dir!(), "rnx_test_id2_#{:rand.uniform(100_000)}")
      File.rm(path)

      original = RNX.prepare_identity(path)
      loaded = RNX.prepare_identity(path)
      assert loaded.pub_bytes == original.pub_bytes

      File.rm(path)
    end
  end

  # ── Callback Functions ──────────────────────────────────────────────

  describe "initiator_identified/2" do
    test "does not teardown when identity is allowed" do
      hash = :crypto.strong_rand_bytes(16)
      Process.put(:rnx_allow_all, false)
      Process.put(:rnx_allowed_hashes, [hash])

      # Should not crash - just logs
      link = RNS.Link.new()
      identity = %RNS.Identity{hash: hash, pub_bytes: <<>>}
      assert :ok == RNX.initiator_identified(link, identity)
    end

    test "accepts when allow_all is true" do
      Process.put(:rnx_allow_all, true)
      Process.put(:rnx_allowed_hashes, [])

      link = RNS.Link.new()
      hash = :crypto.strong_rand_bytes(16)
      identity = %RNS.Identity{hash: hash, pub_bytes: <<>>}
      assert :ok == RNX.initiator_identified(link, identity)
    end
  end

  # ── Private helper for capturing IO ────────────────────────────────

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
