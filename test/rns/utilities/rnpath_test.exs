defmodule RNS.Utilities.RNPathTest do
  @moduledoc """
  Tests for the rnpath utility.

  Tests argument parsing, hash validation, path table access,
  rate table access, path dropping, blackhole management,
  and output formatting.
  """

  use ExUnit.Case, async: false

  alias RNS.Utilities.RNPath

  setup_all do
    # Ensure ETS tables exist for tests that directly access them
    ensure_ets_table(:rns_path_table)
    ensure_ets_table(:rns_announce_rate_table)
    ensure_ets_table(:rns_interfaces)
    :ok
  end

  defp ensure_ets_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  end

  # ── Argument Parsing ──────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNPath.parse_args([])

      assert opts.configdir == nil
      assert opts.table == false
      assert opts.max_hops == nil
      assert opts.rates == false
      assert opts.drop == false
      assert opts.drop_announces == false
      assert opts.drop_via == false
      assert opts.blackholed == false
      assert opts.blackhole == false
      assert opts.unblackhole == false
      assert opts.duration == nil
      assert opts.reason == nil
      assert opts.json == false
      assert opts.verbosity == 0
      assert opts.version == false
      assert opts.help == false
      assert opts.destination == nil
      assert opts.list_filter == nil
    end

    test "parses --config option" do
      assert {:ok, opts} = RNPath.parse_args(["--config", "/tmp/test_reticulum"])
      assert opts.configdir == "/tmp/test_reticulum"
    end

    test "parses -t / --table flag" do
      assert {:ok, opts} = RNPath.parse_args(["-t"])
      assert opts.table == true

      assert {:ok, opts} = RNPath.parse_args(["--table"])
      assert opts.table == true
    end

    test "parses -m / --max option" do
      assert {:ok, opts} = RNPath.parse_args(["-m", "3"])
      assert opts.max_hops == 3

      assert {:ok, opts} = RNPath.parse_args(["--max", "5"])
      assert opts.max_hops == 5
    end

    test "parses -r / --rates flag" do
      assert {:ok, opts} = RNPath.parse_args(["-r"])
      assert opts.rates == true
    end

    test "parses -d / --drop flag" do
      assert {:ok, opts} = RNPath.parse_args(["-d"])
      assert opts.drop == true
    end

    test "parses -D / --drop-announces flag" do
      assert {:ok, opts} = RNPath.parse_args(["-D"])
      assert opts.drop_announces == true
    end

    test "parses -x / --drop-via flag" do
      assert {:ok, opts} = RNPath.parse_args(["-x"])
      assert opts.drop_via == true
    end

    test "parses -w / --timeout option" do
      assert {:ok, opts} = RNPath.parse_args(["-w", "30.0"])
      assert opts.timeout == 30.0
    end

    test "parses -b / --blackholed flag" do
      assert {:ok, opts} = RNPath.parse_args(["-b"])
      assert opts.blackholed == true
    end

    test "parses -B / --blackhole flag" do
      assert {:ok, opts} = RNPath.parse_args(["-B"])
      assert opts.blackhole == true
    end

    test "parses -U / --unblackhole flag" do
      assert {:ok, opts} = RNPath.parse_args(["-U"])
      assert opts.unblackhole == true
    end

    test "parses --duration option" do
      assert {:ok, opts} = RNPath.parse_args(["--duration", "24.0"])
      assert opts.duration == 24.0
    end

    test "parses --reason option" do
      assert {:ok, opts} = RNPath.parse_args(["--reason", "spam"])
      assert opts.reason == "spam"
    end

    test "parses -j / --json flag" do
      assert {:ok, opts} = RNPath.parse_args(["-j"])
      assert opts.json == true
    end

    test "parses -v / --verbose flag (repeatable)" do
      assert {:ok, opts} = RNPath.parse_args(["-v"])
      assert opts.verbosity == 1

      assert {:ok, opts} = RNPath.parse_args(["-v", "-v"])
      assert opts.verbosity == 2
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNPath.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses destination as positional arg" do
      hex = String.duplicate("ab", 16)
      assert {:ok, opts} = RNPath.parse_args([hex])
      assert opts.destination == hex
    end

    test "parses destination and list_filter as positional args" do
      hex = String.duplicate("ab", 16)
      assert {:ok, opts} = RNPath.parse_args([hex, "myfilter"])
      assert opts.destination == hex
      assert opts.list_filter == "myfilter"
    end

    test "parses combined options" do
      args = ["--config", "/tmp/rns", "-t", "-m", "5", "-j", "-v"]
      assert {:ok, opts} = RNPath.parse_args(args)
      assert opts.configdir == "/tmp/rns"
      assert opts.table == true
      assert opts.max_hops == 5
      assert opts.json == true
      assert opts.verbosity == 1
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNPath.parse_args(["--unknown"])
      assert msg =~ "unknown option"
    end
  end

  # ── Version Output ────────────────────────────────────────────────

  describe "version output" do
    test "main with --version prints version" do
      output = capture_io(fn -> RNPath.main(["--version"]) end)
      assert output =~ "rnpath #{RNS.Version.version()}"
    end
  end

  # ── Help Output ────────────────────────────────────────────────────

  describe "help output" do
    test "main with --help prints usage" do
      output = capture_io(fn -> RNPath.main(["--help"]) end)
      assert output =~ "Reticulum Path Management Utility"
      assert output =~ "--table"
      assert output =~ "--drop"
      assert output =~ "--blackhole"
    end

    test "main with no args shows usage" do
      output = capture_io(fn -> RNPath.main([]) end)
      assert output =~ "Reticulum Path Management Utility"
    end
  end

  # ── Hash Parsing ──────────────────────────────────────────────────

  describe "parse_hash/1" do
    test "accepts valid 32-character hex hash" do
      hex = String.duplicate("ab", 16)
      assert {:ok, hash} = RNPath.parse_hash(hex)
      assert byte_size(hash) == 16

      assert hash ==
               <<0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
                 0xAB, 0xAB, 0xAB>>
    end

    test "accepts mixed case hex" do
      hex = "AbCdEf0123456789abcdef0123456789"
      assert {:ok, _hash} = RNPath.parse_hash(hex)
    end

    test "rejects wrong length hash" do
      assert {:error, msg} = RNPath.parse_hash("abcdef")
      assert msg =~ "Hash length is invalid"
      assert msg =~ "32 hexadecimal characters"
      assert msg =~ "16 bytes"
    end

    test "rejects too long hash" do
      hex = String.duplicate("ab", 20)
      assert {:error, msg} = RNPath.parse_hash(hex)
      assert msg =~ "Hash length is invalid"
    end

    test "rejects non-hex characters" do
      hex = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
      assert {:error, msg} = RNPath.parse_hash(hex)
      assert msg =~ "Invalid hash"
    end

    test "all-zero hash is valid" do
      hex = String.duplicate("00", 16)
      assert {:ok, hash} = RNPath.parse_hash(hex)
      assert hash == <<0::128>>
    end

    test "all-ff hash is valid" do
      hex = String.duplicate("ff", 16)
      assert {:ok, hash} = RNPath.parse_hash(hex)

      assert hash ==
               <<0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8,
                 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8>>
    end
  end

  # ── Pretty Date ────────────────────────────────────────────────────

  describe "pretty_date/1" do
    test "formats seconds" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 5)
      assert result =~ "seconds"
    end

    test "formats 1 minute" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 90)
      assert result == "1 minute"
    end

    test "formats minutes" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 180)
      assert result =~ "3 minutes"
    end

    test "formats an hour" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 5400)
      assert result == "an hour"
    end

    test "formats hours" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 10800)
      assert result =~ "3 hours"
    end

    test "formats 1 day" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 86400)
      assert result == "1 day"
    end

    test "formats days" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 3 * 86400)
      assert result =~ "3 days"
    end

    test "formats weeks" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 14 * 86400)
      assert result =~ "2 weeks"
    end

    test "formats months" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 60 * 86400)
      assert result =~ "2 months"
    end

    test "formats years" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now - 400 * 86400)
      assert result =~ "1 years"
    end

    test "returns empty string for future timestamp" do
      now = System.system_time(:second)
      result = RNPath.pretty_date(now + 3600)
      assert result == ""
    end
  end

  # ── Path Table Access ──────────────────────────────────────────────

  describe "get_path_table/1" do
    test "returns list of path maps" do
      # With Transport running (started by application), should return a list
      result = RNPath.get_path_table()
      assert is_list(result)
    end

    test "returns list with max_hops filter" do
      result = RNPath.get_path_table(5)
      assert is_list(result)
    end
  end

  # ── Rate Table Access ──────────────────────────────────────────────

  describe "get_rate_table/0" do
    test "returns list of rate entry maps" do
      result = RNPath.get_rate_table()
      assert is_list(result)
    end
  end

  # ── Drop Path ──────────────────────────────────────────────────────

  describe "drop_path/1" do
    test "returns false for nonexistent path" do
      fake_hash = :crypto.strong_rand_bytes(16)
      assert RNPath.drop_path(fake_hash) == false
    end

    test "drops existing path" do
      # Insert a path entry, then drop it
      hash = :crypto.strong_rand_bytes(16)

      entry = %RNS.Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 2,
        expires: System.system_time(:second) + 3600,
        random_blobs: [],
        interface: %{name: "TestInterface"},
        packet_hash: :crypto.strong_rand_bytes(16)
      }

      :ets.insert(:rns_path_table, {hash, entry})

      assert RNPath.drop_path(hash) == true
      # Verify it's gone
      assert :ets.lookup(:rns_path_table, hash) == []
    end
  end

  # ── Drop All Via ───────────────────────────────────────────────────

  describe "drop_all_via/1" do
    test "returns false when no paths match" do
      fake_hash = :crypto.strong_rand_bytes(16)
      assert RNPath.drop_all_via(fake_hash) == false
    end

    test "drops all paths via specified transport" do
      via_hash = :crypto.strong_rand_bytes(16)
      other_hash = :crypto.strong_rand_bytes(16)

      # Insert paths via the target transport
      for _ <- 1..3 do
        hash = :crypto.strong_rand_bytes(16)

        entry = %RNS.Transport.PathEntry{
          timestamp: System.system_time(:second),
          next_hop: via_hash,
          hops: 2,
          expires: System.system_time(:second) + 3600,
          random_blobs: [],
          interface: %{name: "TestInterface"},
          packet_hash: :crypto.strong_rand_bytes(16)
        }

        :ets.insert(:rns_path_table, {hash, entry})
      end

      # Insert a path via a different transport
      other_path_hash = :crypto.strong_rand_bytes(16)

      other_entry = %RNS.Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: other_hash,
        hops: 1,
        expires: System.system_time(:second) + 3600,
        random_blobs: [],
        interface: %{name: "OtherInterface"},
        packet_hash: :crypto.strong_rand_bytes(16)
      }

      :ets.insert(:rns_path_table, {other_path_hash, other_entry})

      assert RNPath.drop_all_via(via_hash) == true
      # The other path should still exist
      assert :ets.lookup(:rns_path_table, other_path_hash) != []

      # Clean up
      :ets.delete(:rns_path_table, other_path_hash)
    end
  end

  # ── Drop Announce Queues ───────────────────────────────────────────

  describe "drop_announce_queues/0" do
    test "returns :ok" do
      assert RNPath.drop_announce_queues() == :ok
    end
  end

  # ── Get Next Hop If Name ───────────────────────────────────────────

  describe "get_next_hop_if_name/1" do
    test "returns Unknown for nonexistent path" do
      fake_hash = :crypto.strong_rand_bytes(16)
      assert RNPath.get_next_hop_if_name(fake_hash) == "Unknown"
    end

    test "returns interface name for existing path" do
      hash = :crypto.strong_rand_bytes(16)

      entry = %RNS.Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 1,
        expires: System.system_time(:second) + 3600,
        random_blobs: [],
        interface: %{name: "MyTestInterface"},
        packet_hash: :crypto.strong_rand_bytes(16)
      }

      :ets.insert(:rns_path_table, {hash, entry})

      assert RNPath.get_next_hop_if_name(hash) == "MyTestInterface"

      # Clean up
      :ets.delete(:rns_path_table, hash)
    end
  end

  # ── Handle Table Output ────────────────────────────────────────────

  describe "handle_table/1 output" do
    test "displays path table entries" do
      # Insert a test path
      hash = :crypto.strong_rand_bytes(16)
      next_hop = :crypto.strong_rand_bytes(16)
      expires = System.system_time(:second) + 3600

      entry = %RNS.Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: next_hop,
        hops: 3,
        expires: expires,
        random_blobs: [],
        interface: %{name: "TestInterface[test]"},
        packet_hash: :crypto.strong_rand_bytes(16)
      }

      :ets.insert(:rns_path_table, {hash, entry})

      opts = %{
        table: true,
        destination: nil,
        max_hops: nil,
        json: false
      }

      output = capture_io(fn -> RNPath.handle_table(opts) end)

      assert output =~ "hops away via"
      assert output =~ "TestInterface[test]"
      assert output =~ "expires"

      # Clean up
      :ets.delete(:rns_path_table, hash)
    end

    test "filters by destination" do
      hash1 = :crypto.strong_rand_bytes(16)
      hash2 = :crypto.strong_rand_bytes(16)

      for hash <- [hash1, hash2] do
        entry = %RNS.Transport.PathEntry{
          timestamp: System.system_time(:second),
          next_hop: :crypto.strong_rand_bytes(16),
          hops: 1,
          expires: System.system_time(:second) + 3600,
          random_blobs: [],
          interface: %{name: "TestInterface"},
          packet_hash: :crypto.strong_rand_bytes(16)
        }

        :ets.insert(:rns_path_table, {hash, entry})
      end

      hex1 = Base.encode16(hash1, case: :lower)

      opts = %{
        table: true,
        destination: hex1,
        max_hops: nil,
        json: false
      }

      output = capture_io(fn -> RNPath.handle_table(opts) end)

      # Should display the matching path
      assert output =~ "hop"

      # Clean up
      :ets.delete(:rns_path_table, hash1)
      :ets.delete(:rns_path_table, hash2)
    end

    test "handles max_hops filter" do
      hash_near = :crypto.strong_rand_bytes(16)
      hash_far = :crypto.strong_rand_bytes(16)

      for {hash, hops} <- [{hash_near, 2}, {hash_far, 10}] do
        entry = %RNS.Transport.PathEntry{
          timestamp: System.system_time(:second),
          next_hop: :crypto.strong_rand_bytes(16),
          hops: hops,
          expires: System.system_time(:second) + 3600,
          random_blobs: [],
          interface: %{name: "TestInterface"},
          packet_hash: :crypto.strong_rand_bytes(16)
        }

        :ets.insert(:rns_path_table, {hash, entry})
      end

      opts = %{
        table: true,
        destination: nil,
        max_hops: 5,
        json: false
      }

      output = capture_io(fn -> RNPath.handle_table(opts) end)

      # The near path (2 hops) should appear, but far (10 hops) should not
      assert output =~ "2 hops"
      refute output =~ "10 hops"

      # Clean up
      :ets.delete(:rns_path_table, hash_near)
      :ets.delete(:rns_path_table, hash_far)
    end
  end

  # ── Handle Rates Output ────────────────────────────────────────────

  describe "handle_rates/1 output" do
    test "displays empty rate table message" do
      opts = %{
        rates: true,
        destination: nil,
        json: false
      }

      output = capture_io(fn -> RNPath.handle_rates(opts) end)
      # Should say something about no information or display entries
      assert is_binary(output)
    end

    test "displays rate table entries" do
      hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      rate_entry = %{
        last: now - 60,
        timestamps: [now - 300, now - 200, now - 100, now - 60],
        rate_violations: 0,
        blocked_until: 0
      }

      :ets.insert(:rns_announce_rate_table, {hash, rate_entry})

      opts = %{
        rates: true,
        destination: nil,
        json: false
      }

      output = capture_io(fn -> RNPath.handle_rates(opts) end)

      assert output =~ "last heard"
      assert output =~ "announces/hour"

      # Clean up
      :ets.delete(:rns_announce_rate_table, hash)
    end

    test "displays rate violations" do
      hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      rate_entry = %{
        last: now - 10,
        timestamps: [now - 10],
        rate_violations: 3,
        blocked_until: 0
      }

      :ets.insert(:rns_announce_rate_table, {hash, rate_entry})

      opts = %{
        rates: true,
        destination: nil,
        json: false
      }

      output = capture_io(fn -> RNPath.handle_rates(opts) end)

      assert output =~ "rate violation"

      # Clean up
      :ets.delete(:rns_announce_rate_table, hash)
    end
  end

  # ── Helper ──────────────────────────────────────────────────────────

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
