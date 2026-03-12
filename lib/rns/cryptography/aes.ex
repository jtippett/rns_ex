defmodule RNS.Cryptography.AES do
  @moduledoc """
  AES-256-CBC encryption and decryption for RNS.

  Wraps Erlang's `:crypto` module to provide AES-256-CBC operations.
  PKCS7 padding must be applied by the caller before encryption.

  Matches `python/RNS/Cryptography/AES.py` (AES_256_CBC class).
  """

  @key_length 32

  @doc """
  Encrypts `plaintext` with AES-256-CBC.

  `plaintext` must already be PKCS7-padded to a multiple of 16 bytes.
  `key` must be exactly 32 bytes. `iv` must be exactly 16 bytes.

  Returns the ciphertext binary (same length as plaintext).
  """
  @spec encrypt(binary(), binary(), binary()) :: binary()
  def encrypt(plaintext, key, iv) do
    validate_key!(key)
    :crypto.crypto_one_time(:aes_256_cbc, key, iv, plaintext, encrypt: true)
  end

  @doc """
  Decrypts `ciphertext` with AES-256-CBC.

  `key` must be exactly 32 bytes. `iv` must be exactly 16 bytes.
  The caller should apply PKCS7 unpadding to the result.

  Returns the decrypted binary.
  """
  @spec decrypt(binary(), binary(), binary()) :: binary()
  def decrypt(ciphertext, key, iv) do
    validate_key!(key)
    :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, encrypt: false)
  end

  defp validate_key!(key) when byte_size(key) == @key_length, do: :ok

  defp validate_key!(key) do
    raise ArgumentError,
          "invalid key length #{byte_size(key) * 8} bits, expected #{@key_length * 8} bits"
  end
end
