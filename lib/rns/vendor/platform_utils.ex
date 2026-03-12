defmodule RNS.Vendor.PlatformUtils do
  @moduledoc """
  OS/platform detection utilities.

  Maps the Python `platformutils` module. Detects the host operating system
  and provides helper predicates for platform-specific behavior.
  """

  @doc """
  Returns the current platform identifier as a string.

  Returns `"android"`, `"linux"`, `"darwin"`, `"win32"`, etc.
  """
  @spec get_platform() :: String.t()
  def get_platform do
    case System.get_env("ANDROID_ARGUMENT") || System.get_env("ANDROID_ROOT") do
      nil -> to_string(:os.type() |> elem(1))
      _ -> "android"
    end
  end

  @doc "Returns true if running on Linux."
  @spec is_linux?() :: boolean()
  def is_linux?, do: get_platform() == "linux"

  @doc "Returns true if running on macOS."
  @spec is_darwin?() :: boolean()
  def is_darwin?, do: get_platform() == "darwin"

  @doc "Returns true if running on Android."
  @spec is_android?() :: boolean()
  def is_android?, do: get_platform() == "android"

  @doc "Returns true if running on Windows."
  @spec is_windows?() :: boolean()
  def is_windows?, do: String.starts_with?(get_platform(), "win")

  @doc "Returns true if epoll should be used (Linux/Android)."
  @spec use_epoll?() :: boolean()
  def use_epoll?, do: is_linux?() or is_android?()

  @doc "Returns true if AF_UNIX sockets should be used (Linux/Android)."
  @spec use_af_unix?() :: boolean()
  def use_af_unix?, do: is_linux?() or is_android?()
end
