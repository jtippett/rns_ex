defmodule RNS.Identity do
  @moduledoc """
  Manages identities in the Reticulum Network Stack.

  Provides methods for encryption, decryption, signatures and verification,
  and is the basis for all encrypted communication over Reticulum networks.

  Each identity has an X25519 keypair for encryption and an Ed25519 keypair
  for signing. The identity hash is a truncated SHA-256 of the concatenated
  public keys.
  """

  require Logger

  alias RNS.Cryptography.Ed25519
  alias RNS.Cryptography.Hashes
  alias RNS.Cryptography.HKDF
  alias RNS.Cryptography.Token
  alias RNS.Cryptography.X25519

  use RNS.Constants.Identity

  @token_overhead Token.token_overhead()
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

  def curve, do: @curve
  def keysize, do: @keysize
  def hashlength, do: @hashlength
  def name_hash_length, do: @name_hash_length
  def truncated_hashlength, do: @truncated_hashlength
  def ratchetsize, do: @ratchetsize
  def ratchet_expiry, do: @ratchet_expiry
  def siglength, do: @siglength
  def token_overhead, do: @token_overhead
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
  @spec private_key(t()) :: binary()
  def private_key(%__MODULE__{prv_bytes: prv, sig_prv_bytes: sig_prv}) do
    prv <> sig_prv
  end

  @doc "Returns the full public key (64 bytes: encryption + signing)."
  @spec public_key(t()) :: binary()
  def public_key(%__MODULE__{pub_bytes: pub, sig_pub_bytes: sig_pub}) do
    pub <> sig_pub
  end

  # --- Key loading ---

  @doc """
  Loads a 64-byte private key into the identity, deriving all public keys.

  Returns `{:ok, updated_identity}` on success, `{:error, reason}` on failure.
  """
  @spec load_private_key(t(), binary()) :: {:ok, t()} | {:error, term()}
  def load_private_key(
        %__MODULE__{} = id,
        <<enc_prv::binary-size(32), sig_prv::binary-size(32), _::binary>>
      ) do
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
    e ->
      Logger.debug("Failed to load private key: #{inspect(e)}")
      {:error, e}
  end

  def load_private_key(%__MODULE__{}, _), do: {:error, :invalid_key_length}

  @doc """
  Loads a 64-byte public key into the identity.

  Returns the updated identity.
  """
  @spec load_public_key(t(), binary()) :: t()
  def load_public_key(
        %__MODULE__{} = id,
        <<enc_pub::binary-size(32), sig_pub::binary-size(32), _::binary>>
      ) do
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
    case File.write(path, private_key(id)) do
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
    raise KeyError,
      key: :sig_prv,
      term: "Signing failed because identity does not hold a private key"
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
    raise KeyError,
      key: :pub,
      term: "Signature validation failed because identity does not hold a public key"
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
    raise KeyError,
      key: :pub,
      term: "Encryption failed because identity does not hold a public key"
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
        salt(id),
        context(id)
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
    raise KeyError,
      key: :prv,
      term: "Decryption failed because identity does not hold a private key"
  end

  def decrypt(%__MODULE__{} = id, ciphertext_token, opts) when is_binary(ciphertext_token) do
    half = div(@keysize, 8 * 2)
    ratchets = Keyword.get(opts, :ratchets)
    enforce_ratchets = Keyword.get(opts, :enforce_ratchets, false)

    if byte_size(ciphertext_token) <= half do
      nil
    else
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
    end
  end

  defp try_ratchet_decrypt(id, ratchets, peer_pub_bytes, ciphertext) do
    Enum.find_value(ratchets, fn ratchet ->
      with {:ok, ratchet_kp} <- safe_from_private(ratchet),
           {:ok, shared_key} <- safe_exchange(ratchet_kp, peer_pub_bytes),
           {:ok, plaintext} <- safe_decrypt(id, shared_key, ciphertext) do
        plaintext
      else
        _ -> nil
      end
    end)
  end

  defp try_standard_decrypt(id, peer_pub_bytes, ciphertext) do
    with {:ok, enc_kp} <- safe_from_private(id.prv_bytes),
         {:ok, shared_key} <- safe_exchange(enc_kp, peer_pub_bytes),
         {:ok, plaintext} <- safe_decrypt(id, shared_key, ciphertext) do
      plaintext
    else
      _ -> nil
    end
  end

  defp safe_from_private(bytes) do
    {:ok, X25519.from_private_bytes(bytes)}
  rescue
    e ->
      Logger.debug("X25519 key load failed: #{inspect(e)}")
      {:error, {:key_load, e}}
  end

  defp safe_exchange(kp, pub_bytes) do
    {:ok, X25519.exchange(kp, pub_bytes)}
  rescue
    e ->
      Logger.debug("X25519 key exchange failed: #{inspect(e)}")
      {:error, {:exchange, e}}
  end

  defp safe_decrypt(id, shared_key, ciphertext) do
    {:ok, do_decrypt(id, shared_key, ciphertext)}
  rescue
    e ->
      Logger.debug("Token decryption failed: #{inspect(e)}")
      {:error, {:decrypt, e}}
  end

  defp do_decrypt(id, shared_key, ciphertext) do
    derived_key =
      HKDF.derive_key(
        shared_key,
        @derived_key_length,
        salt(id),
        context(id)
      )

    token = Token.new(derived_key)
    Token.decrypt(token, ciphertext)
  end

  # --- Announce Validation ---

  @doc """
  Validates an announce packet by extracting the public key and signature
  from the announce data and verifying the signature.

  Returns `true` if the announce signature is valid, `false` otherwise.
  """
  @spec validate_announce(map()) :: {:ok, binary(), binary()} | :error
  def validate_announce(packet) do
    keysize_bytes = div(@keysize, 8)
    name_hash_len = div(@name_hash_length, 8)
    sig_len = div(@siglength, 8)
    ratchetsize_bytes = div(@ratchetsize, 8)

    with data when is_binary(data) <- packet.data,
         dest_hash when is_binary(dest_hash) <- packet.destination_hash do
      <<public_key::binary-size(keysize_bytes), rest::binary>> = data

      {name_hash, random_hash, ratchet, signature, app_data} =
        case Map.get(packet, :context_flag, 0) do
          1 ->
            <<nh::binary-size(name_hash_len), rh::binary-size(10),
              rt::binary-size(ratchetsize_bytes), sig::binary-size(sig_len), ad::binary>> = rest

            {nh, rh, rt, sig, ad}

          _ ->
            <<nh::binary-size(name_hash_len), rh::binary-size(10), sig::binary-size(sig_len),
              ad::binary>> = rest

            {nh, rh, <<>>, sig, ad}
        end

      signed_data = dest_hash <> public_key <> name_hash <> random_hash <> ratchet <> app_data

      identity =
        new(create_keys: false)
        |> load_public_key(public_key)

      if validate(identity, signature, signed_data) do
        {:ok, public_key, app_data}
      else
        :error
      end
    else
      _ -> :error
    end
  rescue
    # Broad rescue is intentional: announce validation must never crash the caller.
    # Binary pattern match failures (MatchError) and crypto errors are both expected
    # when processing malformed or adversarial announce packets.
    e in [MatchError] ->
      Logger.debug("Announce validation failed (match error): #{inspect(e)}")
      :error

    e in [ArgumentError] ->
      Logger.debug("Announce validation failed (argument error): #{inspect(e)}")
      :error

    e ->
      Logger.debug("Announce validation failed: #{inspect(e)}")
      :error
  end

  # --- Hash helpers ---

  @doc "Returns the SHA-256 hash of data."
  @spec full_hash(binary()) :: binary()
  def full_hash(data), do: Hashes.sha256(data)

  @doc "Returns the truncated (16-byte) SHA-256 hash of data."
  @spec truncated_hash(binary()) :: binary()
  def truncated_hash(data), do: Hashes.truncated_hash(data)

  @doc "Returns a random 16-byte truncated hash."
  @spec random_hash() :: binary()
  def random_hash do
    truncated_hash(:crypto.strong_rand_bytes(div(@truncated_hashlength, 8)))
  end

  # --- Hex conveniences ---

  @doc """
  Returns the identity hash as a lowercase hex string.

  Returns nil if the identity has no hash (keys not loaded).

  ## Examples

      iex> id = RNS.Identity.new()
      iex> hex = RNS.Identity.to_hex(id)
      iex> byte_size(hex)
      32
  """
  @spec to_hex(t()) :: String.t() | nil
  def to_hex(%__MODULE__{hash: nil}), do: nil
  def to_hex(%__MODULE__{hexhash: hexhash}), do: hexhash

  @doc """
  Creates an Identity from a hex-encoded private key string.

  Accepts both upper and lowercase hex. Returns nil if the hex is
  invalid or the key cannot be loaded.

  ## Examples

      iex> id = RNS.Identity.new()
      iex> hex = Base.encode16(RNS.Identity.private_key(id), case: :lower)
      iex> restored = RNS.Identity.from_hex(hex)
      iex> restored.hash == id.hash
      true
  """
  @spec from_hex(String.t()) :: t() | nil
  def from_hex(hex_string) when is_binary(hex_string) do
    case Base.decode16(hex_string, case: :mixed) do
      {:ok, bytes} -> from_bytes(bytes)
      :error -> nil
    end
  end

  @doc """
  Returns the full public key (64 bytes) as a lowercase hex string.

  Returns nil if the identity has no public key.

  ## Examples

      iex> id = RNS.Identity.new()
      iex> hex = RNS.Identity.public_hex(id)
      iex> byte_size(hex)
      128
  """
  @spec public_hex(t()) :: String.t() | nil
  def public_hex(%__MODULE__{pub_bytes: nil}), do: nil

  def public_hex(%__MODULE__{} = id) do
    Base.encode16(public_key(id), case: :lower)
  end

  # --- Salt / Context ---

  @doc "Returns the identity hash, used as HKDF salt."
  @spec salt(t()) :: binary() | nil
  def salt(%__MODULE__{hash: hash}), do: hash

  @doc "Returns nil (no context used)."
  @spec context(t()) :: nil
  def context(%__MODULE__{}), do: nil

  # --- Store delegates ---

  @doc """
  Stores a known destination in the IdentityStore.

  The public key must be exactly KEYSIZE // 8 bytes (64).
  """
  @spec remember(binary(), binary(), binary(), binary() | nil) ::
          :ok | {:error, :invalid_public_key}
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
  @spec ratchet_id(binary()) :: binary()
  def ratchet_id(ratchet_pub_bytes) do
    <<id::binary-size(div(@name_hash_length, 8)), _::binary>> = full_hash(ratchet_pub_bytes)
    id
  end

  @doc "Stores a ratchet public key for a destination hash."
  @spec remember_ratchet(binary(), binary()) :: :ok
  defdelegate remember_ratchet(destination_hash, ratchet_pub_bytes), to: RNS.IdentityStore

  @doc "Retrieves the stored ratchet public key for a destination hash."
  @spec ratchet(binary()) :: binary() | nil
  defdelegate ratchet(destination_hash), to: RNS.IdentityStore, as: :get_ratchet

  @doc "Returns the current ratchet ID for a destination, or nil."
  @spec current_ratchet_id(binary()) :: binary() | nil
  def current_ratchet_id(destination_hash) do
    case ratchet(destination_hash) do
      nil -> nil
      ratchet_val -> ratchet_id(ratchet_val)
    end
  end

  # --- Internal ---

  defp update_hashes(%__MODULE__{} = id) do
    pub = public_key(id)
    hash = truncated_hash(pub)
    %{id | hash: hash, hexhash: Base.encode16(hash, case: :lower)}
  end

  defimpl Jason.Encoder do
    def encode(identity, opts) do
      map = %{
        hash: identity.hexhash,
        public_key: RNS.Identity.public_hex(identity),
        app_data:
          if(identity.app_data, do: Base.encode16(identity.app_data, case: :lower), else: nil)
      }

      Jason.Encode.map(map, opts)
    end
  end
end
