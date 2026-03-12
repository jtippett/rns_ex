defmodule RNS.Cryptography.Ed25519Test do
  use ExUnit.Case, async: true

  alias RNS.Cryptography.Ed25519

  @key_length 32
  @sig_length 64

  # Known test seeds for reproducible tests
  @test_seed_1 Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @test_seed_2 Base.decode16!("4CCD089B28FF96DA9DB6C346EC114E0F5B8A319F35ABA624DA8CF6ED4FB8A6FB")
  @test_seed_3 Base.decode16!("C5AA8DF43F9F837BEDB7442F31DCB7B166D38535076F094B85CE3A2E0B4458F7")

  # Helper: compute reference public key using Erlang :crypto (OpenSSL)
  defp crypto_pubkey(seed) do
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519, seed)
    pub
  end

  # Helper: compute reference signature using Erlang :crypto
  defp crypto_sign(seed, message) do
    :crypto.sign(:eddsa, :none, message, [seed, :ed25519])
  end

  # Helper: verify using Erlang :crypto
  defp crypto_verify(signature, message, pub) do
    :crypto.verify(:eddsa, :none, message, signature, [pub, :ed25519])
  end

  describe "generate_keypair/0" do
    test "generates a keypair with 32-byte keys" do
      keypair = Ed25519.generate_keypair()
      assert byte_size(Ed25519.private_bytes(keypair)) == @key_length
      assert byte_size(Ed25519.public_key(keypair)) == @key_length
    end

    test "generates unique keypairs each time" do
      kp1 = Ed25519.generate_keypair()
      kp2 = Ed25519.generate_keypair()
      assert Ed25519.private_bytes(kp1) != Ed25519.private_bytes(kp2)
      assert Ed25519.public_key(kp1) != Ed25519.public_key(kp2)
    end
  end

  describe "from_private_bytes/1" do
    test "derives public key matching Erlang :crypto for test seed 1" do
      keypair = Ed25519.from_private_bytes(@test_seed_1)
      assert Ed25519.public_key(keypair) == crypto_pubkey(@test_seed_1)
    end

    test "derives public key matching Erlang :crypto for test seed 2" do
      keypair = Ed25519.from_private_bytes(@test_seed_2)
      assert Ed25519.public_key(keypair) == crypto_pubkey(@test_seed_2)
    end

    test "derives public key matching Erlang :crypto for test seed 3" do
      keypair = Ed25519.from_private_bytes(@test_seed_3)
      assert Ed25519.public_key(keypair) == crypto_pubkey(@test_seed_3)
    end

    test "raises on invalid key length" do
      assert_raise ArgumentError, fn ->
        Ed25519.from_private_bytes(<<0::8*16>>)
      end

      assert_raise ArgumentError, fn ->
        Ed25519.from_private_bytes(<<0::8*64>>)
      end
    end
  end

  describe "from_public_bytes/1" do
    test "creates a public-key-only struct from raw bytes" do
      pub_bytes = crypto_pubkey(@test_seed_1)
      keypair = Ed25519.from_public_bytes(pub_bytes)
      assert Ed25519.public_key(keypair) == pub_bytes
    end

    test "raises on invalid public key length" do
      assert_raise ArgumentError, fn ->
        Ed25519.from_public_bytes(<<0::8*16>>)
      end
    end
  end

  describe "private_bytes/1" do
    test "returns the original seed" do
      seed = :crypto.strong_rand_bytes(32)
      keypair = Ed25519.from_private_bytes(seed)
      assert Ed25519.private_bytes(keypair) == seed
    end
  end

  describe "public_key/1" do
    test "returns 32-byte public key" do
      keypair = Ed25519.generate_keypair()
      pub = Ed25519.public_key(keypair)
      assert is_binary(pub)
      assert byte_size(pub) == @key_length
    end

    test "deterministic — same seed produces same public key" do
      seed = :crypto.strong_rand_bytes(32)
      kp1 = Ed25519.from_private_bytes(seed)
      kp2 = Ed25519.from_private_bytes(seed)
      assert Ed25519.public_key(kp1) == Ed25519.public_key(kp2)
    end
  end

  describe "sign/2" do
    test "signature matches Erlang :crypto for test seed 1 and empty message" do
      keypair = Ed25519.from_private_bytes(@test_seed_1)
      sig = Ed25519.sign(keypair, <<>>)
      assert byte_size(sig) == @sig_length
      assert sig == crypto_sign(@test_seed_1, <<>>)
    end

    test "signature matches Erlang :crypto for test seed 2 and single byte" do
      keypair = Ed25519.from_private_bytes(@test_seed_2)
      sig = Ed25519.sign(keypair, <<0x72>>)
      assert byte_size(sig) == @sig_length
      assert sig == crypto_sign(@test_seed_2, <<0x72>>)
    end

    test "signature matches Erlang :crypto for test seed 3 and two bytes" do
      keypair = Ed25519.from_private_bytes(@test_seed_3)
      sig = Ed25519.sign(keypair, <<0xAF, 0x82>>)
      assert byte_size(sig) == @sig_length
      assert sig == crypto_sign(@test_seed_3, <<0xAF, 0x82>>)
    end

    test "produces 64-byte signature" do
      keypair = Ed25519.generate_keypair()
      sig = Ed25519.sign(keypair, "hello world")
      assert byte_size(sig) == @sig_length
    end

    test "different messages produce different signatures" do
      keypair = Ed25519.generate_keypair()
      sig1 = Ed25519.sign(keypair, "message one")
      sig2 = Ed25519.sign(keypair, "message two")
      assert sig1 != sig2
    end

    test "same message with different keys produces different signatures" do
      kp1 = Ed25519.generate_keypair()
      kp2 = Ed25519.generate_keypair()
      msg = "same message"
      sig1 = Ed25519.sign(kp1, msg)
      sig2 = Ed25519.sign(kp2, msg)
      assert sig1 != sig2
    end

    test "signing is deterministic — same key+message gives same signature" do
      seed = :crypto.strong_rand_bytes(32)
      keypair = Ed25519.from_private_bytes(seed)
      msg = "deterministic test"
      sig1 = Ed25519.sign(keypair, msg)
      sig2 = Ed25519.sign(keypair, msg)
      assert sig1 == sig2
    end
  end

  describe "verify/3" do
    test "verifies a valid signature" do
      keypair = Ed25519.generate_keypair()
      msg = "test message"
      sig = Ed25519.sign(keypair, msg)
      assert Ed25519.verify(sig, msg, Ed25519.public_key(keypair)) == true
    end

    test "rejects signature with wrong message" do
      keypair = Ed25519.generate_keypair()
      sig = Ed25519.sign(keypair, "correct message")
      assert Ed25519.verify(sig, "wrong message", Ed25519.public_key(keypair)) == false
    end

    test "rejects signature with wrong public key" do
      kp1 = Ed25519.generate_keypair()
      kp2 = Ed25519.generate_keypair()
      msg = "test message"
      sig = Ed25519.sign(kp1, msg)
      assert Ed25519.verify(sig, msg, Ed25519.public_key(kp2)) == false
    end

    test "rejects tampered signature" do
      keypair = Ed25519.generate_keypair()
      msg = "test message"
      sig = Ed25519.sign(keypair, msg)

      # Flip a bit in the signature
      <<first_byte, rest::binary>> = sig
      tampered = <<Bitwise.bxor(first_byte, 1), rest::binary>>
      assert Ed25519.verify(tampered, msg, Ed25519.public_key(keypair)) == false
    end

    test "verifies signature created by Erlang :crypto" do
      seed = :crypto.strong_rand_bytes(32)
      msg = "cross-validation test"
      crypto_sig = crypto_sign(seed, msg)
      pub = crypto_pubkey(seed)
      assert Ed25519.verify(crypto_sig, msg, pub) == true
    end

    test "Erlang :crypto verifies signature created by Ed25519 module" do
      seed = :crypto.strong_rand_bytes(32)
      keypair = Ed25519.from_private_bytes(seed)
      msg = "cross-validation test"
      sig = Ed25519.sign(keypair, msg)
      pub = Ed25519.public_key(keypair)
      assert crypto_verify(sig, msg, pub) == true
    end

    test "accepts public key as raw bytes" do
      keypair = Ed25519.generate_keypair()
      msg = "raw bytes test"
      sig = Ed25519.sign(keypair, msg)
      pub_bytes = Ed25519.public_key(keypair)
      assert Ed25519.verify(sig, msg, pub_bytes) == true
    end
  end

  describe "sign/verify roundtrip" do
    test "roundtrip with empty message" do
      keypair = Ed25519.generate_keypair()
      sig = Ed25519.sign(keypair, <<>>)
      assert Ed25519.verify(sig, <<>>, Ed25519.public_key(keypair)) == true
    end

    test "roundtrip with large message" do
      keypair = Ed25519.generate_keypair()
      msg = :crypto.strong_rand_bytes(10_000)
      sig = Ed25519.sign(keypair, msg)
      assert Ed25519.verify(sig, msg, Ed25519.public_key(keypair)) == true
    end
  end

  describe "key serialization roundtrip" do
    test "private key roundtrip through bytes" do
      kp1 = Ed25519.generate_keypair()
      seed = Ed25519.private_bytes(kp1)
      kp2 = Ed25519.from_private_bytes(seed)

      assert Ed25519.private_bytes(kp2) == seed
      assert Ed25519.public_key(kp2) == Ed25519.public_key(kp1)

      # Verify signing still works after roundtrip
      msg = "roundtrip test"
      sig = Ed25519.sign(kp2, msg)
      assert Ed25519.verify(sig, msg, Ed25519.public_key(kp1)) == true
    end

    test "public key roundtrip through bytes" do
      keypair = Ed25519.generate_keypair()
      pub_bytes = Ed25519.public_key(keypair)
      pub_only = Ed25519.from_public_bytes(pub_bytes)

      assert Ed25519.public_key(pub_only) == pub_bytes
    end
  end

  if Code.ensure_loaded?(StreamData) do
    use ExUnitProperties

    describe "property-based tests" do
      property "sign/verify roundtrip for arbitrary messages" do
        seed = :crypto.strong_rand_bytes(32)
        keypair = Ed25519.from_private_bytes(seed)

        check all message <- StreamData.binary(min_length: 0, max_length: 1000) do
          sig = Ed25519.sign(keypair, message)
          assert byte_size(sig) == @sig_length
          assert Ed25519.verify(sig, message, Ed25519.public_key(keypair)) == true
        end
      end

      property "cross-validates with Erlang :crypto for arbitrary seeds and messages" do
        check all seed <- StreamData.binary(length: 32),
                  message <- StreamData.binary(min_length: 0, max_length: 200) do
          keypair = Ed25519.from_private_bytes(seed)

          # Public key matches
          assert Ed25519.public_key(keypair) == crypto_pubkey(seed)

          # Signature matches
          sig = Ed25519.sign(keypair, message)
          assert sig == crypto_sign(seed, message)
        end
      end
    end
  end
end
