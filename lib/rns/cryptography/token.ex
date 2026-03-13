defmodule RNS.Cryptography.Token do
  @moduledoc """
  Fernet-like authenticated encryption for RNS.

  A slightly modified implementation of the Fernet spec. Per the RNS design,
  the one-byte VERSION and eight-byte TIMESTAMP fields from Fernet are stripped
  to reduce overhead and avoid leaking initiator metadata.

  Token format: `IV (16 bytes) || Ciphertext || HMAC-SHA256 (32 bytes)`

  Supports AES-128-CBC (32-byte key) and AES-256-CBC (64-byte key).
  The key is split in half: first half is the signing key (HMAC),
  second half is the encryption key (AES).
  """

  alias RNS.Cryptography.HMAC
  alias RNS.Cryptography.PKCS7

  @token_overhead 48

  defstruct [:signing_key, :encryption_key, :mode]

  @type t :: %__MODULE__{
          signing_key: binary(),
          encryption_key: binary(),
          mode: :aes_128_cbc | :aes_256_cbc
        }

  @doc """
  Returns the token overhead in bytes (16 IV + 32 HMAC = 48).
  """
  @spec token_overhead() :: non_neg_integer()
  def token_overhead, do: @token_overhead

  @doc """
  Generates a random 64-byte key for AES-256-CBC mode.
  """
  @spec generate_key() :: binary()
  def generate_key do
    :crypto.strong_rand_bytes(64)
  end

  @doc """
  Creates a new Token from a key.

  - 32-byte key → AES-128-CBC mode (16 signing + 16 encryption)
  - 64-byte key → AES-256-CBC mode (32 signing + 32 encryption)

  Raises `ArgumentError` for invalid key lengths or nil key.
  """
  @spec new(binary()) :: t()
  def new(nil) do
    raise ArgumentError, "Token key cannot be nil"
  end

  def new(key) when is_binary(key) and byte_size(key) == 32 do
    <<signing_key::binary-size(16), encryption_key::binary-size(16)>> = key

    %__MODULE__{
      signing_key: signing_key,
      encryption_key: encryption_key,
      mode: :aes_128_cbc
    }
  end

  def new(key) when is_binary(key) and byte_size(key) == 64 do
    <<signing_key::binary-size(32), encryption_key::binary-size(32)>> = key

    %__MODULE__{
      signing_key: signing_key,
      encryption_key: encryption_key,
      mode: :aes_256_cbc
    }
  end

  def new(key) when is_binary(key) do
    raise ArgumentError,
          "Token key must be 128 or 256 bits, not #{byte_size(key) * 8}"
  end

  def new(_key) do
    raise ArgumentError, "Token key must be a binary"
  end

  @doc """
  Verifies the HMAC-SHA256 on a token.

  Returns `true` if valid, `false` if tampered.
  Raises `ArgumentError` if the token is too short (≤ 32 bytes).
  """
  @spec verify_hmac(t(), binary()) :: boolean()
  def verify_hmac(%__MODULE__{}, token) when byte_size(token) <= 32 do
    raise ArgumentError,
          "Cannot verify HMAC on token of only #{byte_size(token)} bytes"
  end

  def verify_hmac(%__MODULE__{signing_key: signing_key}, token) do
    hmac_offset = byte_size(token) - 32
    <<signed_parts::binary-size(hmac_offset), received_hmac::binary-size(32)>> = token
    expected_hmac = HMAC.digest(signing_key, signed_parts)
    received_hmac == expected_hmac
  end

  @doc """
  Encrypts `data` with AES-CBC and appends HMAC-SHA256.

  Returns `IV || Ciphertext || HMAC-SHA256`.
  """
  @spec encrypt(t(), binary()) :: binary()
  def encrypt(%__MODULE__{} = token, data) when is_binary(data) do
    iv = :crypto.strong_rand_bytes(16)
    padded = PKCS7.pad(data)
    ciphertext = aes_encrypt(token.mode, padded, token.encryption_key, iv)
    signed_parts = iv <> ciphertext
    signed_parts <> HMAC.digest(token.signing_key, signed_parts)
  end

  @doc """
  Decrypts a token. Verifies HMAC first, then decrypts and unpads.

  Raises `ArgumentError` if HMAC verification fails or decryption fails.
  """
  @spec decrypt(t(), binary()) :: binary()
  def decrypt(%__MODULE__{} = token, ciphertoken) when is_binary(ciphertoken) do
    unless verify_hmac(token, ciphertoken) do
      raise ArgumentError, "Token HMAC was invalid"
    end

    <<iv::binary-size(16), rest::binary>> = ciphertoken
    ciphertext_len = byte_size(rest) - 32
    <<ciphertext::binary-size(ciphertext_len), _hmac::binary-size(32)>> = rest

    try do
      padded = aes_decrypt(token.mode, ciphertext, token.encryption_key, iv)
      PKCS7.unpad(padded)
    rescue
      e ->
        reraise ArgumentError, "Could not decrypt token: #{Exception.message(e)}", __STACKTRACE__
    end
  end

  defp aes_encrypt(:aes_256_cbc, plaintext, key, iv) do
    :crypto.crypto_one_time(:aes_256_cbc, key, iv, plaintext, encrypt: true)
  end

  defp aes_encrypt(:aes_128_cbc, plaintext, key, iv) do
    :crypto.crypto_one_time(:aes_128_cbc, key, iv, plaintext, encrypt: true)
  end

  defp aes_decrypt(:aes_256_cbc, ciphertext, key, iv) do
    :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, encrypt: false)
  end

  defp aes_decrypt(:aes_128_cbc, ciphertext, key, iv) do
    :crypto.crypto_one_time(:aes_128_cbc, key, iv, ciphertext, encrypt: false)
  end
end
