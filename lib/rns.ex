defmodule RNS do
  @moduledoc """
  Elixir port of the Reticulum Network Stack.

  RNS provides encrypted, self-configuring mesh networking with zero infrastructure
  requirements. This module serves as the main entry point and public API.
  """

  @version RNS.Version.version()

  @doc """
  Returns the current RNS version string.
  """
  @spec version() :: String.t()
  def version, do: @version
end
