defmodule RNS.UtilitiesTest do
  use ExUnit.Case, async: true

  describe "hexrep/2" do
    test "formats binary with delimiters by default" do
      assert RNS.hexrep(<<0xDE, 0xAD, 0xBE, 0xEF>>) == "de:ad:be:ef"
    end

    test "formats binary without delimiters" do
      assert RNS.hexrep(<<0xDE, 0xAD>>, false) == "dead"
    end

    test "handles single byte" do
      assert RNS.hexrep(<<0xFF>>) == "ff"
    end

    test "handles empty binary" do
      assert RNS.hexrep(<<>>) == ""
    end

    test "handles zero bytes" do
      assert RNS.hexrep(<<0x00, 0x00>>) == "00:00"
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

  describe "prettysize/2" do
    test "formats bytes" do
      assert RNS.prettysize(500) == "500 B"
    end

    test "formats kilobytes" do
      assert RNS.prettysize(1000) == "1.00 KB"
    end

    test "formats megabytes" do
      assert RNS.prettysize(1_500_000) == "1.50 MB"
    end

    test "formats gigabytes" do
      assert RNS.prettysize(2_500_000_000) == "2.50 GB"
    end

    test "formats with bits suffix" do
      # 500 bytes * 8 = 4000 bits = 4.00 Kb
      assert RNS.prettysize(500, "b") == "4.00 Kb"
    end
  end

  describe "prettyfrequency/2" do
    test "formats Hz frequency" do
      assert RNS.prettyfrequency(868.0) == "868.00 Hz"
    end

    test "formats MHz frequency" do
      assert RNS.prettyfrequency(868_000_000) == "868.00 MHz"
    end

    test "formats GHz frequency" do
      assert RNS.prettyfrequency(2_400_000_000) == "2.40 GHz"
    end

    test "formats KHz frequency" do
      assert RNS.prettyfrequency(433_000) == "433.00 KHz"
    end
  end

  describe "prettydistance/2" do
    test "formats kilometers" do
      assert RNS.prettydistance(1500.0) == "1.50 Km"
    end

    test "formats meters" do
      assert RNS.prettydistance(5.0) == "5.00 m"
    end

    test "formats centimeters" do
      assert RNS.prettydistance(0.05) == "5.00 cm"
    end

    test "formats millimeters" do
      assert RNS.prettydistance(0.005) == "5.00 mm"
    end
  end

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

    test "formats hours, minutes and seconds" do
      assert RNS.prettytime(3661.5) == "1h, 1m and 1.5s"
    end

    test "formats days" do
      assert RNS.prettytime(90061) == "1d, 1h, 1m and 1s"
    end

    test "verbose mode uses full words" do
      assert RNS.prettytime(90061, verbose: true) == "1 day, 1 hour, 1 minute and 1 second"
    end

    test "verbose mode pluralizes correctly" do
      assert RNS.prettytime(180_122, verbose: true) == "2 days, 2 hours, 2 minutes and 2 seconds"
    end

    test "compact mode limits to 2 components" do
      assert RNS.prettytime(90061, compact: true) == "1d and 1h"
    end

    test "handles negative time" do
      assert RNS.prettytime(-90) == "-1m and 30s"
    end
  end

  describe "prettyshorttime/2" do
    test "formats zero" do
      assert RNS.prettyshorttime(0) == "0us"
    end

    test "formats milliseconds" do
      assert RNS.prettyshorttime(0.001) == "1ms"
    end

    test "formats seconds and milliseconds" do
      assert RNS.prettyshorttime(1.5) == "1s and 500ms"
    end

    test "formats milliseconds and microseconds" do
      assert RNS.prettyshorttime(0.0015) == "1ms and 500µs"
    end

    test "handles negative time" do
      result = RNS.prettyshorttime(-0.001)
      assert String.starts_with?(result, "-")
    end
  end

  describe "log level re-exports" do
    test "RNS module re-exports log level constants" do
      assert RNS.log_none() == -1
      assert RNS.log_critical() == 0
      assert RNS.log_error() == 1
      assert RNS.log_warning() == 2
      assert RNS.log_notice() == 3
      assert RNS.log_info() == 4
      assert RNS.log_verbose() == 5
      assert RNS.log_debug() == 6
      assert RNS.log_extreme() == 7
    end
  end

  describe "host_os/0" do
    test "returns a string" do
      assert is_binary(RNS.host_os())
    end

    test "returns a known platform" do
      platform = RNS.host_os()
      assert platform in ["linux", "darwin", "win32", "freebsd", "android"]
    end
  end

  describe "log/2 delegation" do
    test "delegates to RNS.Log" do
      assert RNS.log("test", 3) == :ok
    end
  end
end
