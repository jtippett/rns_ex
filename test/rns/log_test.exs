defmodule RNS.LogTest do
  use ExUnit.Case, async: true

  describe "log/2 with atom levels" do
    test "returns :ok for each atom level" do
      assert RNS.Log.log("test critical", :critical) == :ok
      assert RNS.Log.log("test error", :error) == :ok
      assert RNS.Log.log("test warning", :warning) == :ok
      assert RNS.Log.log("test notice", :notice) == :ok
      assert RNS.Log.log("test info", :info) == :ok
      assert RNS.Log.log("test verbose", :verbose) == :ok
      assert RNS.Log.log("test debug", :debug) == :ok
      assert RNS.Log.log("test extreme", :extreme) == :ok
    end

    test "defaults to :notice level" do
      assert RNS.Log.log("notice message") == :ok
    end
  end

  describe "log/2 with legacy integer levels" do
    test "accepts integer levels for backward compatibility" do
      assert RNS.Log.log("test message", 0) == :ok
      assert RNS.Log.log("test message", 1) == :ok
      assert RNS.Log.log("test message", 2) == :ok
      assert RNS.Log.log("test message", 3) == :ok
      assert RNS.Log.log("test message", 4) == :ok
      assert RNS.Log.log("test message", 5) == :ok
      assert RNS.Log.log("test message", 6) == :ok
      assert RNS.Log.log("test message", 7) == :ok
    end

    test "suppresses messages for LOG_NONE (-1)" do
      assert RNS.Log.log("should not appear", -1) == :ok
    end

    test "handles unknown integer levels" do
      assert RNS.Log.log("unknown level", 99) == :ok
    end
  end
end
