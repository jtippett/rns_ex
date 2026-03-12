defmodule RNS.Version do
  @moduledoc """
  Version information for the RNS Elixir port.
  """

  @version "0.1.0"

  @doc """
  Returns the current version string.
  """
  @spec version() :: String.t()
  def version, do: @version
end
