defmodule RNS.Cryptography.HKDF do
  @moduledoc """
  HKDF (HMAC-based Key Derivation Function) for RNS.

  Implements RFC 5869 using HMAC-SHA256. Provides both the combined
  `derive_key/4` interface and the separate `extract/2` + `expand/3` steps.

  Matches the interface from `python/RNS/Cryptography/HKDF.py`.
  """

  alias RNS.Cryptography.HMAC

  @hash_len 32

  @doc """
  Derives a key of the given length from input key material using HKDF-SHA256.

  Matches the Python `hkdf(length, derive_from, salt, context)` interface.

  ## Parameters

    * `ikm` - input key material (binary, non-empty)
    * `length` - desired output length in bytes (positive integer)
    * `salt` - optional salt value (binary or nil)
    * `info` - optional context/application-specific info (binary or nil)

  ## Raises

    * `ArgumentError` if length < 1 or ikm is empty/nil
  """
  @spec derive_key(binary(), pos_integer(), binary() | nil, binary() | nil) :: binary()
  def derive_key(ikm, length, salt, info) do
    if length == nil or length < 1 do
      raise ArgumentError, "Invalid output key length"
    end

    if ikm == nil or ikm == "" or ikm == <<>> do
      raise ArgumentError, "Cannot derive key from empty input material"
    end

    prk = extract(ikm, salt)
    expand(prk, length, info)
  end

  @doc """
  HKDF-Extract step: extracts a pseudorandom key from input key material.

  Returns a 32-byte (256-bit) pseudorandom key.

  ## Parameters

    * `ikm` - input key material
    * `salt` - optional salt (nil or empty defaults to 32 zero bytes)
  """
  @spec extract(binary(), binary() | nil) :: binary()
  def extract(ikm, salt) do
    salt = normalize_salt(salt)
    HMAC.digest(salt, ikm, :sha256)
  end

  @doc """
  HKDF-Expand step: expands a pseudorandom key to the desired length.

  ## Parameters

    * `prk` - pseudorandom key (from extract step)
    * `length` - desired output length in bytes
    * `info` - optional context info (nil defaults to empty binary)
  """
  @spec expand(binary(), pos_integer(), binary() | nil) :: binary()
  def expand(prk, length, info) do
    info = info || <<>>
    n = ceil(length / @hash_len)

    {derived, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev_block} ->
        counter = <<rem(i, 256)>>
        block = HMAC.digest(prk, prev_block <> info <> counter, :sha256)
        {acc <> block, block}
      end)

    <<result::binary-size(length), _rest::binary>> = derived
    result
  end

  defp normalize_salt(nil), do: :binary.copy(<<0>>, @hash_len)
  defp normalize_salt(<<>>), do: :binary.copy(<<0>>, @hash_len)
  defp normalize_salt(salt) when is_binary(salt), do: salt
end
