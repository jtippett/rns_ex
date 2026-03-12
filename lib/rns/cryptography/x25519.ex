defmodule RNS.Cryptography.X25519 do
  @moduledoc """
  X25519 Elliptic Curve Diffie-Hellman key exchange for RNS.

  Wraps Erlang's `:crypto` module to provide X25519 ECDH operations.
  Matches `python/RNS/Cryptography/X25519.py` API semantics.
  """

  @key_length 32

  defstruct [:private_key, :public_key]

  @type t :: %__MODULE__{
          private_key: binary(),
          public_key: binary()
        }

  @doc """
  Generates a new random X25519 keypair.

  Returns a keypair struct with 32-byte private and public keys.
  """
  @spec generate_keypair() :: t()
  def generate_keypair do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)
    %__MODULE__{private_key: private_key, public_key: public_key}
  end

  @doc """
  Creates a keypair from raw private key bytes.

  Derives the corresponding public key from the given 32-byte private key.
  Raises `ArgumentError` if the key is not exactly 32 bytes.
  """
  @spec from_private_bytes(binary()) :: t()
  def from_private_bytes(data) when byte_size(data) == @key_length do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519, data)
    %__MODULE__{private_key: private_key, public_key: public_key}
  end

  def from_private_bytes(data) when is_binary(data) do
    raise ArgumentError,
          "X25519 private key must be #{@key_length} bytes, got #{byte_size(data)}"
  end

  @doc """
  Returns the raw private key bytes (32 bytes).
  """
  @spec private_bytes(t()) :: binary()
  def private_bytes(%__MODULE__{private_key: private_key}), do: private_key

  @doc """
  Returns the raw public key bytes (32 bytes).
  """
  @spec public_key(t()) :: binary()
  def public_key(%__MODULE__{public_key: public_key}), do: public_key

  @doc """
  Performs X25519 ECDH key exchange.

  Given our keypair and the peer's 32-byte public key, computes the
  shared secret (32 bytes). Both parties derive the same shared secret.

  Raises `ArgumentError` if the peer public key is not exactly 32 bytes.
  """
  @spec exchange(t(), binary()) :: binary()
  def exchange(%__MODULE__{private_key: private_key}, peer_public_key)
      when byte_size(peer_public_key) == @key_length do
    :crypto.compute_key(:ecdh, peer_public_key, private_key, :x25519)
  end

  def exchange(%__MODULE__{}, peer_public_key) when is_binary(peer_public_key) do
    raise ArgumentError,
          "peer public key must be #{@key_length} bytes, got #{byte_size(peer_public_key)}"
  end
end
