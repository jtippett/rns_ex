defmodule RNS.Cryptography.PKCS7 do
  @moduledoc """
  PKCS7 padding for block ciphers.

  Implements PKCS7 padding as used by RNS for AES-CBC encryption.
  Default block size is 16 bytes (128 bits), matching AES block size.

  Matches `python/RNS/Cryptography/PKCS7.py`.
  """

  @block_size 16

  @doc """
  Pads `data` to a multiple of `block_size` using PKCS7 padding.

  Appends `n` bytes each with value `n`, where `n` is the number of
  padding bytes needed. If `data` is already block-aligned, a full
  block of padding is added.

  ## Examples

      iex> RNS.Cryptography.PKCS7.pad(<<1, 2, 3>>)
      <<1, 2, 3, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13>>

  """
  @spec pad(binary(), pos_integer()) :: binary()
  def pad(data, block_size \\ @block_size) do
    n = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<n>>, n)
  end

  @doc """
  Removes PKCS7 padding from `data`.

  Reads the last byte to determine padding length, validates it,
  and strips the padding bytes.

  Raises `ArgumentError` if the padding is invalid.

  ## Examples

      iex> RNS.Cryptography.PKCS7.unpad(<<1, 2, 3, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13>>)
      <<1, 2, 3>>

  """
  @spec unpad(binary(), pos_integer()) :: binary()
  def unpad(data, block_size \\ @block_size)

  def unpad(<<>>, _block_size) do
    raise ArgumentError, "cannot unpad empty data"
  end

  def unpad(data, block_size) do
    n = :binary.last(data)

    if n == 0 or n > block_size do
      raise ArgumentError,
            "cannot unpad, invalid padding length of #{n} bytes"
    end

    keep = byte_size(data) - n
    <<unpadded::binary-size(keep), _::binary>> = data
    unpadded
  end
end
