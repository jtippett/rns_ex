defmodule RNS.Cryptography.Ed25519 do
  @moduledoc """
  Ed25519 digital signatures for RNS.

  Wraps the `eddy` hex package to provide Ed25519 signing and verification.
  """

  @key_length 32
  @sig_length 64

  defstruct [:private_key, :public_key]

  @type t :: %__MODULE__{
          private_key: binary() | nil,
          public_key: binary()
        }

  @doc """
  Generates a new random Ed25519 keypair.

  Returns a keypair struct with 32-byte private key (seed) and 32-byte public key.
  """
  @spec generate_keypair() :: t()
  def generate_keypair do
    seed = :crypto.strong_rand_bytes(@key_length)
    from_private_bytes(seed)
  end

  @doc """
  Creates a keypair from a 32-byte private key seed.

  Derives the corresponding Ed25519 public key from the given seed.
  Raises `ArgumentError` if the seed is not exactly 32 bytes.
  """
  @spec from_private_bytes(binary()) :: t()
  def from_private_bytes(seed) when byte_size(seed) == @key_length do
    priv = %Eddy.PrivKey{d: seed}
    pub_bytes = Eddy.get_pubkey(priv, encoding: :raw)
    %__MODULE__{private_key: seed, public_key: pub_bytes}
  end

  def from_private_bytes(data) when is_binary(data) do
    raise ArgumentError,
          "Ed25519 private key seed must be #{@key_length} bytes, got #{byte_size(data)}"
  end

  @doc """
  Creates a public-key-only struct from raw 32-byte public key bytes.

  Useful for verification when only the public key is available.
  Raises `ArgumentError` if the key is not exactly 32 bytes.
  """
  @spec from_public_bytes(binary()) :: t()
  def from_public_bytes(data) when byte_size(data) == @key_length do
    %__MODULE__{private_key: nil, public_key: data}
  end

  def from_public_bytes(data) when is_binary(data) do
    raise ArgumentError,
          "Ed25519 public key must be #{@key_length} bytes, got #{byte_size(data)}"
  end

  @doc """
  Returns the raw private key seed bytes (32 bytes).
  """
  @spec private_bytes(t()) :: binary()
  def private_bytes(%__MODULE__{private_key: private_key}), do: private_key

  @doc """
  Returns the raw public key bytes (32 bytes).
  """
  @spec public_key(t()) :: binary()
  def public_key(%__MODULE__{public_key: public_key}), do: public_key

  @doc """
  Signs a message with the keypair's private key.

  Returns a 64-byte raw Ed25519 signature.
  """
  @spec sign(t(), binary()) :: binary()
  def sign(%__MODULE__{private_key: seed}, message)
      when is_binary(seed) and is_binary(message) do
    priv = %Eddy.PrivKey{d: seed}
    Eddy.sign(message, priv, encoding: :raw)
  end

  @doc """
  Verifies an Ed25519 signature against a message and public key.

  Accepts the public key as raw 32-byte binary or as a keypair struct.
  Returns `true` if valid, `false` otherwise.
  """
  @spec verify(binary(), binary(), binary() | t()) :: boolean()
  def verify(signature, message, %__MODULE__{public_key: pub_bytes}) do
    verify(signature, message, pub_bytes)
  end

  def verify(signature, message, pub_bytes)
      when byte_size(signature) == @sig_length and is_binary(message) and
             byte_size(pub_bytes) == @key_length do
    try do
      case Eddy.verify(signature, message, pub_bytes, encoding: :raw) do
        true -> true
        _ -> false
      end
    rescue
      # Eddy raises WithClauseError when signature contains invalid curve points
      _ -> false
    end
  end

  def verify(_signature, _message, _pub_bytes), do: false
end
