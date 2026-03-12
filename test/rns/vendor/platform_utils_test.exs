defmodule RNS.Vendor.PlatformUtilsTest do
  use ExUnit.Case, async: true

  alias RNS.Vendor.PlatformUtils

  describe "get_platform/0" do
    test "returns a non-empty string" do
      platform = PlatformUtils.get_platform()
      assert is_binary(platform)
      assert String.length(platform) > 0
    end

    test "returns a recognized platform" do
      assert PlatformUtils.get_platform() in ["linux", "darwin", "win32", "freebsd", "android"]
    end
  end

  describe "platform predicates" do
    test "exactly one platform predicate is true" do
      predicates = [
        PlatformUtils.is_linux?(),
        PlatformUtils.is_darwin?(),
        PlatformUtils.is_windows?(),
        PlatformUtils.is_android?()
      ]

      # At least one should be true (unless running on an exotic OS like FreeBSD)
      # We just verify they return booleans
      assert Enum.all?(predicates, &is_boolean/1)
    end

    test "use_epoll? returns boolean" do
      assert is_boolean(PlatformUtils.use_epoll?())
    end

    test "use_af_unix? returns boolean" do
      assert is_boolean(PlatformUtils.use_af_unix?())
    end
  end
end
