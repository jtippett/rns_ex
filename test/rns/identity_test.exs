defmodule RNS.IdentityTest do
  use ExUnit.Case, async: true

  alias RNS.Identity

  # Constants from Python Identity class
  @keysize 512
  @hashlength 256
  @name_hash_length 80
  @truncated_hashlength 128
  @ratchetsize 256
  @siglength @keysize
  @token_overhead 48
  @derived_key_length 64

  describe "constants" do
    test "KEYSIZE is 512 bits" do
      assert Identity.keysize() == @keysize
    end

    test "HASHLENGTH is 256 bits" do
      assert Identity.hashlength() == @hashlength
    end

    test "NAME_HASH_LENGTH is 80 bits" do
      assert Identity.name_hash_length() == @name_hash_length
    end

    test "TRUNCATED_HASHLENGTH is 128 bits" do
      assert Identity.truncated_hashlength() == @truncated_hashlength
    end

    test "RATCHETSIZE is 256 bits" do
      assert Identity.ratchetsize() == @ratchetsize
    end

    test "SIGLENGTH equals KEYSIZE" do
      assert Identity.siglength() == @siglength
    end

    test "TOKEN_OVERHEAD is 48 bytes" do
      assert Identity.token_overhead() == @token_overhead
    end

    test "DERIVED_KEY_LENGTH is 64 bytes (512//8)" do
      assert Identity.derived_key_length() == @derived_key_length
    end

    test "CURVE is Curve25519" do
      assert Identity.curve() == "Curve25519"
    end
  end

  describe "new/0 and create_keys/0" do
    test "creates identity with all key fields populated" do
      id = Identity.new()
      assert is_binary(id.prv_bytes)
      assert is_binary(id.sig_prv_bytes)
      assert is_binary(id.pub_bytes)
      assert is_binary(id.sig_pub_bytes)
      assert is_binary(id.hash)
      assert is_binary(id.hexhash)
    end

    test "encryption private key is 32 bytes" do
      id = Identity.new()
      assert byte_size(id.prv_bytes) == 32
    end

    test "signing private key is 32 bytes" do
      id = Identity.new()
      assert byte_size(id.sig_prv_bytes) == 32
    end

    test "encryption public key is 32 bytes" do
      id = Identity.new()
      assert byte_size(id.pub_bytes) == 32
    end

    test "signing public key is 32 bytes" do
      id = Identity.new()
      assert byte_size(id.sig_pub_bytes) == 32
    end

    test "hash is TRUNCATED_HASHLENGTH // 8 bytes" do
      id = Identity.new()
      assert byte_size(id.hash) == @truncated_hashlength |> div(8)
    end

    test "hexhash is hex-encoded hash" do
      id = Identity.new()
      assert id.hexhash == Base.encode16(id.hash, case: :lower)
    end

    test "each new identity has unique keys" do
      id1 = Identity.new()
      id2 = Identity.new()
      assert id1.prv_bytes != id2.prv_bytes
      assert id1.pub_bytes != id2.pub_bytes
      assert id1.hash != id2.hash
    end

    test "new with create_keys: false creates empty identity" do
      id = Identity.new(create_keys: false)
      assert id.prv_bytes == nil
      assert id.sig_prv_bytes == nil
      assert id.pub_bytes == nil
      assert id.sig_pub_bytes == nil
      assert id.hash == nil
      assert id.hexhash == nil
    end
  end

  describe "get_private_key/1 and get_public_key/1" do
    test "get_private_key returns 64-byte concatenation of prv + sig_prv" do
      id = Identity.new()
      prv = Identity.get_private_key(id)
      assert byte_size(prv) == @keysize |> div(8)
      assert prv == id.prv_bytes <> id.sig_prv_bytes
    end

    test "get_public_key returns 64-byte concatenation of pub + sig_pub" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      assert byte_size(pub) == @keysize |> div(8)
      assert pub == id.pub_bytes <> id.sig_pub_bytes
    end
  end

  describe "load_private_key/2" do
    test "loads 64-byte private key and derives all keys" do
      id1 = Identity.new()
      prv = Identity.get_private_key(id1)

      id2 = Identity.new(create_keys: false)
      assert {:ok, id2} = Identity.load_private_key(id2, prv)

      assert id2.prv_bytes == id1.prv_bytes
      assert id2.sig_prv_bytes == id1.sig_prv_bytes
      assert id2.pub_bytes == id1.pub_bytes
      assert id2.sig_pub_bytes == id1.sig_pub_bytes
      assert id2.hash == id1.hash
      assert id2.hexhash == id1.hexhash
    end

    test "derives correct public keys from private keys" do
      id = Identity.new()
      prv = Identity.get_private_key(id)

      id2 = Identity.new(create_keys: false)
      {:ok, id2} = Identity.load_private_key(id2, prv)

      # Public keys should match
      assert Identity.get_public_key(id) == Identity.get_public_key(id2)
    end
  end

  describe "load_public_key/2" do
    test "loads 64-byte public key" do
      id1 = Identity.new()
      pub = Identity.get_public_key(id1)

      id2 = Identity.new(create_keys: false)
      id2 = Identity.load_public_key(id2, pub)

      assert id2.pub_bytes == id1.pub_bytes
      assert id2.sig_pub_bytes == id1.sig_pub_bytes
      assert id2.hash == id1.hash
      assert id2.hexhash == id1.hexhash
    end

    test "does not set private keys when loading public key" do
      id1 = Identity.new()
      pub = Identity.get_public_key(id1)

      id2 = Identity.new(create_keys: false)
      id2 = Identity.load_public_key(id2, pub)

      assert id2.prv_bytes == nil
      assert id2.sig_prv_bytes == nil
    end
  end

  describe "from_bytes/1" do
    test "creates identity from private key bytes" do
      id1 = Identity.new()
      prv = Identity.get_private_key(id1)

      id2 = Identity.from_bytes(prv)
      assert id2 != nil
      assert Identity.get_public_key(id2) == Identity.get_public_key(id1)
      assert id2.hash == id1.hash
    end

    test "returns nil for invalid bytes" do
      assert Identity.from_bytes(<<>>) == nil
    end
  end

  describe "to_file/2 and from_file/1" do
    test "roundtrip save and load identity" do
      id1 = Identity.new()
      path = Path.join(System.tmp_dir!(), "rns_identity_test_#{:rand.uniform(100_000)}")

      try do
        assert Identity.to_file(id1, path) == true
        id2 = Identity.from_file(path)
        assert id2 != nil
        assert Identity.get_private_key(id2) == Identity.get_private_key(id1)
        assert Identity.get_public_key(id2) == Identity.get_public_key(id1)
        assert id2.hash == id1.hash
      after
        File.rm(path)
      end
    end

    test "from_file returns nil for nonexistent file" do
      assert Identity.from_file("/tmp/nonexistent_identity_#{:rand.uniform(100_000)}") == nil
    end
  end

  describe "sign/2 and validate/3" do
    test "sign returns 64-byte signature" do
      id = Identity.new()
      sig = Identity.sign(id, "hello world")
      assert byte_size(sig) == @siglength |> div(8)
    end

    test "validate returns true for valid signature" do
      id = Identity.new()
      msg = "test message"
      sig = Identity.sign(id, msg)
      assert Identity.validate(id, sig, msg) == true
    end

    test "validate returns false for wrong message" do
      id = Identity.new()
      sig = Identity.sign(id, "original")
      assert Identity.validate(id, sig, "tampered") == false
    end

    test "validate returns false for wrong key" do
      id1 = Identity.new()
      id2 = Identity.new()
      sig = Identity.sign(id1, "message")
      assert Identity.validate(id2, sig, "message") == false
    end

    test "sign raises when no private key" do
      id1 = Identity.new()
      pub = Identity.get_public_key(id1)
      id2 = Identity.new(create_keys: false)
      id2 = Identity.load_public_key(id2, pub)

      assert_raise KeyError, fn ->
        Identity.sign(id2, "hello")
      end
    end

    test "validate raises when no public key" do
      id = Identity.new(create_keys: false)

      assert_raise KeyError, fn ->
        Identity.validate(id, <<0::512>>, "hello")
      end
    end
  end

  describe "encrypt/2 and decrypt/2" do
    test "roundtrip encrypt/decrypt" do
      id = Identity.new()
      plaintext = "hello world"
      ciphertext = Identity.encrypt(id, plaintext)
      assert Identity.decrypt(id, ciphertext) == plaintext
    end

    test "ciphertext is larger than plaintext by overhead" do
      id = Identity.new()
      plaintext = "test data"
      ciphertext = Identity.encrypt(id, plaintext)
      # Ephemeral pub key (32) + Token overhead (48) + padded data
      assert byte_size(ciphertext) > byte_size(plaintext) + 32 + @token_overhead
    end

    test "encrypt with different identity can be decrypted by that identity" do
      receiver_id = Identity.new()

      # Encrypt for receiver (using receiver's public key)
      receiver_pub_only = Identity.new(create_keys: false)

      receiver_pub_only =
        Identity.load_public_key(receiver_pub_only, Identity.get_public_key(receiver_id))

      ciphertext = Identity.encrypt(receiver_pub_only, "secret message")
      assert Identity.decrypt(receiver_id, ciphertext) == "secret message"
    end

    test "encrypt raises when no public key" do
      id = Identity.new(create_keys: false)

      assert_raise KeyError, fn ->
        Identity.encrypt(id, "hello")
      end
    end

    test "decrypt raises when no private key" do
      id1 = Identity.new()
      ciphertext = Identity.encrypt(id1, "hello")

      id2 = Identity.new(create_keys: false)
      id2 = Identity.load_public_key(id2, Identity.get_public_key(id1))

      assert_raise KeyError, fn ->
        Identity.decrypt(id2, ciphertext)
      end
    end

    test "decrypt returns nil for invalid ciphertext" do
      id = Identity.new()
      assert Identity.decrypt(id, :crypto.strong_rand_bytes(100)) == nil
    end

    test "decrypt returns nil for too-short ciphertext" do
      id = Identity.new()
      assert Identity.decrypt(id, <<0::128>>) == nil
    end

    test "encrypts empty data" do
      id = Identity.new()
      ciphertext = Identity.encrypt(id, "")
      assert Identity.decrypt(id, ciphertext) == ""
    end

    test "encrypts large data" do
      id = Identity.new()
      data = :crypto.strong_rand_bytes(4096)
      ciphertext = Identity.encrypt(id, data)
      assert Identity.decrypt(id, ciphertext) == data
    end
  end

  describe "full_hash/1" do
    test "returns SHA-256 hash" do
      data = "test"
      assert Identity.full_hash(data) == :crypto.hash(:sha256, data)
    end

    test "returns 32 bytes" do
      assert byte_size(Identity.full_hash("data")) == 32
    end
  end

  describe "truncated_hash/1" do
    test "returns first 16 bytes of SHA-256" do
      data = "test"
      <<expected::binary-size(16), _::binary>> = :crypto.hash(:sha256, data)
      assert Identity.truncated_hash(data) == expected
    end

    test "returns 16 bytes" do
      assert byte_size(Identity.truncated_hash("data")) == 16
    end
  end

  describe "get_random_hash/0" do
    test "returns 16 bytes" do
      assert byte_size(Identity.get_random_hash()) == 16
    end

    test "returns unique values" do
      h1 = Identity.get_random_hash()
      h2 = Identity.get_random_hash()
      assert h1 != h2
    end
  end

  describe "hash computation" do
    test "hash is truncated hash of public key" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      expected = Identity.truncated_hash(pub)
      assert id.hash == expected
    end
  end

  describe "get_salt/1 and get_context/1" do
    test "get_salt returns identity hash" do
      id = Identity.new()
      assert Identity.get_salt(id) == id.hash
    end

    test "get_context returns nil" do
      id = Identity.new()
      assert Identity.get_context(id) == nil
    end
  end

  describe "encrypt with ratchet" do
    test "encrypt/decrypt with ratchet key" do
      id = Identity.new()
      # Generate a ratchet (just an X25519 private key)
      ratchet_prv = RNS.Cryptography.X25519.generate_keypair()
      ratchet_pub_bytes = RNS.Cryptography.X25519.public_key(ratchet_prv)
      ratchet_prv_bytes = RNS.Cryptography.X25519.private_bytes(ratchet_prv)

      plaintext = "ratcheted message"
      ciphertext = Identity.encrypt(id, plaintext, ratchet: ratchet_pub_bytes)

      # Decrypt with ratchet list
      result = Identity.decrypt(id, ciphertext, ratchets: [ratchet_prv_bytes])
      assert result == plaintext
    end

    test "decrypt without ratchet fails when encrypted with ratchet" do
      id = Identity.new()
      ratchet_prv = RNS.Cryptography.X25519.generate_keypair()
      ratchet_pub_bytes = RNS.Cryptography.X25519.public_key(ratchet_prv)

      plaintext = "ratcheted message"
      ciphertext = Identity.encrypt(id, plaintext, ratchet: ratchet_pub_bytes)

      # Without ratchet, should fail (return nil since HMAC won't match)
      assert Identity.decrypt(id, ciphertext) == nil
    end

    test "decrypt with enforce_ratchets returns nil when no ratchet matches" do
      id = Identity.new()
      plaintext = "test"
      # Encrypt without ratchet
      ciphertext = Identity.encrypt(id, plaintext)

      # Decrypt with enforce_ratchets and a wrong ratchet
      wrong_ratchet =
        RNS.Cryptography.X25519.private_bytes(RNS.Cryptography.X25519.generate_keypair())

      result = Identity.decrypt(id, ciphertext, ratchets: [wrong_ratchet], enforce_ratchets: true)
      assert result == nil
    end
  end
