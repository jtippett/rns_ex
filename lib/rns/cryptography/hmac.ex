defmodule RNS.Cryptography.HMAC do
  @moduledoc """
  HMAC (Hash-based Message Authentication Code) for RNS.

  Wraps Erlang's `:crypto.mac/4` to provide HMAC-SHA256 and HMAC-SHA512.
  Matches the interface used by `python/RNS/Cryptography/HMAC.py`.
  """

  @doc """
  Computes an HMAC digest for the given key and data.

  ## Parameters

    * `key` - the secret key (binary)
    * `data` - the message to authenticate (binary)
    * `algorithm` - hash algorithm, `:sha256` (default) or `:sha512`

  ## Examples

      iex> RNS.Cryptography.HMAC.digest("key", "data")
      <<5, 11, ...>>

      iex> RNS.Cryptography.HMAC.digest("key", "data", :sha512)
      <<109, 35, ...>>

  """
  @spec digest(binary(), binary(), :sha256 | :sha512) :: binary()
  def digest(key, data, algorithm \\ :sha256) do
    :crypto.mac(:hmac, algorithm, key, data)
  end
end
