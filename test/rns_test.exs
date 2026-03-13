defmodule RNSTest do
  use ExUnit.Case, async: true

  # ── Application & Version ──────────────────────────────────────

  describe "application" do
    test "starts successfully" do
      assert {:ok, _pid} = Application.ensure_all_started(:rns_ex)
    end
  end

  describe "version/0" do
    test "returns a string" do
      assert is_binary(RNS.version())
    end

    test "matches mix project version" do
      assert RNS.version() == "0.1.0"
    end

    test "matches RNS.Version.version/0" do
      assert RNS.version() == RNS.Version.version()
    end
  end

  describe "host_os/0" do
    test "returns a recognized platform string" do
      assert RNS.host_os() in ["darwin", "linux", "windows", "freebsd", "unknown"]
    end
  end

  # ── Log Level Constants ────────────────────────────────────────

  describe "log level constants" do
    test "log_none returns -1" do
      assert RNS.log_none() == -1
    end

    test "log_critical returns 0" do
      assert RNS.log_critical() == 0
    end

    test "log_error returns 1" do
      assert RNS.log_error() == 1
    end

    test "log_warning returns 2" do
      assert RNS.log_warning() == 2
    end

    test "log_notice returns 3" do
      assert RNS.log_notice() == 3
    end

    test "log_info returns 4" do
      assert RNS.log_info() == 4
    end

    test "log_verbose returns 5" do
      assert RNS.log_verbose() == 5
    end

    test "log_debug returns 6" do
      assert RNS.log_debug() == 6
    end

    test "log_extreme returns 7" do
      assert RNS.log_extreme() == 7
    end
  end

  describe "log destination constants" do
    test "log_stdout returns 0x91" do
      assert RNS.log_stdout() == 0x91
    end

    test "log_file returns 0x92" do
      assert RNS.log_file() == 0x92
    end

    test "log_callback returns 0x93" do
      assert RNS.log_callback() == 0x93
    end

    test "log_maxsize returns 5MB" do
      assert RNS.log_maxsize() == 5 * 1024 * 1024
    end
  end

  # ── Logging Functions ──────────────────────────────────────────

  describe "log/2" do
    test "logs with default level (notice)" do
      assert RNS.log("test message") == :ok
    end

    test "logs at specific level" do
      assert RNS.log("debug message", RNS.log_debug()) == :ok
    end
  end

  describe "loglevelname/1" do
    test "returns correct names for all levels" do
      assert RNS.loglevelname(0) == "[Critical]"
      assert RNS.loglevelname(1) == "[Error]   "
      assert RNS.loglevelname(2) == "[Warning] "
      assert RNS.loglevelname(3) == "[Notice]  "
      assert RNS.loglevelname(4) == "[Info]    "
      assert RNS.loglevelname(5) == "[Verbose] "
      assert RNS.loglevelname(6) == "[Debug]   "
      assert RNS.loglevelname(7) == "[Extra]   "
    end

    test "returns Unknown for invalid levels" do
      assert RNS.loglevelname(99) == "Unknown"
      assert RNS.loglevelname(-2) == "Unknown"
    end
  end

  describe "timestamp_str/1" do
    test "formats epoch time as readable string" do
      result = RNS.timestamp_str(1_700_000_000)
      assert result =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
    end

    test "handles zero epoch" do
      result = RNS.timestamp_str(0)
      assert result == "1970-01-01 00:00:00"
    end
  end

  describe "precise_timestamp_str/1" do
    test "returns HH:MM:SS.mmm format" do
      result = RNS.precise_timestamp_str(0)
      assert String.match?(result, ~r/^\d{2}:\d{2}:\d{2}\.\d{3}$/)
    end
  end

  describe "trace_exception/1" do
    test "logs exception without crashing" do
      try do
        raise "test error"
      rescue
        e ->
          assert RNS.trace_exception(e, __STACKTRACE__) == :ok
      end
    end

    test "logs without stacktrace" do
      try do
        raise "test error"
      rescue
        e ->
          assert RNS.trace_exception(e) == :ok
      end
    end
  end

  # ── Randomness ─────────────────────────────────────────────────

  describe "rand/0" do
    test "returns a float in [0.0, 1.0)" do
      for _ <- 1..100 do
        r = RNS.rand()
        assert is_float(r)
        assert r >= 0.0
        assert r < 1.0
      end
    end

    test "returns different values on successive calls" do
      values = for _ <- 1..10, do: RNS.rand()
      # At least 2 distinct values in 10 calls
      assert MapSet.size(MapSet.new(values)) >= 2
    end
  end

  # ── Hex Formatting ─────────────────────────────────────────────

  describe "hexrep/2" do
    test "formats with delimiters by default" do
      assert RNS.hexrep(<<0xDE, 0xAD, 0xBE, 0xEF>>) == "de:ad:be:ef"
    end

    test "formats without delimiters" do
      assert RNS.hexrep(<<0xDE, 0xAD>>, false) == "dead"
    end

    test "handles empty binary" do
      assert RNS.hexrep(<<>>) == ""
    end

    test "handles single byte" do
      assert RNS.hexrep(<<0x0A>>) == "0a"
    end
  end

  describe "prettyhexrep/1" do
    test "wraps hex in angle brackets" do
      assert RNS.prettyhexrep(<<0xDE, 0xAD>>) == "<dead>"
    end

    test "handles empty binary" do
      assert RNS.prettyhexrep(<<>>) == "<>"
    end
  end

  # ── Size Formatting ────────────────────────────────────────────

  describe "prettysize/2" do
    test "formats bytes without SI prefix" do
      assert RNS.prettysize(500) == "500 B"
    end

    test "formats kilobytes" do
      assert RNS.prettysize(1000) == "1.00 KB"
    end

    test "formats megabytes" do
      assert RNS.prettysize(1_000_000) == "1.00 MB"
    end

    test "formats with bits suffix" do
      assert RNS.prettysize(125, "b") == "1.00 Kb"
    end
  end

  describe "prettyspeed/2" do
    test "formats speed in bps" do
      # Default suffix is "b" (bits): prettysize(8000/8, "b") + "ps"
      # prettysize(1000, "b") = 1000*8=8000 -> "8.00 Kbps"
      assert RNS.prettyspeed(8000) == "8.00 Kbps"
    end

    test "formats speed in Bps" do
      assert RNS.prettyspeed(8000, "B") == "1.00 KBps"
    end
  end

  describe "prettyfrequency/2" do
    test "formats MHz" do
      assert RNS.prettyfrequency(868_000_000) == "868.00 MHz"
    end

    test "formats GHz" do
      assert RNS.prettyfrequency(2_400_000_000) == "2.40 GHz"
    end
  end

  describe "prettydistance/2" do
    test "formats kilometers" do
      assert RNS.prettydistance(1500.0) == "1.50 Km"
    end

    test "formats meters" do
      assert RNS.prettydistance(5.0) == "5.00 m"
    end
  end

  # ── Time Formatting ────────────────────────────────────────────

  describe "prettytime/2" do
    test "formats zero" do
      assert RNS.prettytime(0) == "0s"
    end

    test "formats seconds" do
      assert RNS.prettytime(30) == "30s"
    end

    test "formats minutes and seconds" do
      assert RNS.prettytime(90) == "1m and 30s"
    end

    test "formats hours, minutes, seconds" do
      assert RNS.prettytime(3661.5) == "1h, 1m and 1.5s"
    end

    test "formats with verbose option" do
      assert RNS.prettytime(90061, verbose: true) == "1 day, 1 hour, 1 minute and 1 second"
    end

    test "formats with compact option" do
      assert RNS.prettytime(90061, compact: true) == "1d and 1h"
    end

    test "formats negative time" do
      result = RNS.prettytime(-60)
      assert result == "-1m"
    end
  end

  describe "prettyshorttime/2" do
    test "formats milliseconds and microseconds" do
      assert RNS.prettyshorttime(0.0015) == "1ms and 500µs"
    end

    test "formats seconds and milliseconds" do
      assert RNS.prettyshorttime(1.5) == "1s and 500ms"
    end

    test "formats zero" do
      assert RNS.prettyshorttime(0) == "0us"
    end
  end

  # ── Physical Layer Info ────────────────────────────────────────

  describe "phyparams/0" do
    test "prints physical layer parameters" do
      output = ExUnit.CaptureIO.capture_io(fn -> RNS.phyparams() end)

      assert output =~ "Required Physical Layer MTU"
      assert output =~ "Plaintext Packet MDU"
      assert output =~ "Encrypted Packet MDU"
      assert output =~ "Link Curve"
      assert output =~ "Link Packet MDU"
      assert output =~ "Link Public Key Size"
      assert output =~ "Link Private Key Size"
      assert output =~ "bytes"
      assert output =~ "bits"
    end

    test "returns :ok" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert RNS.phyparams() == :ok
      end)
    end
  end

  # ── Module Accessibility ───────────────────────────────────────

  describe "core module exports" do
    test "RNS.Reticulum is accessible" do
      assert function_exported?(RNS.Reticulum, :mtu, 0)
    end

    test "RNS.Identity is accessible" do
      assert function_exported?(RNS.Identity, :new, 0)
      assert function_exported?(RNS.Identity, :new, 1)
    end

    test "RNS.Destination is accessible" do
      Code.ensure_loaded!(RNS.Destination)
      # new/5 with default last arg means both /4 and /5 are exported
      assert function_exported?(RNS.Destination, :new, 4)
      assert function_exported?(RNS.Destination, :new, 5)
    end

    test "RNS.Transport is accessible" do
      Code.ensure_loaded!(RNS.Transport)
      assert function_exported?(RNS.Transport, :register_destination, 1)
    end

    test "RNS.Packet is accessible" do
      assert function_exported?(RNS.Packet, :mtu, 0)
      assert function_exported?(RNS.Packet, :plain_mdu, 0)
      assert function_exported?(RNS.Packet, :encrypted_mdu, 0)
    end

    test "RNS.PacketReceipt is accessible" do
      assert is_atom(RNS.PacketReceipt)
      assert Code.ensure_loaded?(RNS.PacketReceipt)
    end

    test "RNS.Link is accessible" do
      assert function_exported?(RNS.Link, :ecpubsize, 0)
      assert function_exported?(RNS.Link, :keysize, 0)
      assert function_exported?(RNS.Link, :mdu, 0)
    end

    test "RNS.Channel is accessible" do
      assert Code.ensure_loaded?(RNS.Channel)
    end

    test "RNS.Channel.MessageBase behaviour is accessible" do
      assert Code.ensure_loaded?(RNS.Channel.MessageBase)
    end

    test "RNS.Buffer is accessible" do
      Code.ensure_loaded!(RNS.Buffer)
      assert function_exported?(RNS.Buffer, :create_reader, 2)
      assert function_exported?(RNS.Buffer, :create_writer, 2)
    end

    test "RNS.Buffer.RawChannelReader is accessible" do
      assert Code.ensure_loaded?(RNS.Buffer.RawChannelReader)
    end

    test "RNS.Buffer.RawChannelWriter is accessible" do
      assert Code.ensure_loaded?(RNS.Buffer.RawChannelWriter)
    end

    test "RNS.Resource is accessible" do
      assert Code.ensure_loaded?(RNS.Resource)
    end

    test "RNS.Resource.Advertisement is accessible" do
      assert Code.ensure_loaded?(RNS.Resource.Advertisement)
    end

    test "RNS.Resolver is accessible" do
      assert Code.ensure_loaded?(RNS.Resolver)
    end

    test "RNS.RequestReceipt is accessible" do
      assert Code.ensure_loaded?(RNS.RequestReceipt)
    end

    test "RNS.Discovery is accessible" do
      assert Code.ensure_loaded?(RNS.Discovery)
    end

    test "RNS.Discovery.InterfaceAnnouncer is accessible" do
      assert Code.ensure_loaded?(RNS.Discovery.InterfaceAnnouncer)
    end
  end

  describe "cryptography module exports" do
    test "RNS.Cryptography.Hashes is accessible" do
      assert function_exported?(RNS.Cryptography.Hashes, :sha256, 1)
      assert function_exported?(RNS.Cryptography.Hashes, :truncated_hash, 1)
    end

    test "RNS.Cryptography.HKDF is accessible" do
      assert function_exported?(RNS.Cryptography.HKDF, :derive_key, 4)
    end

    test "RNS.Cryptography.HMAC is accessible" do
      assert Code.ensure_loaded?(RNS.Cryptography.HMAC)
    end

    test "RNS.Cryptography.AES is accessible" do
      assert Code.ensure_loaded?(RNS.Cryptography.AES)
    end

    test "RNS.Cryptography.X25519 is accessible" do
      assert function_exported?(RNS.Cryptography.X25519, :generate_keypair, 0)
    end

    test "RNS.Cryptography.Ed25519 is accessible" do
      assert function_exported?(RNS.Cryptography.Ed25519, :generate_keypair, 0)
    end

    test "RNS.Cryptography.Token is accessible" do
      assert function_exported?(RNS.Cryptography.Token, :generate_key, 0)
    end

    test "RNS.Cryptography re-exports all crypto modules" do
      assert Code.ensure_loaded?(RNS.Cryptography)
    end
  end

  # ── Identity + Destination Integration ─────────────────────────

  describe "Identity and Destination creation" do
    test "creates an identity with keys" do
      identity = RNS.Identity.new()
      assert is_struct(identity, RNS.Identity)
      assert identity.pub_bytes != nil
      assert identity.prv_bytes != nil
    end

    test "identity hash is a 16-byte truncated hash" do
      identity = RNS.Identity.new()
      assert is_binary(identity.hash)
      # Identity hash is truncated_hash (128 bits = 16 bytes)
      assert byte_size(identity.hash) == 16
    end

    test "identity hexhash is a hex string" do
      identity = RNS.Identity.new()
      assert is_binary(identity.hexhash)
      # 16 bytes = 32 hex chars
      assert String.match?(identity.hexhash, ~r/^[0-9a-f]{32}$/)
    end

    test "creates a destination from identity" do
      identity = RNS.Identity.new()

      destination =
        RNS.Destination.new(
          identity,
          RNS.Destination.direction_in(),
          RNS.Destination.single(),
          "testapp",
          ["service"]
        )

      assert is_struct(destination, RNS.Destination)
      assert is_binary(destination.hash)
      # Destination hash is truncated hash: 128 bits = 16 bytes
      assert byte_size(destination.hash) == 16
    end

    test "destination hash is representable with hexrep" do
      identity = RNS.Identity.new()

      destination =
        RNS.Destination.new(
          identity,
          RNS.Destination.direction_out(),
          RNS.Destination.single(),
          "myapp",
          ["echo"]
        )

      hex = RNS.hexrep(destination.hash)
      assert is_binary(hex)
      assert String.contains?(hex, ":")
    end

    test "identity sign/verify roundtrip" do
      identity = RNS.Identity.new()
      message = "Hello, Reticulum!"
      signature = RNS.Identity.sign(identity, message)
      assert RNS.Identity.validate(identity, signature, message)
    end

    test "identity encrypt/decrypt roundtrip" do
      identity = RNS.Identity.new()
      plaintext = "Secret message for the mesh network"
      ciphertext = RNS.Identity.encrypt(identity, plaintext)
      decrypted = RNS.Identity.decrypt(identity, ciphertext)
      assert decrypted == plaintext
    end
  end

  # ── Protocol Constants ─────────────────────────────────────────

  describe "protocol constants" do
    test "MTU is 500 bytes" do
      assert RNS.Reticulum.mtu() == 500
    end

    test "packet plain MDU matches spec" do
      assert RNS.Packet.plain_mdu() > 0
      assert RNS.Packet.plain_mdu() < 500
    end

    test "packet encrypted MDU matches spec" do
      assert RNS.Packet.encrypted_mdu() > 0
      assert RNS.Packet.encrypted_mdu() < RNS.Packet.plain_mdu()
    end

    test "link key sizes are correct" do
      assert RNS.Link.ecpubsize() == 64
      assert RNS.Link.keysize() == 32
    end

    test "link MDU is positive and less than MTU" do
      assert RNS.Link.mdu() > 0
      assert RNS.Link.mdu() < 500
    end

    test "identity curve is Curve25519" do
      assert RNS.Identity.curve() == "Curve25519"
    end

    test "identity hash length is 256 bits" do
      assert RNS.Identity.hashlength() == 256
    end

    test "identity truncated hash length is 128 bits" do
      assert RNS.Identity.truncated_hashlength() == 128
    end
  end

  # ── Top-level RNS function completeness ────────────────────────

  describe "public API completeness" do
    test "all expected functions are exported from RNS module" do
      expected_functions = [
        {:version, 0},
        {:host_os, 0},
        {:log, 1},
        {:log, 2},
        {:loglevelname, 1},
        {:timestamp_str, 1},
        {:precise_timestamp_str, 1},
        {:trace_exception, 1},
        {:rand, 0},
        {:hexrep, 1},
        {:hexrep, 2},
        {:prettyhexrep, 1},
        {:prettysize, 1},
        {:prettysize, 2},
        {:prettyspeed, 1},
        {:prettyspeed, 2},
        {:prettyfrequency, 1},
        {:prettyfrequency, 2},
        {:prettydistance, 1},
        {:prettydistance, 2},
        {:prettytime, 1},
        {:prettytime, 2},
        {:prettyshorttime, 1},
        {:prettyshorttime, 2},
        {:phyparams, 0},
        {:panic, 0},
        {:rns_exit, 0},
        {:rns_exit, 1},
        # Log level constants
        {:log_none, 0},
        {:log_critical, 0},
        {:log_error, 0},
        {:log_warning, 0},
        {:log_notice, 0},
        {:log_info, 0},
        {:log_verbose, 0},
        {:log_debug, 0},
        {:log_extreme, 0},
        # Log destination constants
        {:log_stdout, 0},
        {:log_file, 0},
        {:log_callback, 0},
        {:log_maxsize, 0}
      ]

      for {func, arity} <- expected_functions do
        assert function_exported?(RNS, func, arity),
               "Expected RNS.#{func}/#{arity} to be exported"
      end
    end
  end
end
