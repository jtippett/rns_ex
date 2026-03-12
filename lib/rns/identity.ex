defmodule RNS.Identity do
  @moduledoc """
  Manages identities in the Reticulum Network Stack.

  Provides methods for encryption, decryption, signatures and verification,
  and is the basis for all encrypted communication over Reticulum networks.

  Each identity has an X25519 keypair for encryption and an Ed25519 keypair
  for signing. The identity hash is a truncated SHA-256 of the concatenated
  public keys.

  Matches `python/RNS/Identity.py`.
  """

  alias RNS.Cryptography.X25519
  alias RNS.Cryptography.Ed25519
  alias RNS.Cryptography.Token
  alias RNS.Cryptography.HKDF
  alias RNS.Cryptography.Hashes

  @curve "Curve25519"
  @keysize 512
  @ratchetsize 256
  @ratchet_expiry 60 * 60 * 24 * 30
  @token_overhead Token.token_overhead()
  @hashlength 256
  @siglength @keysize
  @name_hash_length 80
  @truncated_hashlength 128
  @derived_key_length div(512, 8)
  defstruct [
    :prv_bytes,
    :sig_prv_bytes,
    :pub_bytes,
    :sig_pub_bytes,
    :hash,
    :hexhash,
    :app_data
  ]

  @type t :: %__MODULE__{
          prv_bytes: binary() | nil,
          sig_prv_bytes: binary() | nil,
          pub_bytes: binary() | nil,
          sig_pub_bytes: binary() | nil,
          hash: binary() | nil,
          hexhash: String.t() | nil,
          app_data: binary() | nil
        }

  # --- Constants accessors ---

  @doc "The curve used for ECDH key exchanges."
  @spec curve() :: String.t()
  def curve, do: @curve

  @doc "Key size in bits (256 encryption + 256 signing)."
  @spec keysize() :: non_neg_integer()
  def keysize, do: @keysize

  @doc "Hash length in bits."
  @spec hashlength() :: non_neg_integer()
  def hashlength, do: @hashlength

  @doc "Name hash length in bits."
  @spec name_hash_length() :: non_neg_integer()
  def name_hash_length, do: @name_hash_length

  @doc "Truncated hash length in bits."
  @spec truncated_hashlength() :: non_neg_integer()
  def truncated_hashlength, do: @truncated_hashlength

  @doc "Ratchet size in bits."
  @spec ratchetsize() :: non_neg_integer()
  def ratchetsize, do: @ratchetsize

  @doc "Ratchet expiry in seconds (30 days)."
  @spec ratchet_expiry() :: non_neg_integer()
  def ratchet_expiry, do: @ratchet_expiry

  @doc "Signature length in bits (equals KEYSIZE)."
  @spec siglength() :: non_neg_integer()
  def siglength, do: @siglength

  @doc "Token overhead in bytes."
  @spec token_overhead() :: non_neg_integer()
  def token_overhead, do: @token_overhead

  @doc "Derived key length in bytes."
  @spec derived_key_length() :: non_neg_integer()
  def derived_key_length, do: @derived_key_length

  # --- Identity creation ---

  @doc """
  Creates a new Identity.

  By default generates fresh encryption and signing keys.
  Pass `create_keys: false` to create an empty identity for later key loading.

  ## Examples

      iex> id = RNS.Identity.new()
      iex> byte_size(id.hash)
      16

      iex> id = RNS.Identity.new(create_keys: false)
      iex> id.hash
      nil
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id = %__MODULE__{}

    if Keyword.get(opts, :create_keys, true) do
      create_keys(id)
    else
      id
    end
  end

  @doc """
  Generates fresh X25519 and Ed25519 keypairs for the identity.
  """
  @spec create_keys(t()) :: t()
  def create_keys(%__MODULE__{} = id) do
    enc_kp = X25519.generate_keypair()
    sig_kp = Ed25519.generate_keypair()

    %{
      id
      | prv_bytes: X25519.private_bytes(enc_kp),
        pub_bytes: X25519.public_key(enc_kp),
        sig_prv_bytes: Ed25519.private_bytes(sig_kp),
        sig_pub_bytes: Ed25519.public_key(sig_kp)
    }
    |> update_hashes()
  end

  # --- Key accessors ---

  @doc "Returns the full private key (64 bytes: encryption + signing)."
  @spec get_private_key(t()) :: binary()
  def get_private_key(%__MODULE__{prv_bytes: prv, sig_prv_bytes: sig_prv}) do
    prv <> sig_prv
  end

  @doc "Returns the full public key (64 bytes: encryption + signing)."
  @spec get_public_key(t()) :: binary()
  def get_public_key(%__MODULE__{pub_bytes: pub, sig_pub_bytes: sig_pub}) do
    pub <> sig_pub
  end

  # --- Key loading ---

  @doc """
  Loads a 64-byte private key into the identity, deriving all public keys.

  Returns `{:ok, updated_identity}` on success, `{:error, reason}` on failure.
  """
  @spec load_private_key(t(), binary()) :: {:ok, t()} | {:error, term()}
  def load_private_key(%__MODULE__{} = id, prv_bytes) when is_binary(prv_bytes) do
    half = div(@keysize, 8 * 2)

    if byte_size(prv_bytes) < half * 2 do
      {:error, :invalid_key_length}
    else
      try do
        <<enc_prv::binary-size(half), sig_prv::binary-size(half)>> =
          binary_part(prv_bytes, 0, half * 2)

        enc_kp = X25519.from_private_bytes(enc_prv)
        sig_kp = Ed25519.from_private_bytes(sig_prv)

        updated =
          %{
            id
            | prv_bytes: enc_prv,
              sig_prv_bytes: sig_prv,
              pub_bytes: X25519.public_key(enc_kp),
              sig_pub_bytes: Ed25519.public_key(sig_kp)
          }
          |> update_hashes()

        {:ok, updated}
      rescue
        e -> {:error, e}
      end
    end
  end

  @doc """
  Loads a 64-byte public key into the identity.

  Returns the updated identity.
  """
  @spec load_public_key(t(), binary()) :: t()
  def load_public_key(%__MODULE__{} = id, pub_bytes) when is_binary(pub_bytes) do
    half = div(@keysize, 8 * 2)
    <<enc_pub::binary-size(half), sig_pub::binary-size(half)>> = binary_part(pub_bytes, 0, half * 2)

    %{id | pub_bytes: enc_pub, sig_pub_bytes: sig_pub}
    |> update_hashes()
  end

  # --- Serialization ---

  @doc """
  Creates an Identity from raw private key bytes.

  Returns the identity or nil if the bytes are invalid.
  """
  @spec from_bytes(binary()) :: t() | nil
  def from_bytes(prv_bytes) when is_binary(prv_bytes) do
    id = new(create_keys: false)

    case load_private_key(id, prv_bytes) do
      {:ok, loaded} -> loaded
      {:error, _} -> nil
    end
  end

  @doc """
  Loads an Identity from a file containing the private key.

  Returns the identity or nil if loading fails.
  """
  @spec from_file(String.t()) :: t() | nil
  def from_file(path) do
    case File.read(path) do
      {:ok, prv_bytes} -> from_bytes(prv_bytes)
      {:error, _} -> nil
    end
  end

  @doc """
  Saves the identity's private key to a file.

  Returns true on success, false on failure.
  """
  @spec to_file(t(), String.t()) :: boolean()
  def to_file(%__MODULE__{} = id, path) do
    case File.write(path, get_private_key(id)) do
      :ok -> true
      {:error, _} -> false
    end
  end

  # --- Signing and verification ---

  @doc """
  Signs a message with the identity's Ed25519 private key.

  Returns a 64-byte signature.
  Raises `KeyError` if the identity has no private key.
  """
  @spec sign(t(), binary()) :: binary()
  def sign(%__MODULE__{sig_prv_bytes: nil}, _message) do
    raise KeyError, key: :sig_prv, term: "Signing failed because identity does not hold a private key"
  end

  def sign(%__MODULE__{sig_prv_bytes: sig_prv}, message) when is_binary(message) do
    kp = Ed25519.from_private_bytes(sig_prv)
    Ed25519.sign(kp, message)
  end

  @doc """
  Validates a signature against a message using the identity's Ed25519 public key.

  Returns true if valid, false otherwise.
  Raises `KeyError` if the identity has no public key.
  """
  @spec validate(t(), binary(), binary()) :: boolean()
  def validate(%__MODULE__{pub_bytes: nil}, _signature, _message) do
    raise KeyError, key: :pub, term: "Signature validation failed because identity does not hold a public key"
  end

  def validate(%__MODULE__{sig_pub_bytes: sig_pub}, signature, message) do
    Ed25519.verify(signature, message, sig_pub)
  end

  # --- Encryption and decryption ---

  @doc """
  Encrypts plaintext for this identity using ephemeral ECDH.

  ## Options

    * `:ratchet` - optional ratchet public key bytes (32 bytes) to use instead of
      the identity's encryption public key

  Returns the encrypted token as binary.
  Raises `KeyError` if the identity has no public key.
  """
  @spec encrypt(t(), binary(), keyword()) :: binary()
  def encrypt(id, plaintext, opts \\ [])

  def encrypt(%__MODULE__{pub_bytes: nil}, _plaintext, _opts) do
    raise KeyError, key: :pub, term: "Encryption failed because identity does not hold a public key"
  end

  def encrypt(%__MODULE__{} = id, plaintext, opts) when is_binary(plaintext) do
    ratchet = Keyword.get(opts, :ratchet)

    ephemeral = X25519.generate_keypair()
    ephemeral_pub_bytes = X25519.public_key(ephemeral)

    target_pub_key =
      if ratchet != nil do
        ratchet
      else
        id.pub_bytes
      end

    shared_key = X25519.exchange(ephemeral, target_pub_key)

    derived_key =
      HKDF.derive_key(
        shared_key,
        @derived_key_length,
        get_salt(id),
        get_context(id)
      )

    token = Token.new(derived_key)
    ciphertext = Token.encrypt(token, plaintext)

    ephemeral_pub_bytes <> ciphertext
  end

  @doc """
  Decrypts a ciphertext token for this identity.

  ## Options

    * `:ratchets` - list of ratchet private key bytes to try
    * `:enforce_ratchets` - if true, only decrypt with ratchet keys

  Returns plaintext binary or nil if decryption fails.
  Raises `KeyError` if the identity has no private key.
  """
  @spec decrypt(t(), binary(), keyword()) :: binary() | nil
  def decrypt(id, ciphertext_token, opts \\ [])

  def decrypt(%__MODULE__{prv_bytes: nil}, _ciphertext_token, _opts) do
    raise KeyError, key: :prv, term: "Decryption failed because identity does not hold a private key"
  end

  def decrypt(%__MODULE__{} = id, ciphertext_token, opts) when is_binary(ciphertext_token) do
    half = div(@keysize, 8 * 2)
    ratchets = Keyword.get(opts, :ratchets)
    enforce_ratchets = Keyword.get(opts, :enforce_ratchets, false)

    if byte_size(ciphertext_token) <= half do
      nil
    else
      try do
        <<peer_pub_bytes::binary-size(half), ciphertext::binary>> = ciphertext_token

        plaintext =
          if ratchets do
            try_ratchet_decrypt(id, ratchets, peer_pub_bytes, ciphertext)
          else
            nil
          end

        cond do
          enforce_ratchets and plaintext == nil ->
            nil

          plaintext != nil ->
            plaintext

          true ->
            # Try standard decryption with identity's private key
            try_standard_decrypt(id, peer_pub_bytes, ciphertext)
        end
      rescue
        _ -> nil
      end
    end
  end

  defp try_ratchet_decrypt(id, ratchets, peer_pub_bytes, ciphertext) do
    Enum.find_value(ratchets, fn ratchet ->
      try do
        ratchet_kp = X25519.from_private_bytes(ratchet)
        shared_key = X25519.exchange(ratchet_kp, peer_pub_bytes)
        do_decrypt(id, shared_key, ciphertext)
      rescue
        _ -> nil
      end
    end)
  end

  defp try_standard_decrypt(id, peer_pub_bytes, ciphertext) do
    try do
      enc_kp = X25519.from_private_bytes(id.prv_bytes)
      shared_key = X25519.exchange(enc_kp, peer_pub_bytes)
      do_decrypt(id, shared_key, ciphertext)
    rescue
      _ -> nil
    end
  end

  defp do_decrypt(id, shared_key, ciphertext) do
    derived_key =
      HKDF.derive_key(
        shared_key,
        @derived_key_length,
        get_salt(id),
        get_context(id)
      )

    token = Token.new(derived_key)
    Token.decrypt(token, ciphertext)
  end

  # --- Hash helpers ---

  @doc "Returns the SHA-256 hash of data."
  @spec full_hash(binary()) :: binary()
  def full_hash(data), do: Hashes.sha256(data)

  @doc "Returns the truncated (16-byte) SHA-256 hash of data."
  @spec truncated_hash(binary()) :: binary()
  def truncated_hash(data), do: Hashes.truncated_hash(data)

  @doc "Returns a random 16-byte truncated hash."
  @spec get_random_hash() :: binary()
  def get_random_hash do
    truncated_hash(:crypto.strong_rand_bytes(div(@truncated_hashlength, 8)))
  end

  # --- Salt / Context ---

  @doc "Returns the identity hash, used as HKDF salt."
  @spec get_salt(t()) :: binary() | nil
  def get_salt(%__MODULE__{hash: hash}), do: hash

  @doc "Returns nil (no context used)."
  @spec get_context(t()) :: nil
  def get_context(%__MODULE__{}), do: nil

  # --- Store delegates ---

  @doc """
  Stores a known destination in the IdentityStore.

  The public key must be exactly KEYSIZE // 8 bytes (64).
  """
  @spec remember(binary(), binary(), binary(), binary() | nil) :: :ok | {:error, :invalid_public_key}
  defdelegate remember(packet_hash, destination_hash, public_key, app_data \\ nil),
    to: RNS.IdentityStore

  @doc """
  Recalls an identity by destination hash or identity hash.

  Pass `from_identity_hash: true` to search by identity hash.
  """
  @spec recall(binary(), keyword()) :: t() | nil
  defdelegate recall(target_hash, opts \\ []), to: RNS.IdentityStore

  @doc "Recalls app_data for a known destination hash."
  @spec recall_app_data(binary()) :: binary() | nil
  defdelegate recall_app_data(destination_hash), to: RNS.IdentityStore

  # --- Ratchet operations ---

  @doc "Generates a new ratchet (X25519 private key bytes)."
  @spec generate_ratchet() :: binary()
  def generate_ratchet do
    kp = X25519.generate_keypair()
    X25519.private_bytes(kp)
  end

  @doc "Returns the public key bytes for a ratchet private key."
  @spec ratchet_public_bytes(binary()) :: binary()
  def ratchet_public_bytes(ratchet_prv_bytes) do
    kp = X25519.from_private_bytes(ratchet_prv_bytes)
    X25519.public_key(kp)
  end

  @doc "Returns the ratchet ID (first NAME_HASH_LENGTH//8 bytes of SHA-256 hash of public key)."
  @spec get_ratchet_id(binary()) :: binary()
  def get_ratchet_id(ratchet_pub_bytes) do
    <<id::binary-size(div(@name_hash_length, 8)), _::binary>> = full_hash(ratchet_pub_bytes)
    id
  end

  @doc "Stores a ratchet public key for a destination hash."
  @spec remember_ratchet(binary(), binary()) :: :ok
  defdelegate remember_ratchet(destination_hash, ratchet_pub_bytes), to: RNS.IdentityStore

  @doc "Retrieves the stored ratchet public key for a destination hash."
  @spec get_ratchet(binary()) :: binary() | nil
  defdelegate get_ratchet(destination_hash), to: RNS.IdentityStore

  @doc "Returns the current ratchet ID for a destination, or nil."
  @spec current_ratchet_id(binary()) :: binary() | nil
  def current_ratchet_id(destination_hash) do
    case get_ratchet(destination_hash) do
      nil -> nil
      ratchet -> get_ratchet_id(ratchet)
    end
  end

  # --- Internal ---

  defp update_hashes(%__MODULE__{pub_bytes: nil} = id), do: id

  defp update_hashes(%__MODULE__{} = id) do
    pub = get_public_key(id)
    hash = truncated_hash(pub)
    %{id | hash: hash, hexhash: Base.encode16(hash, case: :lower)}
  end
end
