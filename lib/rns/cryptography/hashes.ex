defmodule RNS.Cryptography.Hashes do
  @moduledoc """
  SHA-256 and SHA-512 hash primitives for RNS.

  Wraps Erlang's `:crypto` module to provide SHA hash functions.
  All SHA-256/512 calls in RNS route through this module, allowing
  future platform-aware hardware acceleration.
  """

  @truncated_hashlength_bytes 16

  @doc """
  Computes the SHA-256 hash of the given data.

  Returns a 32-byte (256-bit) binary digest.
  """
  @spec sha256(binary()) :: binary()
  def sha256(data) do
    :crypto.hash(:sha256, data)
  end

  @doc """
  Computes the SHA-512 hash of the given data.

  Returns a 64-byte (512-bit) binary digest.
  """
  @spec sha512(binary()) :: binary()
  def sha512(data) do
    :crypto.hash(:sha512, data)
  end

  @doc """
  Computes a truncated SHA-256 hash of the given data.

  Returns the first 16 bytes (128 bits) of the SHA-256 digest.
  This is used throughout RNS for address hashing and deduplication.
  """
  @spec truncated_hash(binary()) :: binary()
  def truncated_hash(data) do
    <<truncated::binary-size(@truncated_hashlength_bytes), _rest::binary>> = sha256(data)
    truncated
  end
end
