defmodule RNS.Cryptography.X25519Test do
  use ExUnit.Case, async: true

  alias RNS.Cryptography.X25519

  # RFC 7748 Section 6.1 test vectors
  @alice_private Base.decode16!("77076D0A7318A57D3C16C17251B26645DF4C2F87EBC0992AB177FBA51DB92C2A", case: :upper)
  @alice_public Base.decode16!("8520F0098930A754748B7DDCB43EF75A0DBF3A0D26381AF4EBA4A98EAA9B4E6A", case: :upper)
  @bob_private Base.decode16!("5DAB087E624A8A4B79E17F8B83800EE66F3BB1292618B6FD1C2F8B27FF88E0EB", case: :upper)
  @bob_public Base.decode16!("DE9EDB7D7B7DC1B4D35B61C2ECE435373F8343C85B78674DADFC7E146F882B4F", case: :upper)
  @shared_secret Base.decode16!("4A5D9D5BA4CE2DE1728E3BF480350F25E07E21C947D19E3376F09B3C1E161742", case: :upper)

  describe "generate_keypair/0" do
    test "returns a keypair struct with private and public keys" do
      keypair = X25519.generate_keypair()
      assert is_struct(keypair)
      assert byte_size(X25519.private_bytes(keypair)) == 32
      assert byte_size(X25519.public_key(keypair)) == 32
    end

    test "generates different keypairs each time" do
      kp1 = X25519.generate_keypair()
      kp2 = X25519.generate_keypair()
      assert X25519.private_bytes(kp1) != X25519.private_bytes(kp2)
      assert X25519.public_key(kp1) != X25519.public_key(kp2)
    end
  end

  describe "from_private_bytes/1" do
    test "creates keypair from raw private key bytes" do
      keypair = X25519.from_private_bytes(@alice_private)
      assert byte_size(X25519.private_bytes(keypair)) == 32
      assert byte_size(X25519.public_key(keypair)) == 32
    end

    test "derives correct public key for Alice (RFC 7748)" do
      keypair = X25519.from_private_bytes(@alice_private)
      assert X25519.public_key(keypair) == @alice_public
    end

    test "derives correct public key for Bob (RFC 7748)" do
      keypair = X25519.from_private_bytes(@bob_private)
      assert X25519.public_key(keypair) == @bob_public
    end

    test "rejects invalid key length" do
      assert_raise ArgumentError, fn ->
        X25519.from_private_bytes(<<0::8*16>>)
      end

      assert_raise ArgumentError, fn ->
        X25519.from_private_bytes(<<0::8*64>>)
      end
    end
  end

  describe "private_bytes/1" do
    test "returns 32-byte binary" do
      keypair = X25519.generate_keypair()
      priv = X25519.private_bytes(keypair)
      assert is_binary(priv)
      assert byte_size(priv) == 32
    end

    test "roundtrips through from_private_bytes" do
      keypair = X25519.generate_keypair()
      priv = X25519.private_bytes(keypair)
      reconstructed = X25519.from_private_bytes(priv)
      assert X25519.public_key(reconstructed) == X25519.public_key(keypair)
    end
  end

  describe "public_key/1" do
    test "returns 32-byte binary" do
      keypair = X25519.generate_keypair()
      pub = X25519.public_key(keypair)
      assert is_binary(pub)
      assert byte_size(pub) == 32
    end

    test "is deterministic for same private key" do
      keypair1 = X25519.from_private_bytes(@alice_private)
      keypair2 = X25519.from_private_bytes(@alice_private)
      assert X25519.public_key(keypair1) == X25519.public_key(keypair2)
    end
  end

  describe "exchange/2" do
    test "Alice and Bob derive the same shared secret (RFC 7748)" do
      alice = X25519.from_private_bytes(@alice_private)
      bob = X25519.from_private_bytes(@bob_private)

      alice_shared = X25519.exchange(alice, X25519.public_key(bob))
      bob_shared = X25519.exchange(bob, X25519.public_key(alice))

      assert alice_shared == bob_shared
      assert alice_shared == @shared_secret
    end

    test "two generated keypairs produce same shared secret" do
      alice = X25519.generate_keypair()
      bob = X25519.generate_keypair()

      alice_shared = X25519.exchange(alice, X25519.public_key(bob))
      bob_shared = X25519.exchange(bob, X25519.public_key(alice))

      assert alice_shared == bob_shared
    end

    test "shared secret is 32 bytes" do
      alice = X25519.generate_keypair()
      bob = X25519.generate_keypair()

      shared = X25519.exchange(alice, X25519.public_key(bob))
      assert byte_size(shared) == 32
    end

    test "different peer produces different shared secret" do
      alice = X25519.generate_keypair()
      bob = X25519.generate_keypair()
      charlie = X25519.generate_keypair()

      shared_ab = X25519.exchange(alice, X25519.public_key(bob))
      shared_ac = X25519.exchange(alice, X25519.public_key(charlie))

      assert shared_ab != shared_ac
    end

    test "rejects invalid peer public key length" do
      alice = X25519.generate_keypair()

      assert_raise ArgumentError, fn ->
        X25519.exchange(alice, <<0::8*16>>)
      end
    end
  end

  describe "RFC 7748 Section 5.2 test vectors" do
    # Single iteration: scalar multiply base point 9 by given scalar
    test "scalar multiplication test vector 1" do
      # Input scalar (private key)
      scalar = Base.decode16!("A546E36BF0527C9D3B16154B82465EDD62144C0AC1FC5A18506A2244BA449AC4", case: :upper)
      # Input u-coordinate
      u_coord = Base.decode16!("E6DB6867583030DB3594C1A424B15F7C726624EC26B3353B10A903A6D0AB1C4C", case: :upper)
      # Expected output
      expected = Base.decode16!("C3DA55379DE9C6908E94EA4DF28D084F32ECCF03491C71F754B4075577A28552", case: :upper)

      # This tests the raw scalar mult: exchange with a specific u-coordinate as "public key"
      keypair = X25519.from_private_bytes(scalar)
      result = X25519.exchange(keypair, u_coord)
      assert result == expected
    end

    test "scalar multiplication test vector 2" do
      scalar = Base.decode16!("4B66E9D4D1B4673C5AD22691957D6AF5C11B6421E0EA01D42CA4169E7918BA0D", case: :upper)
      u_coord = Base.decode16!("E5210F12786811D3F4B7959D0538AE2C31DBE7106FC03C3EFC4CD549C715A493", case: :upper)
      expected = Base.decode16!("95CBDE9476E8907D7AADE45CB4B873F88B595A68799FA152E6F8F7647AAC7957", case: :upper)

      keypair = X25519.from_private_bytes(scalar)
      result = X25519.exchange(keypair, u_coord)
      assert result == expected
    end
  end

  if Code.ensure_loaded?(StreamData) do
    describe "property-based tests" do
      use ExUnitProperties

      property "ECDH exchange always produces same shared secret for both parties" do
        check all(
                _seed1 <- StreamData.binary(length: 32),
                _seed2 <- StreamData.binary(length: 32)
              ) do
          alice = X25519.generate_keypair()
          bob = X25519.generate_keypair()

          alice_shared = X25519.exchange(alice, X25519.public_key(bob))
          bob_shared = X25519.exchange(bob, X25519.public_key(alice))

          assert alice_shared == bob_shared
          assert byte_size(alice_shared) == 32
        end
      end

      property "from_private_bytes roundtrip preserves public key" do
        check all(seed <- StreamData.binary(length: 32)) do
          original = X25519.from_private_bytes(seed)
          restored = X25519.from_private_bytes(X25519.private_bytes(original))
          assert X25519.public_key(original) == X25519.public_key(restored)
        end
      end
    end
  end
end
