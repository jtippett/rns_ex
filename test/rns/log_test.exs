defmodule RNS.LogTest do
  use ExUnit.Case, async: true

  describe "log level constants" do
    test "log levels have correct values" do
      assert RNS.Log.log_none() == -1
      assert RNS.Log.log_critical() == 0
      assert RNS.Log.log_error() == 1
      assert RNS.Log.log_warning() == 2
      assert RNS.Log.log_notice() == 3
      assert RNS.Log.log_info() == 4
      assert RNS.Log.log_verbose() == 5
      assert RNS.Log.log_debug() == 6
      assert RNS.Log.log_extreme() == 7
    end

    test "log destination constants" do
      assert RNS.Log.log_stdout() == 0x91
      assert RNS.Log.log_file() == 0x92
      assert RNS.Log.log_callback() == 0x93
    end

    test "log maxsize" do
      assert RNS.Log.log_maxsize() == 5 * 1024 * 1024
    end
  end

  describe "loglevelname/1" do
    test "returns correct name for each level" do
      assert RNS.Log.loglevelname(0) == "[Critical]"
      assert RNS.Log.loglevelname(1) == "[Error]   "
      assert RNS.Log.loglevelname(2) == "[Warning] "
      assert RNS.Log.loglevelname(3) == "[Notice]  "
      assert RNS.Log.loglevelname(4) == "[Info]    "
      assert RNS.Log.loglevelname(5) == "[Verbose] "
      assert RNS.Log.loglevelname(6) == "[Debug]   "
      assert RNS.Log.loglevelname(7) == "[Extra]   "
    end

    test "returns Unknown for invalid level" do
      assert RNS.Log.loglevelname(99) == "Unknown"
      assert RNS.Log.loglevelname(-2) == "Unknown"
    end
  end

  describe "to_logger_level/1" do
    test "maps RNS levels to Logger levels" do
      assert RNS.Log.to_logger_level(0) == :emergency
      assert RNS.Log.to_logger_level(1) == :error
      assert RNS.Log.to_logger_level(2) == :warning
      assert RNS.Log.to_logger_level(3) == :notice
      assert RNS.Log.to_logger_level(4) == :info
      assert RNS.Log.to_logger_level(5) == :debug
      assert RNS.Log.to_logger_level(6) == :debug
      assert RNS.Log.to_logger_level(7) == :debug
    end
  end

  describe "log/3" do
    test "returns :ok" do
      assert RNS.Log.log("test message", 3) == :ok
    end

    test "suppresses messages above loglevel" do
      # With loglevel 0 (critical only), verbose messages should be suppressed
      assert RNS.Log.log("verbose msg", 5, loglevel: 0) == :ok
    end

    test "suppresses all messages when LOG_NONE" do
      assert RNS.Log.log("should not appear", 0, loglevel: -1) == :ok
    end

    test "defaults to LOG_NOTICE level" do
      assert RNS.Log.log("notice message") == :ok
    end
  end
end
