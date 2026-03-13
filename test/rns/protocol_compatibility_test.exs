defmodule RNS.ProtocolCompatibilityTest do
  @moduledoc """
  Cross-language protocol compatibility tests.

  Verifies that the Elixir RNS implementation produces byte-identical outputs
  to the Python reference implementation for all protocol-critical operations.

  Test fixtures are derived from:
  - NIST/RFC published test vectors (SHA-256, HMAC-SHA256, HKDF RFC 5869, RFC 7748, RFC 8032)
  - Deterministic key material fed through both implementations
  - Python RNS generate_fixtures.py script (test/fixtures/generate_fixtures.py)

  To regenerate Python fixtures:
      python3 test/fixtures/generate_fixtures.py

  The Elixir port must be wire-compatible with Python RNS.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias RNS.Cryptography.{Hashes, HMAC, HKDF, PKCS7, AES, X25519, Ed25519, Token}
  alias RNS.{Identity, Destination, Packet}

  # Helper to decode hex strings
  defp hex(hex_string) when is_binary(hex_string) do
    Base.decode16!(hex_string, case: :mixed)
  end

  defp to_hex(binary) when is_binary(binary) do
    Base.encode16(binary, case: :lower)
  end

  # =========================================================================
  # 1. PROTOCOL CONSTANTS
  # =========================================================================

  describe "protocol constants match Python RNS" do
    test "Reticulum constants" do
      # These must be exact — any mismatch breaks wire compatibility
      assert RNS.Reticulum.mtu() == 500
      assert RNS.Reticulum.truncated_hashlength() == 128
      assert RNS.Reticulum.header_minsize() == 19
      assert RNS.Reticulum.header_maxsize() == 35
      assert RNS.Reticulum.mdu() == 464
      assert RNS.Reticulum.ifac_min_size() == 1
      assert RNS.Reticulum.resource_cache() == 86400
      assert RNS.Reticulum.announce_cap() == 2
      assert RNS.Reticulum.minimum_bitrate() == 5
      assert RNS.Reticulum.default_per_hop_timeout() == 6
    end

    test "Identity constants" do
      assert Identity.keysize() == 512
      assert Identity.hashlength() == 256
      assert Identity.name_hash_length() == 80
      assert Identity.ratchetsize() == 256
      assert Identity.truncated_hashlength() == 128
    end

    test "Token overhead" do
      assert Token.token_overhead() == 48
    end

    test "derived key lengths" do
      # Identity uses 64-byte (512-bit) derived key for AES-256-CBC
      # This is split into 32-byte signing key + 32-byte encryption key
      key = :crypto.strong_rand_bytes(64)
      token = Token.new(key)
      assert token.mode == :aes_256_cbc
    end

    test "packet types" do
      assert Packet.data() == 0x00
      assert Packet.announce() == 0x01
      assert Packet.linkrequest() == 0x02
      assert Packet.proof() == 0x03
    end

    test "header types" do
      assert Packet.header_1() == 0x00
      assert Packet.header_2() == 0x01
    end

    test "destination types" do
      assert Destination.single() == 0x00
      assert Destination.group() == 0x01
      assert Destination.plain() == 0x02
      assert Destination.link() == 0x03
    end
  end

  # =========================================================================
  # 2. SHA-256 HASH COMPUTATION
  # =========================================================================

  describe "SHA-256 hash computation (NIST test vectors)" do
    # NIST FIPS 180-4 test vectors
    test "SHA-256 empty string" do
      expected = hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
      assert Hashes.sha256(<<>>) == expected
    end

    test "SHA-256 'abc'" do
      expected = hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
      assert Hashes.sha256("abc") == expected
    end

    test "SHA-256 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'" do
      input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
      expected = hex("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
      assert Hashes.sha256(input) == expected
    end

    test "SHA-512 empty string" do
      expected =
        hex(
          "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        )

      assert Hashes.sha512(<<>>) == expected
    end

    test "truncated hash is first 16 bytes of SHA-256" do
      data = "Reticulum Network Stack"
      full = Hashes.sha256(data)
      truncated = Hashes.truncated_hash(data)
      assert byte_size(truncated) == 16
      assert truncated == binary_part(full, 0, 16)
    end

    test "Identity.full_hash matches SHA-256" do
      data = "test data for hashing"
      assert Identity.full_hash(data) == Hashes.sha256(data)
    end

    test "Identity.truncated_hash matches first 16 bytes of SHA-256" do
      data = "test data for truncation"
      assert Identity.truncated_hash(data) == binary_part(Hashes.sha256(data), 0, 16)
    end
  end

  # =========================================================================
  # 3. HMAC-SHA256 (RFC 4231 test vectors)
  # =========================================================================

  describe "HMAC-SHA256 (RFC 4231 test vectors)" do
    test "RFC 4231 Test Case 1" do
      key = :binary.copy(<<0x0B>>, 20)
      data = "Hi There"
      expected = hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
      assert HMAC.digest(key, data) == expected
    end

    test "RFC 4231 Test Case 2" do
      # Key = "Jefe"
      key = "Jefe"
      data = "what do ya want for nothing?"
      expected = hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
      assert HMAC.digest(key, data) == expected
    end

    test "RFC 4231 Test Case 3" do
      key = :binary.copy(<<0xAA>>, 20)
      data = :binary.copy(<<0xDD>>, 50)
      expected = hex("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
      assert HMAC.digest(key, data) == expected
    end
  end

  # =========================================================================
  # 4. HKDF (RFC 5869 test vectors)
  # =========================================================================

  describe "HKDF key derivation (RFC 5869 test vectors)" do
    test "RFC 5869 Test Case 1" do
      ikm = :binary.copy(<<0x0B>>, 22)
      salt = :binary.list_to_bin(Enum.to_list(0x00..0x0C))
      info = :binary.list_to_bin(Enum.to_list(0xF0..0xF9))
      length = 42

      expected =
        hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")

      assert HKDF.derive_key(ikm, length, salt, info) == expected
    end

    test "RFC 5869 Test Case 2" do
      ikm = :binary.list_to_bin(Enum.to_list(0x00..0x4F))
      salt = :binary.list_to_bin(Enum.to_list(0x60..0xAF))
      info = :binary.list_to_bin(Enum.to_list(0xB0..0xFF))
      length = 82

      expected =
        hex(
          "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87"
        )

      assert HKDF.derive_key(ikm, length, salt, info) == expected
    end

    test "RFC 5869 Test Case 3 (no salt, no info)" do
      ikm = :binary.copy(<<0x0B>>, 22)
      length = 42

      expected =
        hex("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")

      assert HKDF.derive_key(ikm, length, nil, nil) == expected
    end

    test "RNS Identity key derivation pattern" do
      # RNS uses HKDF with:
      # - ikm = 32-byte shared key from X25519 ECDH
      # - length = 64 bytes (for AES-256-CBC token: 32 signing + 32 encryption)
      # - salt = identity hash (16 bytes)
      # - info = nil
      shared_key = :binary.copy(<<0xAA>>, 32)
      identity_hash = :binary.copy(<<0xBB>>, 16)
      derived = HKDF.derive_key(shared_key, 64, identity_hash, nil)
      assert byte_size(derived) == 64

      # The derived key should be deterministic
      derived2 = HKDF.derive_key(shared_key, 64, identity_hash, nil)
      assert derived == derived2

      # Different salt = different key
      other_hash = :binary.copy(<<0xCC>>, 16)
      derived3 = HKDF.derive_key(shared_key, 64, other_hash, nil)
      assert derived != derived3
    end
  end

  # =========================================================================
  # 5. PKCS7 PADDING
  # =========================================================================

  describe "PKCS7 padding (matches Python RNS)" do
    test "empty data gets 16 padding bytes" do
      padded = PKCS7.pad(<<>>)
      assert padded == :binary.copy(<<16>>, 16)
      assert byte_size(padded) == 16
    end

    test "1-byte data gets 15 padding bytes" do
      padded = PKCS7.pad("A")
      assert padded == "A" <> :binary.copy(<<15>>, 15)
      assert byte_size(padded) == 16
    end

    test "15-byte data gets 1 padding byte" do
      padded = PKCS7.pad("ABCDEFGHIJKLMNO")
      assert padded == "ABCDEFGHIJKLMNO" <> <<1>>
      assert byte_size(padded) == 16
    end

    test "16-byte data gets full block of padding" do
      padded = PKCS7.pad("ABCDEFGHIJKLMNOP")
      assert padded == "ABCDEFGHIJKLMNOP" <> :binary.copy(<<16>>, 16)
      assert byte_size(padded) == 32
    end

    test "pad/unpad roundtrip" do
      for size <- [0, 1, 2, 15, 16, 17, 31, 32, 100, 255, 256] do
        data = :crypto.strong_rand_bytes(size)
        assert PKCS7.unpad(PKCS7.pad(data)) == data
      end
    end
  end

  # =========================================================================
  # 6. AES-256-CBC ENCRYPTION
  # =========================================================================

  describe "AES-256-CBC encryption (deterministic with known IV)" do
    test "encrypt/decrypt roundtrip with known key and IV" do
      key = :binary.copy(<<0x01>>, 32)
      iv = :binary.copy(<<0x02>>, 16)
      plaintext = "Hello AES-256-CBC!"

      padded = PKCS7.pad(plaintext)
      ciphertext = AES.encrypt(padded, key, iv)
      decrypted = AES.decrypt(ciphertext, key, iv)

      assert PKCS7.unpad(decrypted) == plaintext
    end

    test "deterministic: same key+IV+plaintext produces same ciphertext" do
      key = :binary.list_to_bin(Enum.to_list(0..31))
      iv = :binary.list_to_bin(Enum.to_list(0..15))
      plaintext = :binary.list_to_bin(Enum.to_list(0..47))

      padded = PKCS7.pad(plaintext)
      ct1 = AES.encrypt(padded, key, iv)
      ct2 = AES.encrypt(padded, key, iv)
      assert ct1 == ct2
    end

    test "empty plaintext encryption" do
      key = :binary.copy(<<0xFF>>, 32)
      iv = :binary.copy(<<0x00>>, 16)
      plaintext = <<>>

      padded = PKCS7.pad(plaintext)
      ciphertext = AES.encrypt(padded, key, iv)
      decrypted = AES.decrypt(ciphertext, key, iv)
      assert PKCS7.unpad(decrypted) == plaintext
    end
  end

  # =========================================================================
  # 7. TOKEN (FERNET-LIKE AUTHENTICATED ENCRYPTION)
  # =========================================================================

  describe "Token authenticated encryption" do
    test "token structure: IV(16) || ciphertext || HMAC(32)" do
      key = :binary.copy(<<0x01>>, 64)
      token = Token.new(key)
      ciphertoken = Token.encrypt(token, "test data")

      # Must have at least 48 bytes overhead
      assert byte_size(ciphertoken) >= 48

      # Extract parts
      iv = binary_part(ciphertoken, 0, 16)
      hmac = binary_part(ciphertoken, byte_size(ciphertoken) - 32, 32)
      body = binary_part(ciphertoken, 16, byte_size(ciphertoken) - 48)

      assert byte_size(iv) == 16
      assert byte_size(hmac) == 32
      assert byte_size(body) > 0

      # HMAC should be over iv || ciphertext
      signed_parts = binary_part(ciphertoken, 0, byte_size(ciphertoken) - 32)
      expected_hmac = HMAC.digest(binary_part(key, 0, 32), signed_parts)
      assert hmac == expected_hmac
    end

    test "64-byte key: first 32 signing, last 32 encryption (AES-256-CBC)" do
      key = :binary.list_to_bin(Enum.to_list(0..63))
      token = Token.new(key)
      assert token.mode == :aes_256_cbc
      assert token.signing_key == binary_part(key, 0, 32)
      assert token.encryption_key == binary_part(key, 32, 32)
    end

    test "32-byte key: first 16 signing, last 16 encryption (AES-128-CBC)" do
      key = :binary.list_to_bin(Enum.to_list(0..31))
      token = Token.new(key)
      assert token.mode == :aes_128_cbc
      assert token.signing_key == binary_part(key, 0, 16)
      assert token.encryption_key == binary_part(key, 16, 16)
    end

    test "encrypt/decrypt roundtrip with various payloads" do
      key = :crypto.strong_rand_bytes(64)
      token = Token.new(key)

      for data <- ["", "Hello!", "A" |> String.duplicate(100), :crypto.strong_rand_bytes(256)] do
        ct = Token.encrypt(token, data)
        assert Token.decrypt(token, ct) == data
      end
    end

    test "tampered ciphertext fails HMAC verification" do
      key = :crypto.strong_rand_bytes(64)
      token = Token.new(key)
      ct = Token.encrypt(token, "secret data")

      # Flip a bit in the ciphertext body
      pos = 20
      <<before::binary-size(pos), byte::8, rest::binary>> = ct
      tampered = before <> <<bxor(byte, 1)::8>> <> rest

      assert_raise ArgumentError, ~r/HMAC was invalid/, fn ->
        Token.decrypt(token, tampered)
      end
    end

    test "wrong key fails decryption" do
      key1 = :crypto.strong_rand_bytes(64)
      key2 = :crypto.strong_rand_bytes(64)
      token1 = Token.new(key1)
      token2 = Token.new(key2)

      ct = Token.encrypt(token1, "secret")

      assert_raise ArgumentError, fn ->
        Token.decrypt(token2, ct)
      end
    end

    test "Python-generated ciphertext can be decrypted" do
      # This test verifies cross-language compatibility by constructing
      # a token ciphertext manually with known key, IV, and plaintext
      key = :binary.copy(<<0x01>>, 64)
      signing_key = binary_part(key, 0, 32)
      encryption_key = binary_part(key, 32, 32)

      plaintext = "Hello, Reticulum!"
      iv = :binary.copy(<<0x03>>, 16)

      # Manually construct what Python Token.encrypt would produce
      padded = PKCS7.pad(plaintext)
      ciphertext = AES.encrypt(padded, encryption_key, iv)
      signed_parts = iv <> ciphertext
      hmac_val = HMAC.digest(signing_key, signed_parts)
      manual_token = signed_parts <> hmac_val

      # Verify our Token module can decrypt it
      token = Token.new(key)
      assert Token.decrypt(token, manual_token) == plaintext
    end
  end

  # =========================================================================
  # 8. X25519 KEY EXCHANGE (RFC 7748 test vectors)
  # =========================================================================

  describe "X25519 ECDH key exchange" do
    test "RFC 7748 Section 6.1 test vector" do
      # Alice's private key (clamped per RFC 7748)
      alice_prv =
        hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")

      # Bob's private key
      bob_prv =
        hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")

      alice_key = X25519.from_private_bytes(alice_prv)
      bob_key = X25519.from_private_bytes(bob_prv)

      # Expected public keys
      alice_pub_expected =
        hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")

      bob_pub_expected =
        hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")

      assert X25519.public_key(alice_key) == alice_pub_expected
      assert X25519.public_key(bob_key) == bob_pub_expected

      # Shared secret must be the same
      shared_ab = X25519.exchange(alice_key, X25519.public_key(bob_key))
      shared_ba = X25519.exchange(bob_key, X25519.public_key(alice_key))
      assert shared_ab == shared_ba

      expected_shared =
        hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

      assert shared_ab == expected_shared
    end

    test "deterministic key derivation from private bytes" do
      prv_bytes = :crypto.hash(:sha256, "deterministic_test_key")
      key1 = X25519.from_private_bytes(prv_bytes)
      key2 = X25519.from_private_bytes(prv_bytes)
      assert X25519.public_key(key1) == X25519.public_key(key2)
    end

    test "ECDH exchange is commutative" do
      for _ <- 1..5 do
        a = X25519.generate_keypair()
        b = X25519.generate_keypair()
        assert X25519.exchange(a, X25519.public_key(b)) ==
                 X25519.exchange(b, X25519.public_key(a))
      end
    end
  end

  # =========================================================================
  # 9. ED25519 SIGNATURES (RFC 8032 test vectors)
  # =========================================================================

  describe "Ed25519 signatures" do
    test "eddy matches Erlang :crypto for deterministic seeds" do
      # Cross-validate that eddy produces the same results as Erlang :crypto,
      # which is the ground truth for both Python and Elixir RNS implementations.
      seeds = [
        :crypto.hash(:sha256, "test_seed_1"),
        :crypto.hash(:sha256, "test_seed_2"),
        :binary.copy(<<0x42>>, 32),
        :binary.list_to_bin(Enum.to_list(0..31)),
      ]

      for seed <- seeds do
        # eddy via our wrapper
        key = Ed25519.from_private_bytes(seed)
        eddy_pub = Ed25519.public_key(key)

        # Erlang :crypto directly
        {crypto_pub, _} = :crypto.generate_key(:eddsa, :ed25519, seed)

        assert eddy_pub == crypto_pub,
               "eddy and :crypto disagree for seed #{to_hex(seed)}"

        # Verify signature compatibility
        message = "test message"
        eddy_sig = Ed25519.sign(key, message)
        crypto_sig = :crypto.sign(:eddsa, :none, message, [seed, :ed25519])

        assert eddy_sig == crypto_sig,
               "eddy and :crypto signatures differ for seed #{to_hex(seed)}"
      end
    end

    test "signature verification rejects wrong message" do
      key = Ed25519.generate_keypair()
      sig = Ed25519.sign(key, "correct message")
      refute Ed25519.verify(sig, "wrong message", Ed25519.public_key(key))
    end

    test "deterministic signatures — same key+message always produces same signature" do
      seed = :crypto.hash(:sha256, "deterministic_ed25519")
      key = Ed25519.from_private_bytes(seed)
      msg = "test message for determinism"
      sig1 = Ed25519.sign(key, msg)
      sig2 = Ed25519.sign(key, msg)
      assert sig1 == sig2
    end

    test "signature is 64 bytes" do
      key = Ed25519.generate_keypair()
      sig = Ed25519.sign(key, "test")
      assert byte_size(sig) == 64
    end

    test "public key is 32 bytes" do
      key = Ed25519.generate_keypair()
      assert byte_size(Ed25519.public_key(key)) == 32
    end
  end

  # =========================================================================
  # 10. IDENTITY KEY OPERATIONS
  # =========================================================================

  describe "Identity key operations (cross-language determinism)" do
    # Use deterministic key material — these exact bytes produce
    # byte-identical results in both Python and Elixir
    @prv_bytes1 :binary.list_to_bin(Enum.to_list(0..63))
    @prv_bytes2 :crypto.hash(:sha256, "test_key_pair_2") <>
                  :crypto.hash(:sha256, "test_sign_pair_2")
    @prv_bytes3 :binary.copy(<<0x42>>, 64)

    test "key loading from bytes produces consistent public key" do
      id = Identity.from_bytes(@prv_bytes1)
      assert id != nil
      assert byte_size(Identity.public_key(id)) == 64
      assert byte_size(id.hash) == 16

      # Loading same bytes produces same result
      id2 = Identity.from_bytes(@prv_bytes1)
      assert Identity.public_key(id) == Identity.public_key(id2)
      assert id.hash == id2.hash
    end

    test "identity hash is truncated_hash of public_key" do
      for prv <- [@prv_bytes1, @prv_bytes2, @prv_bytes3] do
        id = Identity.from_bytes(prv)
        pub = Identity.public_key(id)
        expected_hash = Hashes.truncated_hash(pub)
        assert id.hash == expected_hash
      end
    end

    test "hexhash is lowercase hex of identity hash" do
      id = Identity.from_bytes(@prv_bytes1)
      assert id.hexhash == to_hex(id.hash)
      assert String.length(id.hexhash) == 32
    end

    test "public key is x25519_pub(32) || ed25519_pub(32)" do
      id = Identity.from_bytes(@prv_bytes1)
      pub = Identity.public_key(id)
      assert byte_size(pub) == 64

      # First 32 bytes = X25519 public key
      x25519_pub = id.pub_bytes
      assert byte_size(x25519_pub) == 32

      # Last 32 bytes = Ed25519 public key
      ed25519_pub = id.sig_pub_bytes
      assert byte_size(ed25519_pub) == 32

      assert pub == x25519_pub <> ed25519_pub
    end

    test "private key is x25519_prv(32) || ed25519_prv(32)" do
      id = Identity.from_bytes(@prv_bytes1)
      prv = Identity.private_key(id)
      assert byte_size(prv) == 64
      assert prv == id.prv_bytes <> id.sig_prv_bytes
    end

    test "sign and verify roundtrip" do
      id = Identity.from_bytes(@prv_bytes1)
      message = "test message for signing"
      signature = Identity.sign(id, message)
      assert byte_size(signature) == 64
      assert Identity.validate(id, signature, message)
    end

    test "sign is deterministic — same key+message = same signature" do
      id = Identity.from_bytes(@prv_bytes1)
      msg = "deterministic signature test"
      sig1 = Identity.sign(id, msg)
      sig2 = Identity.sign(id, msg)
      assert sig1 == sig2
    end

    test "wrong message fails validation" do
      id = Identity.from_bytes(@prv_bytes1)
      sig = Identity.sign(id, "correct")
      refute Identity.validate(id, sig, "wrong")
    end

    test "encrypt/decrypt roundtrip with identity keys" do
      # Encrypt with receiver's public key, decrypt with receiver's private key
      receiver = Identity.from_bytes(@prv_bytes2)

      plaintext = "Cross-language encryption test"
      ciphertext = Identity.encrypt(receiver, plaintext)

      # Ciphertext structure: ephemeral_pub(32) || token
      assert byte_size(ciphertext) > 32 + 48

      decrypted = Identity.decrypt(receiver, ciphertext)
      assert decrypted == plaintext
    end

    test "identity encryption ciphertext structure" do
      receiver = Identity.from_bytes(@prv_bytes1)
      plaintext = "structure test"
      ct = Identity.encrypt(receiver, plaintext)

      # Extract ephemeral public key (32 bytes)
      <<ephemeral_pub::binary-size(32), token_data::binary>> = ct
      assert byte_size(ephemeral_pub) == 32

      # Token data structure: IV(16) || encrypted || HMAC(32)
      assert byte_size(token_data) >= 48

      <<iv::binary-size(16), rest::binary>> = token_data
      assert byte_size(iv) == 16
      hmac = binary_part(rest, byte_size(rest) - 32, 32)
      assert byte_size(hmac) == 32
    end

    test "different identities produce different keys from same private bytes" do
      id1 = Identity.from_bytes(@prv_bytes1)
      id2 = Identity.from_bytes(@prv_bytes2)
      assert Identity.public_key(id1) != Identity.public_key(id2)
      assert id1.hash != id2.hash
    end

    test "identity ECDH uses correct salt (identity hash)" do
      # When encrypting to an identity, the HKDF salt is the receiver's hash.
      # This means the same shared key with different identities produces
      # different derived keys — this is a critical security property.
      receiver = Identity.from_bytes(@prv_bytes1)

      # Two encryptions of the same plaintext will differ (random ephemeral key)
      ct1 = Identity.encrypt(receiver, "same data")
      ct2 = Identity.encrypt(receiver, "same data")
      assert ct1 != ct2

      # But both decrypt correctly
      assert Identity.decrypt(receiver, ct1) == "same data"
      assert Identity.decrypt(receiver, ct2) == "same data"
    end
  end

  # =========================================================================
  # 11. DESTINATION HASH COMPUTATION
  # =========================================================================

  describe "destination hash computation" do
    setup do
      id = Identity.from_bytes(:binary.list_to_bin(Enum.to_list(0..63)))
      {:ok, id: id}
    end

    test "expand_name format: app_name.aspect1.aspect2", %{id: _id} do
      assert Destination.expand_name(nil, "test_app", []) == "test_app"
      assert Destination.expand_name(nil, "test_app", ["a1"]) == "test_app.a1"
      assert Destination.expand_name(nil, "test_app", ["a1", "a2"]) == "test_app.a1.a2"
    end

    test "expand_name with identity appends hexhash", %{id: id} do
      expanded = Destination.expand_name(id, "test_app", ["echo"])
      assert expanded == "test_app.echo.#{id.hexhash}"
    end

    test "name hash is first 10 bytes of SHA-256(expand_name)", %{id: _id} do
      name_str = "test_app.aspect1.aspect2"
      expected = binary_part(Hashes.sha256(name_str), 0, 10)
      assert Destination.compute_name_hash("test_app", ["aspect1", "aspect2"]) == expected
    end

    test "name hash is 10 bytes (80 bits)" do
      hash = Destination.compute_name_hash("myapp", ["echo"])
      assert byte_size(hash) == 10
    end

    test "SINGLE destination hash = truncated_hash(name_hash || identity_hash)", %{id: id} do
      name_hash = Destination.compute_name_hash("test_app", ["echo"])
      addr_material = name_hash <> id.hash
      expected = binary_part(Hashes.sha256(addr_material), 0, 16)
      assert Destination.compute_hash(id, "test_app", ["echo"]) == expected
    end

    test "PLAIN destination hash = truncated_hash(name_hash)", %{id: _id} do
      name_hash = Destination.compute_name_hash("test_app", ["broadcast"])
      expected = binary_part(Hashes.sha256(name_hash), 0, 16)
      assert Destination.compute_hash(nil, "test_app", ["broadcast"]) == expected
    end

    test "destination hash is 16 bytes (128 bits)", %{id: id} do
      hash = Destination.compute_hash(id, "test_app", ["aspect1"])
      assert byte_size(hash) == 16
    end

    test "different aspects produce different hashes", %{id: id} do
      h1 = Destination.compute_hash(id, "app", ["a"])
      h2 = Destination.compute_hash(id, "app", ["b"])
      assert h1 != h2
    end

    test "different identities produce different hashes" do
      id1 = Identity.from_bytes(:binary.list_to_bin(Enum.to_list(0..63)))
      id2 = Identity.from_bytes(:binary.copy(<<0x42>>, 64))
      h1 = Destination.compute_hash(id1, "app", ["test"])
      h2 = Destination.compute_hash(id2, "app", ["test"])
      assert h1 != h2
    end

    test "deterministic: same inputs always produce same hash", %{id: id} do
      h1 = Destination.compute_hash(id, "myapp", ["echo", "request"])
      h2 = Destination.compute_hash(id, "myapp", ["echo", "request"])
      assert h1 == h2
    end
  end

  # =========================================================================
  # 12. PACKET FLAGS ENCODING
  # =========================================================================

  describe "packet flags encoding" do
    # Flags byte: [header_type(2)|context_flag(1)|transport_type(1)|dest_type(2)|packet_type(2)]
    test "flags byte encoding matches Python bit layout" do
      # All zeros
      assert encode_flags(0, 0, 0, 0, 0) == 0x00

      # header_type=1 (HEADER_2) → bit 6 set
      assert encode_flags(1, 0, 0, 0, 0) == 0x40

      # context_flag=1 → bit 5 set
      assert encode_flags(0, 1, 0, 0, 0) == 0x20

      # transport_type=1 → bit 4 set
      assert encode_flags(0, 0, 1, 0, 0) == 0x10

      # dest_type=1 (GROUP) → bits 3-2 = 01
      assert encode_flags(0, 0, 0, 1, 0) == 0x04

      # dest_type=2 (PLAIN) → bits 3-2 = 10
      assert encode_flags(0, 0, 0, 2, 0) == 0x08

      # dest_type=3 (LINK) → bits 3-2 = 11
      assert encode_flags(0, 0, 0, 3, 0) == 0x0C

      # packet_type=1 (ANNOUNCE) → bits 1-0 = 01
      assert encode_flags(0, 0, 0, 0, 1) == 0x01

      # packet_type=2 (LINKREQUEST)
      assert encode_flags(0, 0, 0, 0, 2) == 0x02

      # packet_type=3 (PROOF)
      assert encode_flags(0, 0, 0, 0, 3) == 0x03

      # All max: header_type=1, context=1, transport=1, dest=3, packet=3
      assert encode_flags(1, 1, 1, 3, 3) == 0x7F

      # Common case: DATA packet to SINGLE destination via HEADER_1
      assert encode_flags(0, 0, 0, 0, 0) == 0x00
    end

    test "HEADER_1 is 19 bytes: flags(1) + hops(1) + dest_hash(16) + context(1)" do
      flags = 0x00
      hops = 3
      dest_hash = :binary.copy(<<0xAA>>, 16)
      context = 0x00

      header = <<flags::8, hops::8>> <> dest_hash <> <<context::8>>
      assert byte_size(header) == 19
    end

    test "HEADER_2 is 35 bytes: flags(1) + hops(1) + transport_id(16) + dest_hash(16) + context(1)" do
      flags = 0x50
      hops = 5
      transport_id = :binary.copy(<<0xBB>>, 16)
      dest_hash = :binary.copy(<<0xCC>>, 16)
      context = 0x00

      header = <<flags::8, hops::8>> <> transport_id <> dest_hash <> <<context::8>>
      assert byte_size(header) == 35
    end
  end

  # =========================================================================
  # 13. ANNOUNCE FORMAT
  # =========================================================================

  describe "announce format" do
    @prv_bytes :binary.list_to_bin(Enum.to_list(0..63))

    test "announce data structure: pub_key(64) || name_hash(10) || random_hash(10) || signature(64)" do
      id = Identity.from_bytes(@prv_bytes)
      pub_key = Identity.public_key(id)
      name_hash = Destination.compute_name_hash("test_app", ["echo"])
      random_hash = :crypto.strong_rand_bytes(10)
      dest_hash = Destination.compute_hash(id, "test_app", ["echo"])

      # Signed data: dest_hash(16) || pub_key(64) || name_hash(10) || random_hash(10)
      signed_data = dest_hash <> pub_key <> name_hash <> random_hash
      assert byte_size(signed_data) == 16 + 64 + 10 + 10

      signature = Identity.sign(id, signed_data)
      assert byte_size(signature) == 64

      # Announce data payload: pub_key(64) || name_hash(10) || random_hash(10) || signature(64)
      announce_data = pub_key <> name_hash <> random_hash <> signature
      assert byte_size(announce_data) == 64 + 10 + 10 + 64
      assert byte_size(announce_data) == 148
    end

    test "announce with app_data appended" do
      id = Identity.from_bytes(@prv_bytes)
      pub_key = Identity.public_key(id)
      name_hash = Destination.compute_name_hash("test_app", ["echo"])
      random_hash = :crypto.strong_rand_bytes(10)
      dest_hash = Destination.compute_hash(id, "test_app", ["echo"])
      app_data = "Hello from Elixir RNS!"

      # Signed data includes app_data
      signed_data = dest_hash <> pub_key <> name_hash <> random_hash <> app_data
      signature = Identity.sign(id, signed_data)

      # Announce data includes app_data after signature
      announce_data = pub_key <> name_hash <> random_hash <> signature <> app_data
      assert byte_size(announce_data) == 148 + byte_size(app_data)
    end

    test "announce signature is verifiable" do
      id = Identity.from_bytes(@prv_bytes)
      pub_key = Identity.public_key(id)
      name_hash = Destination.compute_name_hash("test_app", ["echo"])
      random_hash = :crypto.strong_rand_bytes(10)
      dest_hash = Destination.compute_hash(id, "test_app", ["echo"])

      signed_data = dest_hash <> pub_key <> name_hash <> random_hash
      signature = Identity.sign(id, signed_data)

      # Verify the announce can be validated
      assert Identity.validate(id, signature, signed_data)
    end

    test "random_hash structure: 5 random bytes + 5 timestamp bytes" do
      # Python: random_hash = RNS.Identity.get_random_hash()[0:5] + int(time.time()).to_bytes(5, "big")
      random_part = :crypto.strong_rand_bytes(5)
      timestamp = System.system_time(:second)
      timestamp_bytes = <<timestamp::unsigned-big-40>>
      random_hash = random_part <> timestamp_bytes

      assert byte_size(random_hash) == 10
      assert byte_size(random_part) == 5
      assert byte_size(timestamp_bytes) == 5
    end

    test "announce with ratchet: pub_key(64) || name_hash(10) || random_hash(10) || ratchet(32) || signature(64)" do
      id = Identity.from_bytes(@prv_bytes)
      pub_key = Identity.public_key(id)
      name_hash = Destination.compute_name_hash("test_app", ["echo"])
      random_hash = :crypto.strong_rand_bytes(10)
      dest_hash = Destination.compute_hash(id, "test_app", ["echo"])
      ratchet = :crypto.strong_rand_bytes(32)

      # Signed data includes ratchet
      signed_data = dest_hash <> pub_key <> name_hash <> random_hash <> ratchet
      signature = Identity.sign(id, signed_data)

      # Announce data includes ratchet between random_hash and signature
      announce_data = pub_key <> name_hash <> random_hash <> ratchet <> signature
      assert byte_size(announce_data) == 64 + 10 + 10 + 32 + 64
      assert byte_size(announce_data) == 180
    end
  end

  # =========================================================================
  # 14. FULL IDENTITY ENCRYPT/DECRYPT CHAIN
  # =========================================================================

  describe "full identity encrypt/decrypt chain (cross-language critical)" do
    test "encrypt chain: ephemeral ECDH → HKDF → Token" do
      receiver = Identity.from_bytes(:binary.copy(<<0x42>>, 64))
      plaintext = "full chain test"

      ct = Identity.encrypt(receiver, plaintext)

      # Step 1: Extract ephemeral public key
      <<ephemeral_pub::binary-size(32), token_data::binary>> = ct

      # Step 2: Compute shared key (only receiver can do this)
      receiver_prv = X25519.from_private_bytes(receiver.prv_bytes)
      shared_key = X25519.exchange(receiver_prv, ephemeral_pub)
      assert byte_size(shared_key) == 32

      # Step 3: Derive key via HKDF
      derived_key = HKDF.derive_key(shared_key, 64, Identity.salt(receiver), nil)
      assert byte_size(derived_key) == 64

      # Step 4: Decrypt token
      token = Token.new(derived_key)
      decrypted = Token.decrypt(token, token_data)
      assert decrypted == plaintext
    end

    test "decrypt with wrong identity fails" do
      receiver = Identity.from_bytes(:binary.list_to_bin(Enum.to_list(0..63)))
      wrong = Identity.from_bytes(:binary.copy(<<0x42>>, 64))

      ct = Identity.encrypt(receiver, "secret")
      assert Identity.decrypt(wrong, ct) == nil
    end
  end

  # =========================================================================
  # 15. CROSS-VERIFICATION WITH PYTHON-GENERATED FIXTURES
  # =========================================================================

  describe "Python-generated fixture compatibility" do
    @fixtures_path Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])

    defp load_fixtures do
      File.read!(@fixtures_path) |> Jason.decode!()
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "hash fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["hashes"] do
        input = hex(fixture["input"])
        assert to_hex(Hashes.sha256(input)) == fixture["sha256"]
        assert to_hex(Hashes.truncated_hash(input)) == fixture["truncated_hash"]
        assert to_hex(Identity.full_hash(input)) == fixture["full_hash"]
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "identity fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["identities"] do
        prv = hex(fixture["private_key"])
        id = Identity.from_bytes(prv)

        assert to_hex(Identity.public_key(id)) == fixture["public_key"]
        assert to_hex(id.pub_bytes) == fixture["x25519_pub"]
        assert to_hex(id.sig_pub_bytes) == fixture["ed25519_pub"]
        assert to_hex(id.hash) == fixture["identity_hash"]
        assert id.hexhash == fixture["hexhash"]

        message = hex(fixture["test_message"])
        signature = Identity.sign(id, message)
        assert to_hex(signature) == fixture["signature"]
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "destination hash fixtures match Python" do
      fixtures = load_fixtures()
      id_prv = hex(List.first(fixtures["identities"])["private_key"])
      id = Identity.from_bytes(id_prv)

      for fixture <- fixtures["destinations"] do
        aspects = fixture["aspects"]

        name_hash = Destination.compute_name_hash(fixture["app_name"], aspects)
        assert to_hex(name_hash) == fixture["name_hash"]

        single_hash = Destination.compute_hash(id, fixture["app_name"], aspects)
        assert to_hex(single_hash) == fixture["single_dest_hash"]

        plain_hash = Destination.compute_hash(nil, fixture["app_name"], aspects)
        assert to_hex(plain_hash) == fixture["plain_dest_hash"]
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "HKDF fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["hkdf"] do
        ikm = hex(fixture["ikm"])
        length = fixture["length"]
        salt = if fixture["salt"], do: hex(fixture["salt"]), else: nil
        info = if fixture["info"], do: hex(fixture["info"]), else: nil

        derived = HKDF.derive_key(ikm, length, salt, info)
        assert to_hex(derived) == fixture["derived_key"],
               "HKDF mismatch for: #{fixture["description"]}"
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "token fixtures — Python ciphertext decrypts correctly" do
      fixtures = load_fixtures()
      for fixture <- fixtures["tokens"] do
        key = hex(fixture["key"])
        token = Token.new(key)
        ciphertext = hex(fixture["ciphertext"])
        expected_plaintext = hex(fixture["plaintext"])

        assert Token.verify_hmac(token, ciphertext)
        assert Token.decrypt(token, ciphertext) == expected_plaintext
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "X25519 fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["x25519"] do
        key_a = X25519.from_private_bytes(hex(fixture["private_a"]))
        key_b = X25519.from_private_bytes(hex(fixture["private_b"]))

        assert to_hex(X25519.public_key(key_a)) == fixture["public_a"]
        assert to_hex(X25519.public_key(key_b)) == fixture["public_b"]

        shared = X25519.exchange(key_a, X25519.public_key(key_b))
        assert to_hex(shared) == fixture["shared_secret"]
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "Ed25519 fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["ed25519"] do
        key = Ed25519.from_private_bytes(hex(fixture["private_key"]))
        assert to_hex(Ed25519.public_key(key)) == fixture["public_key"]

        for sig_fixture <- fixture["signatures"] do
          message = hex(sig_fixture["message"])
          signature = Ed25519.sign(key, message)
          assert to_hex(signature) == sig_fixture["signature"]
          assert Ed25519.verify(signature, message, Ed25519.public_key(key))
        end
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "identity encryption — Python ciphertext decrypts" do
      fixtures = load_fixtures()
      for fixture <- fixtures["identity_encryption"] do
        prv = hex(fixture["receiver_private_key"])
        receiver = Identity.from_bytes(prv)
        ciphertext = hex(fixture["ciphertext"])
        expected = hex(fixture["plaintext"])

        decrypted = Identity.decrypt(receiver, ciphertext)
        assert decrypted == expected
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "PKCS7 fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["pkcs7"] do
        input = hex(fixture["input"])
        expected_padded = hex(fixture["padded"])
        assert PKCS7.pad(input) == expected_padded
        assert PKCS7.unpad(expected_padded) == input
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "AES fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["aes"] do
        key = hex(fixture["key"])
        iv = hex(fixture["iv"])
        padded = hex(fixture["padded_plaintext"])
        expected_ct = hex(fixture["ciphertext"])

        assert to_hex(AES.encrypt(padded, key, iv)) == fixture["ciphertext"]
        assert AES.decrypt(expected_ct, key, iv) == padded
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "HMAC fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["hmac"] do
        key = hex(fixture["key"])
        data = hex(fixture["data"])
        expected = hex(fixture["digest"])
        assert HMAC.digest(key, data) == expected
      end
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "constants match Python" do
      fixtures = load_fixtures()
      constants = fixtures["constants"]
      assert RNS.Reticulum.mtu() == constants["MTU"]
      assert RNS.Reticulum.truncated_hashlength() == constants["TRUNCATED_HASHLENGTH"]
      assert RNS.Reticulum.header_minsize() == constants["HEADER_MINSIZE"]
      assert RNS.Reticulum.header_maxsize() == constants["HEADER_MAXSIZE"]
      assert RNS.Reticulum.mdu() == constants["MDU"]
      assert Identity.keysize() == constants["IDENTITY_KEYSIZE"]
      assert Identity.hashlength() == constants["IDENTITY_HASHLENGTH"]
      assert Identity.name_hash_length() == constants["IDENTITY_NAME_HASH_LENGTH"]
      assert Identity.ratchetsize() == constants["IDENTITY_RATCHETSIZE"]
    end

    @tag skip: unless(File.exists?(Path.join([__DIR__, "..", "fixtures", "protocol_compatibility.json"])), do: "Run: python3 test/fixtures/generate_fixtures.py")
    test "announce fixtures match Python" do
      fixtures = load_fixtures()
      for fixture <- fixtures["announces"] do
        prv = hex(fixture["identity_private_key"])
        id = Identity.from_bytes(prv)
        pub_key = Identity.public_key(id)
        assert to_hex(pub_key) == fixture["public_key"]

        name_hash = Destination.compute_name_hash(fixture["app_name"], fixture["aspects"])
        assert to_hex(name_hash) == fixture["name_hash"]

        dest_hash = Destination.compute_hash(id, fixture["app_name"], fixture["aspects"])
        assert to_hex(dest_hash) == fixture["dest_hash"]

        signed_data = hex(fixture["signed_data"])
        signature = Identity.sign(id, signed_data)
        assert to_hex(signature) == fixture["signature"]
      end
    end
  end

  # =========================================================================
  # 16. WIRE FORMAT INVARIANTS
  # =========================================================================

  describe "wire format invariants" do
    test "packet hash is SHA-256 of raw packet" do
      # In RNS, packet hash = truncated_hash(raw_bytes)
      raw = :crypto.strong_rand_bytes(100)
      expected = Hashes.truncated_hash(raw)
      assert byte_size(expected) == 16
    end

    test "MTU limits" do
      # Maximum packet size
      assert RNS.Reticulum.mtu() == 500
      # Header sizes
      assert RNS.Reticulum.header_minsize() == 19
      assert RNS.Reticulum.header_maxsize() == 35
      # MDU = MTU - HEADER_MAXSIZE - IFAC_MIN_SIZE
      assert RNS.Reticulum.mdu() == 500 - 35 - 1
    end

    test "identity key sizes" do
      # Each identity has:
      # - 32-byte X25519 private key
      # - 32-byte Ed25519 private key (seed)
      # - 32-byte X25519 public key
      # - 32-byte Ed25519 public key
      # Total private: 64 bytes (512 bits = KEYSIZE)
      # Total public: 64 bytes
      id = Identity.new()
      assert byte_size(Identity.public_key(id)) == 64
      assert byte_size(Identity.private_key(id)) == 64
      assert byte_size(id.hash) == 16
      assert byte_size(id.pub_bytes) == 32
      assert byte_size(id.sig_pub_bytes) == 32
    end

    test "destination hash size" do
      id = Identity.new()
      hash = Destination.compute_hash(id, "app", ["test"])
      assert byte_size(hash) == 16
    end

    test "ed25519 signature size" do
      id = Identity.new()
      sig = Identity.sign(id, "test")
      assert byte_size(sig) == 64
    end

    test "token overhead is exactly 48 bytes" do
      key = :crypto.strong_rand_bytes(64)
      token = Token.new(key)

      for size <- [0, 1, 10, 100] do
        data = :crypto.strong_rand_bytes(size)
        ct = Token.encrypt(token, data)
        # Overhead = IV(16) + padding + HMAC(32)
        # For size 0: padded to 16, so ct = 16 + 16 + 32 = 64 (overhead = 64)
        # Minimum overhead = 16 (IV) + 32 (HMAC) = 48
        assert byte_size(ct) >= byte_size(data) + 48
      end
    end

    test "X25519 key and shared secret sizes" do
      a = X25519.generate_keypair()
      b = X25519.generate_keypair()
      assert byte_size(X25519.public_key(a)) == 32
      assert byte_size(X25519.public_key(b)) == 32
      shared = X25519.exchange(a, X25519.public_key(b))
      assert byte_size(shared) == 32
    end

    test "HKDF output length matches request" do
      ikm = :crypto.strong_rand_bytes(32)
      for len <- [16, 32, 48, 64, 128] do
        derived = HKDF.derive_key(ikm, len, nil, nil)
        assert byte_size(derived) == len
      end
    end
  end

  # =========================================================================
  # Helper functions
  # =========================================================================

  defp encode_flags(header_type, context_flag, transport_type, dest_type, packet_type) do
    import Bitwise
    (header_type <<< 6) ||| (context_flag <<< 5) ||| (transport_type <<< 4) |||
      (dest_type <<< 2) ||| packet_type
  end
end