end

defmodule RNS.IdentityStoreTest do
  use ExUnit.Case, async: false

  alias RNS.Identity

  setup do
    # Start a fresh IdentityStore for each test
    store = start_supervised!(RNS.IdentityStore)
    %{store: store}
  end

  describe "remember/4" do
    test "remembers a destination with valid public key" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      dest_hash = Identity.truncated_hash(pub)
      packet_hash = :crypto.strong_rand_bytes(32)

      assert :ok = Identity.remember(packet_hash, dest_hash, pub)
    end

    test "remembers a destination with app_data" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      dest_hash = Identity.truncated_hash(pub)
      packet_hash = :crypto.strong_rand_bytes(32)
      app_data = "test app data"

      assert :ok = Identity.remember(packet_hash, dest_hash, pub, app_data)
    end

    test "rejects invalid public key length" do
      dest_hash = :crypto.strong_rand_bytes(16)
      packet_hash = :crypto.strong_rand_bytes(32)

      assert {:error, :invalid_public_key} =
               Identity.remember(packet_hash, dest_hash, <<1, 2, 3>>)
    end
  end

  describe "recall/1" do
    test "recalls a remembered identity by destination hash" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      dest_hash = Identity.truncated_hash(pub)
      packet_hash = :crypto.strong_rand_bytes(32)

      Identity.remember(packet_hash, dest_hash, pub)

      recalled = Identity.recall(dest_hash)
      assert recalled != nil
      assert Identity.get_public_key(recalled) == pub
    end

    test "returns nil for unknown destination hash" do
      assert Identity.recall(:crypto.strong_rand_bytes(16)) == nil
    end

    test "recalls with app_data" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      dest_hash = Identity.truncated_hash(pub)
      packet_hash = :crypto.strong_rand_bytes(32)
      app_data = "my app data"

      Identity.remember(packet_hash, dest_hash, pub, app_data)

      recalled = Identity.recall(dest_hash)
      assert recalled != nil
      assert recalled.app_data == app_data
    end

    test "recalls by identity hash" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      dest_hash = :crypto.strong_rand_bytes(16)
      packet_hash = :crypto.strong_rand_bytes(32)

      Identity.remember(packet_hash, dest_hash, pub)

      identity_hash = Identity.truncated_hash(pub)
      recalled = Identity.recall(identity_hash, from_identity_hash: true)
      assert recalled != nil
      assert Identity.get_public_key(recalled) == pub
    end

    test "recall by identity hash returns nil when not found" do
      assert Identity.recall(:crypto.strong_rand_bytes(16), from_identity_hash: true) == nil
    end
  end

  describe "recall_app_data/1" do
    test "recalls app_data for known destination" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      dest_hash = Identity.truncated_hash(pub)
      packet_hash = :crypto.strong_rand_bytes(32)
      app_data = "stored data"

      Identity.remember(packet_hash, dest_hash, pub, app_data)
      assert Identity.recall_app_data(dest_hash) == app_data
    end

    test "returns nil for unknown destination" do
      assert Identity.recall_app_data(:crypto.strong_rand_bytes(16)) == nil
    end

    test "returns nil when no app_data was stored" do
      id = Identity.new()
      pub = Identity.get_public_key(id)
      dest_hash = Identity.truncated_hash(pub)
      packet_hash = :crypto.strong_rand_bytes(32)

      Identity.remember(packet_hash, dest_hash, pub)
      assert Identity.recall_app_data(dest_hash) == nil
    end
  end

  describe "ratchet operations" do
    test "generate_ratchet returns 32-byte private key" do
      ratchet = Identity.generate_ratchet()
      assert byte_size(ratchet) == 32
    end

    test "ratchet_public_bytes returns public key for ratchet" do
      ratchet = Identity.generate_ratchet()
      pub = Identity.ratchet_public_bytes(ratchet)
      assert byte_size(pub) == 32
    end

    test "get_ratchet_id returns first NAME_HASH_LENGTH//8 bytes of hash" do
      ratchet = Identity.generate_ratchet()
      pub = Identity.ratchet_public_bytes(ratchet)
      ratchet_id = Identity.get_ratchet_id(pub)
      assert byte_size(ratchet_id) == div(Identity.name_hash_length(), 8)
    end

    test "remember_ratchet and get_ratchet roundtrip" do
      dest_hash = :crypto.strong_rand_bytes(16)
      ratchet = Identity.generate_ratchet()
      pub = Identity.ratchet_public_bytes(ratchet)

      Identity.remember_ratchet(dest_hash, pub)
      assert Identity.get_ratchet(dest_hash) == pub
    end

    test "get_ratchet returns nil for unknown destination" do
      assert Identity.get_ratchet(:crypto.strong_rand_bytes(16)) == nil
    end

    test "current_ratchet_id returns nil when no ratchet" do
      assert Identity.current_ratchet_id(:crypto.strong_rand_bytes(16)) == nil
    end

    test "current_ratchet_id returns ratchet id when ratchet exists" do
      dest_hash = :crypto.strong_rand_bytes(16)
      ratchet = Identity.generate_ratchet()
      pub = Identity.ratchet_public_bytes(ratchet)

      Identity.remember_ratchet(dest_hash, pub)

      ratchet_id = Identity.current_ratchet_id(dest_hash)
      assert ratchet_id != nil
      assert byte_size(ratchet_id) == div(Identity.name_hash_length(), 8)
    end
  end
end
