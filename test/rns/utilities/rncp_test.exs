defmodule RNS.Utilities.RNCPTest do
  @moduledoc """
  Tests for the rncp utility.

  Tests argument parsing, hash validation, size formatting,
  progress formatting, identity preparation, callback behavior,
  and CLI output.
  """

  use ExUnit.Case, async: false

  alias RNS.Utilities.RNCP

  # ── Constants ───────────────────────────────────────────────────────

  describe "constants" do
    test "app_name returns rncp" do
      assert RNCP.app_name() == "rncp"
    end

    test "req_fetch_not_allowed returns 0xF0" do
      assert RNCP.req_fetch_not_allowed() == 0xF0
    end

    test "stats_max returns 32" do
      assert RNCP.stats_max() == 32
    end
  end

  # ── Argument Parsing ──────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNCP.parse_args([])

      assert opts.configdir == nil
      assert opts.verbosity == 0
      assert opts.quietness == 0
      assert opts.silent == false
      assert opts.listen == false
      assert opts.no_compress == false
      assert opts.allow_fetch == false
      assert opts.fetch == false
      assert opts.jail == nil
      assert opts.save == nil
      assert opts.overwrite == false
      assert opts.announce == -1
      assert opts.allowed == []
      assert opts.no_auth == false
      assert opts.print_identity == false
      assert opts.identity_path == nil
      assert opts.timeout == 15.0
      assert opts.phy_rates == false
      assert opts.version == false
      assert opts.help == false
      assert opts.file == nil
      assert opts.destination == nil
    end

    test "parses --config option" do
      assert {:ok, opts} = RNCP.parse_args(["--config", "/tmp/test"])
      assert opts.configdir == "/tmp/test"
    end

    test "parses -v / --verbose flag (repeatable)" do
      assert {:ok, opts} = RNCP.parse_args(["-v"])
      assert opts.verbosity == 1

      assert {:ok, opts} = RNCP.parse_args(["-v", "-v", "-v"])
      assert opts.verbosity == 3
    end

    test "parses -q / --quiet flag (repeatable)" do
      assert {:ok, opts} = RNCP.parse_args(["-q"])
      assert opts.quietness == 1

      assert {:ok, opts} = RNCP.parse_args(["-q", "-q"])
      assert opts.quietness == 2
    end

    test "parses -S / --silent flag" do
      assert {:ok, opts} = RNCP.parse_args(["-S"])
      assert opts.silent == true

      assert {:ok, opts} = RNCP.parse_args(["--silent"])
      assert opts.silent == true
    end

    test "parses -l / --listen flag" do
      assert {:ok, opts} = RNCP.parse_args(["-l"])
      assert opts.listen == true

      assert {:ok, opts} = RNCP.parse_args(["--listen"])
      assert opts.listen == true
    end

    test "parses -C / --no-compress flag" do
      assert {:ok, opts} = RNCP.parse_args(["-C"])
      assert opts.no_compress == true
    end

    test "parses -F / --allow-fetch flag" do
      assert {:ok, opts} = RNCP.parse_args(["-F"])
      assert opts.allow_fetch == true
    end

    test "parses -f / --fetch flag" do
      assert {:ok, opts} = RNCP.parse_args(["-f"])
      assert opts.fetch == true
    end

    test "parses -j / --jail path" do
      assert {:ok, opts} = RNCP.parse_args(["-j", "/tmp/jail"])
      assert opts.jail == "/tmp/jail"

      assert {:ok, opts} = RNCP.parse_args(["--jail", "/tmp/jail2"])
      assert opts.jail == "/tmp/jail2"
    end

    test "parses -s / --save path" do
      assert {:ok, opts} = RNCP.parse_args(["-s", "/tmp/save"])
      assert opts.save == "/tmp/save"
    end

    test "parses -O / --overwrite flag" do
      assert {:ok, opts} = RNCP.parse_args(["-O"])
      assert opts.overwrite == true
    end

    test "parses -b announce interval" do
      assert {:ok, opts} = RNCP.parse_args(["-b", "60"])
      assert opts.announce == 60
    end

    test "parses -a allowed hashes (repeatable)" do
      assert {:ok, opts} = RNCP.parse_args(["-a", "abc123", "-a", "def456"])
      assert opts.allowed == ["abc123", "def456"]
    end

    test "parses -n / --no-auth flag" do
      assert {:ok, opts} = RNCP.parse_args(["-n"])
      assert opts.no_auth == true
    end

    test "parses -p / --print-identity flag" do
      assert {:ok, opts} = RNCP.parse_args(["-p"])
      assert opts.print_identity == true
    end

    test "parses -i identity path" do
      assert {:ok, opts} = RNCP.parse_args(["-i", "/tmp/id"])
      assert opts.identity_path == "/tmp/id"
    end

    test "parses -w timeout" do
      assert {:ok, opts} = RNCP.parse_args(["-w", "30.0"])
      assert opts.timeout == 30.0
    end

    test "parses -P / --phy-rates flag" do
      assert {:ok, opts} = RNCP.parse_args(["-P"])
      assert opts.phy_rates == true
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNCP.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses --help flag" do
      assert {:ok, opts} = RNCP.parse_args(["--help"])
      assert opts.help == true
    end

    test "parses positional args: file and destination" do
      assert {:ok, opts} = RNCP.parse_args(["myfile.txt", "abcdef1234567890abcdef1234567890"])
      assert opts.file == "myfile.txt"
      assert opts.destination == "abcdef1234567890abcdef1234567890"
    end

    test "parses only file without destination" do
      assert {:ok, opts} = RNCP.parse_args(["myfile.txt"])
      assert opts.file == "myfile.txt"
      assert opts.destination == nil
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNCP.parse_args(["--unknown"])
      assert msg =~ "unknown option"
    end

    test "parses combined send options" do
      assert {:ok, opts} =
               RNCP.parse_args([
                 "-v",
                 "-v",
                 "--config",
                 "/tmp/cfg",
                 "-w",
                 "20.0",
                 "-P",
                 "-C",
                 "test.txt",
                 "abcdef1234567890abcdef1234567890"
               ])

      assert opts.verbosity == 2
      assert opts.configdir == "/tmp/cfg"
      assert opts.timeout == 20.0
      assert opts.phy_rates == true
      assert opts.no_compress == true
      assert opts.file == "test.txt"
      assert opts.destination == "abcdef1234567890abcdef1234567890"
    end

    test "parses combined listen options" do
      assert {:ok, opts} =
               RNCP.parse_args([
                 "-l",
                 "-n",
                 "-F",
                 "-j",
                 "/tmp/jail",
                 "-s",
                 "/tmp/save",
                 "-O",
                 "-b",
                 "30"
               ])

      assert opts.listen == true
      assert opts.no_auth == true
      assert opts.allow_fetch == true
      assert opts.jail == "/tmp/jail"
      assert opts.save == "/tmp/save"
      assert opts.overwrite == true
      assert opts.announce == 30
    end

    test "parses combined fetch options" do
      assert {:ok, opts} =
               RNCP.parse_args([
                 "-f",
                 "-S",
                 "-s",
                 "/tmp/out",
                 "-O",
                 "myfile.txt",
                 "abcdef1234567890abcdef1234567890"
               ])

      assert opts.fetch == true
      assert opts.silent == true
      assert opts.save == "/tmp/out"
      assert opts.overwrite == true
      assert opts.file == "myfile.txt"
      assert opts.destination == "abcdef1234567890abcdef1234567890"
    end
  end

  # ── Version Output ────────────────────────────────────────────────

  describe "version output" do
    test "main prints version with --version flag" do
      output = capture_io(fn -> RNCP.main(["--version"]) end)
      assert output =~ "rncp"
      assert output =~ RNS.Version.version()
    end
  end

  # ── Help Output ───────────────────────────────────────────────────

  describe "help output" do
    test "main prints help with --help flag" do
      output = capture_io(fn -> RNCP.main(["--help"]) end)
      assert output =~ "Reticulum File Transfer Utility"
      assert output =~ "--config"
      assert output =~ "--listen"
      assert output =~ "--fetch"
    end

    test "main prints help with no args" do
      output = capture_io(fn -> RNCP.main([]) end)
      assert output =~ "Reticulum File Transfer Utility"
    end
  end

  # ── Hash Parsing ──────────────────────────────────────────────────

  describe "parse_destination_hash/1" do
    test "parses valid 32-char hex hash" do
      hash = "abcdef0123456789abcdef0123456789"
      assert {:ok, hash_bytes} = RNCP.parse_destination_hash(hash)
      assert byte_size(hash_bytes) == 16
    end

    test "parses mixed case hex hash" do
      hash = "AbCdEf0123456789aBcDeF0123456789"
      assert {:ok, _hash_bytes} = RNCP.parse_destination_hash(hash)
    end

    test "returns error for wrong length hash" do
      assert {:error, msg} = RNCP.parse_destination_hash("abcdef")
      assert msg =~ "invalid"
    end

    test "returns error for invalid hex characters" do
      hash = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
      assert {:error, msg} = RNCP.parse_destination_hash(hash)
      assert msg =~ "Invalid"
    end

    test "returns error for empty string" do
      assert {:error, _msg} = RNCP.parse_destination_hash("")
    end
  end

  # ── Size Formatting ──────────────────────────────────────────────

  describe "size_str/2" do
    test "formats zero bytes" do
      assert RNCP.size_str(0) == "0 B"
    end

    test "formats small bytes" do
      assert RNCP.size_str(500) == "500 B"
    end

    test "formats kilobytes" do
      result = RNCP.size_str(1500)
      assert result =~ "1.5 KB"
    end

    test "formats megabytes" do
      result = RNCP.size_str(1_500_000)
      assert result =~ "1.5 MB"
    end

    test "formats gigabytes" do
      result = RNCP.size_str(1_500_000_000)
      assert result =~ "1.5 GB"
    end

    test "formats bits when suffix is b" do
      result = RNCP.size_str(1000, "b")
      assert result =~ "8.0 Kb"
    end

    test "formats exact unit boundaries" do
      result = RNCP.size_str(1000)
      assert result =~ "1.0 KB"
    end

    test "handles very large values" do
      result = RNCP.size_str(1_000_000_000_000)
      assert result =~ "TB"
    end
  end

  # ── Progress Formatting ──────────────────────────────────────────

  describe "format_progress/5" do
    test "formats 0% progress" do
      result = RNCP.format_progress(0.0, 1000, 0.0)
      assert result =~ "0.0%"
      assert result =~ "0 B"
      assert result =~ "KB"
    end

    test "formats 50% progress" do
      result = RNCP.format_progress(0.5, 1000, 500.0)
      assert result =~ "50.0%"
      assert result =~ "500 B"
      assert result =~ "KB"
    end

    test "formats 100% progress" do
      result = RNCP.format_progress(1.0, 1000, 100.0)
      assert result =~ "100.0%"
    end

    test "includes phy rates when enabled" do
      result = RNCP.format_progress(0.5, 1000, 500.0, true, 1000.0)
      assert result =~ "at physical layer"
    end

    test "excludes phy rates when disabled" do
      result = RNCP.format_progress(0.5, 1000, 500.0, false, 0.0)
      refute result =~ "physical layer"
    end
  end

  # ── Speed Calculation ──────────────────────────────────────────────

  describe "calculate_speed/1" do
    test "returns 0.0 for empty stats" do
      assert RNCP.calculate_speed([]) == 0.0
    end

    test "returns 0.0 for single entry" do
      assert RNCP.calculate_speed([{1.0, 100}]) == 0.0
    end

    test "calculates speed from two entries" do
      stats = [{1.0, 0}, {2.0, 1000}]
      assert RNCP.calculate_speed(stats) == 1000.0
    end

    test "calculates speed from multiple entries" do
      stats = [{0.0, 0}, {1.0, 500}, {2.0, 1000}]
      assert RNCP.calculate_speed(stats) == 500.0
    end

    test "returns 0.0 when span is zero" do
      stats = [{1.0, 0}, {1.0, 1000}]
      assert RNCP.calculate_speed(stats) == 0.0
    end
  end

  # ── Callback Functions ──────────────────────────────────────────────

  describe "receive_resource_callback/1" do
    test "returns true when allow_all is set" do
      Process.put(:rncp_allow_all, true)
      Process.put(:rncp_allowed_hashes, [])

      resource = %{link: %{peer: %{remote_identity: nil}}}
      assert RNCP.receive_resource_callback(resource) == true
    end

    test "returns false when not allowed and not allow_all" do
      Process.put(:rncp_allow_all, false)
      Process.put(:rncp_allowed_hashes, [])

      resource = %{link: %{peer: %{remote_identity: nil}}}
      assert RNCP.receive_resource_callback(resource) == false
    end

    test "returns true when identity hash is in allowed list" do
      hash = :crypto.strong_rand_bytes(16)
      Process.put(:rncp_allow_all, false)
      Process.put(:rncp_allowed_hashes, [hash])

      resource = %{link: %{peer: %{remote_identity: %{hash: hash}}}}
      assert RNCP.receive_resource_callback(resource) == true
    end
  end

  # ── Fetch Request ───────────────────────────────────────────────────

  describe "fetch_request/2" do
    @default_context %{path: "path", request_id: <<>>, link_id: <<>>, remote_identity: nil, requested_at: 0}

    test "returns REQ_FETCH_NOT_ALLOWED when fetch not allowed" do
      Process.put(:rncp_allow_fetch, false)

      result = RNCP.fetch_request("file.txt", @default_context)
      assert result == 0xF0
    end

    test "returns false when file not found" do
      Process.put(:rncp_allow_fetch, true)
      Process.put(:rncp_fetch_jail, nil)

      result = RNCP.fetch_request("/nonexistent/file_xyz_123.txt", @default_context)
      assert result == false
    end

    test "returns true when file exists without jail" do
      Process.put(:rncp_allow_fetch, true)
      Process.put(:rncp_fetch_jail, nil)

      # Use a file we know exists
      result = RNCP.fetch_request("mix.exs", @default_context)
      assert result == true
    end

    test "blocks path traversal outside jail" do
      jail_dir = System.tmp_dir!() |> Path.join("rncp_test_jail_#{:rand.uniform(100_000)}")
      File.mkdir_p!(jail_dir)

      Process.put(:rncp_allow_fetch, true)
      Process.put(:rncp_fetch_jail, jail_dir)

      result = RNCP.fetch_request("../../etc/passwd", @default_context)
      assert result == 0xF0

      File.rm_rf!(jail_dir)
    end
  end

  # ── Identity Preparation ──────────────────────────────────────────

  describe "prepare_identity/1" do
    test "creates new identity when file doesn't exist" do
      path = Path.join(System.tmp_dir!(), "rncp_test_id_#{:rand.uniform(100_000)}")
      File.rm(path)

      identity = RNCP.prepare_identity(path)
      assert %RNS.Identity{} = identity
      assert identity.pub_bytes != nil

      File.rm(path)
    end

    test "loads identity from existing file" do
      path = Path.join(System.tmp_dir!(), "rncp_test_id2_#{:rand.uniform(100_000)}")
      File.rm(path)

      # Create and save
      original = RNCP.prepare_identity(path)

      # Load
      loaded = RNCP.prepare_identity(path)
      assert loaded.pub_bytes == original.pub_bytes

      File.rm(path)
    end
  end

  # ── Private helper for capturing IO ────────────────────────────────

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
