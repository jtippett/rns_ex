defmodule RNS.Destination do
  @moduledoc """
  Represents a destination endpoint in the Reticulum Network Stack.

  Destinations are used to address packets and establish links. Every
  destination has a hash derived from its name and associated identity.
  The destination type determines if encryption is used and what kind.

  Matches `python/RNS/Destination.py`.
  """

  alias RNS.Identity
  alias RNS.Cryptography.Hashes
  alias RNS.Cryptography.Token

  use RNS.Constants.Packet
  use RNS.Constants.Destination

  @types [@single, @group, @plain, @link]
  @proof_strategies [@prove_none, @prove_app, @prove_all]
  @request_policies [@allow_none, @allow_all, @allow_list]
  @directions [@in_direction, @out_direction]

  # ── Struct ──────────────────────────────────────────────────────

  defstruct [
    :type,
    :direction,
    :identity,
    :name,
    :hash,
    :name_hash,
    :hexhash,
    :default_app_data,
    :mtu,
    :prv_bytes,
    :prv,
    :ratchets,
    :ratchets_path,
    :ratchet_interval,
    :retained_ratchets,
    :latest_ratchet_time,
    :latest_ratchet_id,
    accept_link_requests: true,
    callbacks: %{link_established: nil, packet: nil, proof_requested: nil},
    request_handlers: %{},
    proof_strategy: 0x21,
    enforce_ratchets: false,
    path_responses: %{},
    links: []
  ]

  @type t :: %__MODULE__{}

  # ── Constant accessors ──────────────────────────────────────────
  # For cross-module use, prefer `use RNS.Constants.Destination`.

  def single, do: @single
  def group, do: @group
  def plain, do: @plain
  def link, do: @link
  def types, do: @types
  def prove_none, do: @prove_none
  def prove_app, do: @prove_app
  def prove_all, do: @prove_all
  def proof_strategies, do: @proof_strategies
  def allow_none, do: @allow_none
  def allow_all, do: @allow_all
  def allow_list, do: @allow_list
  def request_policies, do: @request_policies
  def direction_in, do: @in_direction
  def direction_out, do: @out_direction
  def directions, do: @directions
  def pr_tag_window, do: @pr_tag_window
  def ratchet_count, do: @ratchet_count
  def default_ratchet_interval, do: @ratchet_interval

  # ── Static hash computation ─────────────────────────────────────

  @doc """
  Builds the full human-readable name string for a destination.

  ## Examples

      iex> RNS.Destination.expand_name(nil, "myapp", ["service"])
      "myapp.service"

  """
  @spec expand_name(Identity.t() | nil, String.t(), [String.t()]) :: String.t()
  def expand_name(identity, app_name, aspects) do
    base = Enum.join([app_name | aspects], ".")

    if identity != nil do
      base <> "." <> identity.hexhash
    else
      base
    end
  end

  @doc """
  Computes the name hash (first NAME_HASH_LENGTH//8 bytes of SHA-256 of the
  name string without identity).
  """
  @spec compute_name_hash(String.t(), [String.t()]) :: binary()
  def compute_name_hash(app_name, aspects) do
    name_str = expand_name(nil, app_name, aspects)
    full = Hashes.sha256(name_str)
    binary_part(full, 0, div(@name_hash_length, 8))
  end

  @doc """
  Computes the destination address hash.

  Hash = truncated SHA-256 of (name_hash + identity.hash).
  For PLAIN destinations (no identity), hash = truncated SHA-256 of name_hash alone.
  """
  @spec compute_hash(Identity.t() | binary() | nil, String.t(), [String.t()]) :: binary()
  def compute_hash(identity, app_name, aspects) do
    name_hash_bytes = compute_name_hash(app_name, aspects)

    addr_hash_material =
      cond do
        identity == nil ->
          name_hash_bytes

        is_binary(identity) and byte_size(identity) == div(@truncated_hashlength, 8) ->
          name_hash_bytes <> identity

        is_struct(identity, Identity) ->
          name_hash_bytes <> identity.hash

        true ->
          raise ArgumentError, "Invalid material supplied for destination hash calculation"
      end

    full = Hashes.sha256(addr_hash_material)
    binary_part(full, 0, div(@truncated_hashlength, 8))
  end

  @doc """
  Convenience function matching Python's `Destination.hash(identity, app_name, *aspects)`.
  """
  @spec hash(Identity.t() | binary() | nil, String.t(), [String.t()]) :: binary()
  def hash(identity, app_name, aspects \\ []) do
    compute_hash(identity, app_name, aspects)
  end

  @doc """
  Splits a full destination name into app_name and aspects.

  ## Examples

      iex> RNS.Destination.app_and_aspects_from_name("myapp.service.v1")
      {"myapp", ["service", "v1"]}

  """
  @spec app_and_aspects_from_name(String.t()) :: {String.t(), [String.t()]}
  def app_and_aspects_from_name(full_name) do
    [app_name | aspects] = String.split(full_name, ".")
    {app_name, aspects}
  end

  @doc """
  Computes a destination hash from a full name string and identity.
  """
  @spec hash_from_name_and_identity(String.t(), Identity.t() | binary() | nil) :: binary()
  def hash_from_name_and_identity(full_name, identity) do
    {app_name, aspects} = app_and_aspects_from_name(full_name)
    hash(identity, app_name, aspects)
  end

  # ── Construction ────────────────────────────────────────────────

  @doc """
  Creates a new Destination.

  For IN + SINGLE/GROUP destinations with no identity, a new identity
  is auto-created and its hexhash appended to aspects.

  ## Parameters

    * `identity` - An `RNS.Identity` struct, or nil for PLAIN destinations
    * `direction` - `direction_in()` or `direction_out()`
    * `type` - `single()`, `group()`, `plain()`, or `link()`
    * `app_name` - Application name string (no dots allowed)
    * `aspects` - List of aspect strings (no dots allowed)

  """
  @spec new(Identity.t() | nil, non_neg_integer(), non_neg_integer(), String.t(), [String.t()]) ::
          t()
  def new(identity, direction, type, app_name, aspects \\ []) do
    if String.contains?(app_name, ".") do
      raise ArgumentError, "Dots are not allowed in app names"
    end

    unless type in @types do
      raise ArgumentError, "Unknown destination type"
    end

    unless direction in @directions do
      raise ArgumentError, "Unknown destination direction"
    end

    Enum.each(aspects, fn aspect ->
      if String.contains?(aspect, ".") do
        raise ArgumentError, "Dots are not allowed in aspects"
      end
    end)

    {identity, aspects} = resolve_identity(identity, direction, type, aspects)

    name = expand_name(identity, app_name, aspects)
    name_hash_bytes = compute_name_hash(app_name, aspects)
    dest_hash = compute_hash(identity, app_name, aspects)
    hexhash = Base.encode16(dest_hash, case: :lower)

    dest = %__MODULE__{
      type: type,
      direction: direction,
      identity: identity,
      name: name,
      hash: dest_hash,
      name_hash: name_hash_bytes,
      hexhash: hexhash,
      mtu: 0,
      ratchet_interval: @ratchet_interval,
      retained_ratchets: @ratchet_count,
      proof_strategy: @prove_none,
      accept_link_requests: true,
      callbacks: %{link_established: nil, packet: nil, proof_requested: nil},
      request_handlers: %{},
      path_responses: %{},
      links: [],
      enforce_ratchets: false
    }

    # Transport.register_destination will be wired in Phase 4
    dest
  end

  defp resolve_identity(nil, @in_direction, @plain, aspects), do: {nil, aspects}

  defp resolve_identity(nil, @in_direction, _type, aspects) do
    identity = Identity.new()
    {identity, aspects ++ [identity.hexhash]}
  end

  defp resolve_identity(nil, @out_direction, @plain, aspects), do: {nil, aspects}

  defp resolve_identity(nil, @out_direction, _type, _aspects) do
    raise ArgumentError, "Can't create outbound SINGLE destination without an identity"
  end

  defp resolve_identity(_identity, _direction, @plain, _aspects) do
    raise ArgumentError, "Selected destination type PLAIN cannot hold an identity"
  end

  defp resolve_identity(identity, _direction, _type, aspects), do: {identity, aspects}

  # ── Announce ────────────────────────────────────────────────────

  @doc """
  Creates an announce packet for this destination and broadcasts it.

  Only SINGLE + IN destinations can announce.

  ## Options

    * `:app_data` - bytes to include in the announce
    * `:path_response` - whether this is a path response (default: false)
    * `:attached_interface` - interface to send on
    * `:tag` - tag for path response caching
    * `:send` - whether to send immediately (default: true)

  Returns `{packet_or_receipt, updated_destination}`.
  """
  @spec announce(t(), keyword()) :: {term(), t()}
  def announce(dest, opts \\ [])

  def announce(%__MODULE__{type: @single, direction: @in_direction} = dest, opts) do
    app_data = Keyword.get(opts, :app_data)
    path_response = Keyword.get(opts, :path_response, false)
    attached_interface = Keyword.get(opts, :attached_interface)
    tag = Keyword.get(opts, :tag)
    send_announce = Keyword.get(opts, :send, true)

    # Clean stale path responses
    now = System.system_time(:second)
    path_responses = clean_path_responses(dest.path_responses, now)
    dest = %{dest | path_responses: path_responses}

    # Check for cached path response
    {announce_data, ratchet_used, dest} =
      if path_response and tag != nil and Map.has_key?(dest.path_responses, tag) do
        {_ts, cached_data} = Map.get(dest.path_responses, tag)
        {cached_data, <<>>, dest}
      else
        build_announce_data(dest, app_data)
      end

    # Cache the announce data
    dest =
      if tag != nil do
        %{dest | path_responses: Map.put(dest.path_responses, tag, {now, announce_data})}
      else
        dest
      end

    context =
      if path_response, do: @context_path_response, else: @context_none

    context_flag =
      if byte_size(ratchet_used) > 0, do: @flag_set, else: @flag_unset

    announce_packet =
      RNS.Packet.new(dest, announce_data,
        packet_type: @announce,
        context: context,
        attached_interface: attached_interface,
        context_flag: context_flag
      )

    if send_announce do
      result = RNS.Packet.send(announce_packet)
      {result, dest}
    else
      {announce_packet, dest}
    end
  end

  def announce(%__MODULE__{type: type}, _opts) when type != @single do
    raise ArgumentError, "Only SINGLE destination types can be announced"
  end

  def announce(%__MODULE__{direction: dir}, _opts) when dir != @in_direction do
    raise ArgumentError, "Only IN destination types can be announced"
  end

  defp build_announce_data(dest, app_data) do
    # random_hash: 5 random bytes + 5 timestamp bytes (big-endian)
    random_hash =
      :crypto.strong_rand_bytes(5) <>
        <<System.system_time(:second)::big-unsigned-size(40)>>

    public_key = Identity.public_key(dest.identity)

    # Handle ratchets
    {ratchet_bytes, dest} =
      if dest.ratchets != nil do
        dest = rotate_ratchets(dest)
        ratchet_prv = hd(dest.ratchets)
        ratchet_pub = Identity.ratchet_public_bytes(ratchet_prv)
        Identity.remember_ratchet(dest.hash, ratchet_pub)
        {ratchet_pub, dest}
      else
        {<<>>, dest}
      end

    # Resolve app_data
    app_data = resolve_app_data(app_data, dest.default_app_data)
    app_data_bytes = app_data || <<>>

    # signed_data includes destination_hash, announce_data does not
    signed_data =
      dest.hash <> public_key <> dest.name_hash <> random_hash <> ratchet_bytes <> app_data_bytes

    signature = Identity.sign(dest.identity, signed_data)

    announce_data =
      public_key <> dest.name_hash <> random_hash <> ratchet_bytes <> signature <> app_data_bytes

    {announce_data, ratchet_bytes, dest}
  end

  defp resolve_app_data(nil, nil), do: nil
  defp resolve_app_data(nil, default) when is_function(default, 0), do: default.()
  defp resolve_app_data(nil, default) when is_binary(default), do: default
  defp resolve_app_data(app_data, _default), do: app_data

  defp clean_path_responses(path_responses, now) do
    Enum.reduce(path_responses, %{}, fn {tag, {ts, data}}, acc ->
      if now - ts < @pr_tag_window do
        Map.put(acc, tag, {ts, data})
      else
        acc
      end
    end)
  end

  # ── Ratchet management ──────────────────────────────────────────

  @doc """
  Enables ratchets on the destination for forward secrecy.

  Returns the updated destination.
  """
  @spec enable_ratchets(t(), String.t()) :: t()
  def enable_ratchets(dest, ratchets_path) do
    dest = %{dest | latest_ratchet_time: 0, ratchets_path: ratchets_path}
    reload_ratchets(dest)
  end

  @doc """
  Enforces ratchet-only decryption. Only works if ratchets are enabled.

  Returns the updated destination.
  """
  @spec enforce_ratchets(t()) :: t()
  def enforce_ratchets(%__MODULE__{ratchets: ratchets} = dest) when is_list(ratchets) do
    %{dest | enforce_ratchets: true}
  end

  def enforce_ratchets(dest), do: dest

  @doc """
  Sets the number of retained ratchet keys.
  """
  @spec set_retained_ratchets(t(), pos_integer()) :: t()
  def set_retained_ratchets(dest, count) when is_integer(count) and count > 0 do
    %{dest | retained_ratchets: count}
    |> clean_ratchets()
  end

  @doc """
  Sets the minimum ratchet rotation interval in seconds.
  """
  @spec set_ratchet_interval(t(), pos_integer()) :: t()
  def set_ratchet_interval(dest, interval) when is_integer(interval) and interval > 0 do
    %{dest | ratchet_interval: interval}
  end

  @doc """
  Rotates ratchets if the interval has elapsed.

  Returns the updated destination.
  """
  @spec rotate_ratchets(t()) :: t()
  def rotate_ratchets(%__MODULE__{ratchets: nil}) do
    raise RuntimeError, message: "Cannot rotate ratchets, ratchets are not enabled"
  end

  def rotate_ratchets(%__MODULE__{ratchets: ratchets} = dest) when is_list(ratchets) do
    now = System.system_time(:second)
    latest = dest.latest_ratchet_time || 0

    if now > latest + dest.ratchet_interval do
      new_ratchet = Identity.generate_ratchet()
      new_ratchets = [new_ratchet | ratchets]

      dest = %{dest | ratchets: new_ratchets, latest_ratchet_time: now}
      dest = clean_ratchets(dest)
      persist_ratchets(dest)
      dest
    else
      dest
    end
  end

  defp clean_ratchets(%__MODULE__{ratchets: nil} = dest), do: dest

  defp clean_ratchets(%__MODULE__{ratchets: ratchets} = dest) do
    if length(ratchets) > @ratchet_count do
      %{dest | ratchets: Enum.take(ratchets, @ratchet_count)}
    else
      dest
    end
  end

  defp persist_ratchets(%__MODULE__{ratchets_path: nil}), do: :ok
  defp persist_ratchets(%__MODULE__{identity: nil}), do: :ok

  defp persist_ratchets(%__MODULE__{} = dest) do
    packed = :erlang.term_to_binary(dest.ratchets)
    signature = Identity.sign(dest.identity, packed)
    data = :erlang.term_to_binary({signature, packed})
    tmp_path = dest.ratchets_path <> ".tmp"

    case File.write(tmp_path, data) do
      :ok -> File.rename(tmp_path, dest.ratchets_path)
      {:error, _} -> :error
    end
  end

  defp reload_ratchets(%__MODULE__{ratchets_path: nil} = dest) do
    %{dest | ratchets: []}
  end

  defp reload_ratchets(%__MODULE__{ratchets_path: path} = dest) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, data} ->
          try do
            {signature, packed} = :erlang.binary_to_term(data)

            if Identity.validate(dest.identity, signature, packed) do
              ratchets = :erlang.binary_to_term(packed)
              %{dest | ratchets: ratchets}
            else
              %{dest | ratchets: []}
            end
          rescue
            _ -> %{dest | ratchets: []}
          end

        {:error, _} ->
          %{dest | ratchets: []}
      end
    else
      dest = %{dest | ratchets: []}
      persist_ratchets(dest)
      dest
    end
  end

  # ── Encryption / Decryption ─────────────────────────────────────

  @doc """
  Encrypts plaintext for this destination.

  - PLAIN: returns plaintext unchanged
  - SINGLE: uses Identity ECDH encryption, with optional ratchet
  - GROUP: uses Token (Fernet) symmetric encryption

  Returns the ciphertext. For SINGLE destinations, also updates
  `latest_ratchet_id` as a side effect lookup.
  """
  @spec encrypt(t(), binary()) :: binary()
  def encrypt(%__MODULE__{type: @plain}, plaintext), do: plaintext

  def encrypt(%__MODULE__{type: @single, identity: identity} = dest, plaintext)
      when identity != nil do
    selected_ratchet = Identity.ratchet(dest.hash)
    Identity.encrypt(identity, plaintext, ratchet: selected_ratchet)
  end

  def encrypt(%__MODULE__{type: @group, prv: nil}, _plaintext) do
    raise ArgumentError, "No private key held by GROUP destination. Did you create or load one?"
  end

  def encrypt(%__MODULE__{type: @group, prv: prv}, plaintext) do
    Token.encrypt(prv, plaintext)
  end

  @doc """
  Decrypts ciphertext for this destination.

  - PLAIN: returns ciphertext unchanged
  - SINGLE: uses Identity ECDH decryption, with optional ratchets
  - GROUP: uses Token (Fernet) symmetric decryption

  Returns the plaintext, or nil if decryption fails.
  """
  @spec decrypt(t(), binary()) :: binary() | nil
  def decrypt(%__MODULE__{type: @plain}, ciphertext), do: ciphertext

  def decrypt(
        %__MODULE__{type: @single, identity: identity, ratchets: ratchets} = dest,
        ciphertext
      )
      when identity != nil and is_list(ratchets) do
    Identity.decrypt(identity, ciphertext,
      ratchets: ratchets,
      enforce_ratchets: dest.enforce_ratchets
    )
  end

  def decrypt(%__MODULE__{type: @single, identity: identity} = dest, ciphertext)
      when identity != nil do
    Identity.decrypt(identity, ciphertext, enforce_ratchets: dest.enforce_ratchets)
  end

  def decrypt(%__MODULE__{type: @group, prv: nil}, _ciphertext) do
    raise ArgumentError, "No private key held by GROUP destination. Did you create or load one?"
  end

  def decrypt(%__MODULE__{type: @group, prv: prv}, ciphertext) do
    try do
      Token.decrypt(prv, ciphertext)
    rescue
      _ -> nil
    end
  end

  # ── Signing ─────────────────────────────────────────────────────

  @doc """
  Signs a message. Only SINGLE destinations with an identity can sign.

  Returns the 64-byte signature, or nil for other destination types.
  """
  @spec sign(t(), binary()) :: binary() | nil
  def sign(%__MODULE__{type: @single, identity: identity}, message) when identity != nil do
    Identity.sign(identity, message)
  end

  def sign(%__MODULE__{}, _message), do: nil

  # ── GROUP key management ────────────────────────────────────────

  @doc """
  Creates a new symmetric key for a GROUP destination.

  Raises for PLAIN and SINGLE destination types.
  """
  @spec create_keys(t()) :: t()
  def create_keys(%__MODULE__{type: @plain}) do
    raise ArgumentError, "A plain destination does not hold any keys"
  end

  def create_keys(%__MODULE__{type: @single}) do
    raise ArgumentError, "A single destination holds keys through an Identity instance"
  end

  def create_keys(%__MODULE__{type: @group} = dest) do
    key = Token.generate_key()
    %{dest | prv_bytes: key, prv: Token.new(key)}
  end

  @doc """
  Returns the symmetric private key for a GROUP destination.

  Raises for PLAIN and SINGLE destination types.
  """
  @spec private_key(t()) :: binary() | nil
  def private_key(%__MODULE__{type: @plain}) do
    raise ArgumentError, "A plain destination does not hold any keys"
  end

  def private_key(%__MODULE__{type: @single}) do
    raise ArgumentError, "A single destination holds keys through an Identity instance"
  end

  def private_key(%__MODULE__{prv_bytes: prv_bytes}), do: prv_bytes

  @doc """
  Loads a symmetric private key for a GROUP destination.

  Raises for PLAIN and SINGLE destination types.
  """
  @spec load_private_key(t(), binary()) :: t()
  def load_private_key(%__MODULE__{type: @plain}, _key) do
    raise ArgumentError, "A plain destination does not hold any keys"
  end

  def load_private_key(%__MODULE__{type: @single}, _key) do
    raise ArgumentError, "A single destination holds keys through an Identity instance"
  end

  def load_private_key(%__MODULE__{type: @group} = dest, key) when is_binary(key) do
    %{dest | prv_bytes: key, prv: Token.new(key)}
  end

  # ── Callback registration ───────────────────────────────────────

  @doc """
  Registers a callback for when a link is established to this destination.

  Callback signature: `callback(link)`
  """
  @spec set_link_established_callback(t(), function()) :: t()
  def set_link_established_callback(dest, callback) do
    %{dest | callbacks: Map.put(dest.callbacks, :link_established, callback)}
  end

  @doc """
  Registers a callback for when a packet is received by this destination.

  Callback signature: `callback(data, packet)`
  """
  @spec set_packet_callback(t(), function()) :: t()
  def set_packet_callback(dest, callback) do
    %{dest | callbacks: Map.put(dest.callbacks, :packet, callback)}
  end

  @doc """
  Registers a callback for when a proof is requested for a received packet.

  Callback signature: `callback(packet)` returning true or false.
  """
  @spec set_proof_requested_callback(t(), function()) :: t()
  def set_proof_requested_callback(dest, callback) do
    %{dest | callbacks: Map.put(dest.callbacks, :proof_requested, callback)}
  end

  @doc """
  Sets the proof strategy for this destination.
  """
  @spec set_proof_strategy(t(), non_neg_integer()) :: t()
  def set_proof_strategy(dest, strategy) when strategy in @proof_strategies do
    %{dest | proof_strategy: strategy}
  end

  def set_proof_strategy(_dest, strategy) do
    raise ArgumentError, "Unsupported proof strategy: #{inspect(strategy)}"
  end

  @doc """
  Sets the default app_data for announces. Can be bytes or a zero-arity callable.
  """
  @spec set_default_app_data(t(), binary() | function() | nil) :: t()
  def set_default_app_data(dest, app_data \\ nil) do
    %{dest | default_app_data: app_data}
  end

  @doc """
  Clears the default app_data.
  """
  @spec clear_default_app_data(t()) :: t()
  def clear_default_app_data(dest) do
    set_default_app_data(dest, nil)
  end

  # ── Link acceptance ─────────────────────────────────────────────

  @doc """
  Returns whether the destination accepts incoming link requests.
  """
  @spec accepts_links?(t()) :: boolean()
  def accepts_links?(%__MODULE__{accept_link_requests: accepts}), do: accepts

  @doc """
  Sets whether the destination accepts incoming link requests.
  """
  @spec set_accepts_links(t(), boolean()) :: t()
  def set_accepts_links(dest, accepts) when is_boolean(accepts) do
    %{dest | accept_link_requests: accepts}
  end

  # ── Request handlers ────────────────────────────────────────────

  @doc """
  Registers a request handler for the given path.

  ## Options

    * `:response_generator` - a function to generate responses (required)
    * `:allow` - request policy (default: ALLOW_NONE)
    * `:allowed_list` - list of allowed identity hashes
    * `:auto_compress` - whether to auto-compress responses (default: true)

  """
  @spec register_request_handler(t(), String.t(), keyword()) :: t()
  def register_request_handler(dest, path, opts \\ []) do
    response_generator = Keyword.get(opts, :response_generator)
    allow = Keyword.get(opts, :allow, @allow_none)
    allowed_list = Keyword.get(opts, :allowed_list)
    auto_compress = Keyword.get(opts, :auto_compress, true)

    if path == nil or path == "" do
      raise ArgumentError, "Invalid path specified"
    end

    unless is_function(response_generator) do
      raise ArgumentError, "Invalid response generator specified"
    end

    unless allow in @request_policies do
      raise ArgumentError, "Invalid request policy"
    end

    path_hash = Identity.truncated_hash(path)

    handler = %{
      path: path,
      response_generator: response_generator,
      allow: allow,
      allowed_list: allowed_list,
      auto_compress: auto_compress
    }

    %{dest | request_handlers: Map.put(dest.request_handlers, path_hash, handler)}
  end

  @doc """
  Deregisters a request handler for the given path.

  Returns `{success, updated_destination}`.
  """
  @spec deregister_request_handler(t(), String.t()) :: {boolean(), t()}
  def deregister_request_handler(dest, path) do
    path_hash = Identity.truncated_hash(path)

    if Map.has_key?(dest.request_handlers, path_hash) do
      {true, %{dest | request_handlers: Map.delete(dest.request_handlers, path_hash)}}
    else
      {false, dest}
    end
  end

  # ── Receive ─────────────────────────────────────────────────────

  @doc """
  Processes an incoming packet for this destination.

  Returns `{success, updated_destination}`.
  """
  @spec receive_packet(t(), RNS.Packet.t()) :: {boolean(), t()}
  def receive_packet(%__MODULE__{} = dest, packet) do
    if packet.packet_type == @linkrequest do
      incoming_link_request(dest, packet.data, packet)
    else
      plaintext = decrypt(dest, packet.data)

      if plaintext == nil do
        {false, dest}
      else
        if packet.packet_type == @data and dest.callbacks.packet != nil do
          try do
            dest.callbacks.packet.(plaintext, packet)
          rescue
            _ -> :ok
          end
        end

        {true, dest}
      end
    end
  end

  defp incoming_link_request(dest, _data, _packet) do
    if dest.accept_link_requests do
      # Link.validate_request will be implemented in Phase 5
      {true, dest}
    else
      {false, dest}
    end
  end

  # ── String representation ───────────────────────────────────────

  defimpl String.Chars do
    def to_string(dest) do
      "<#{dest.name}:#{dest.hexhash}>"
    end
  end
end
