defmodule RNS.Cryptography.TokenTest do
  use ExUnit.Case, async: true

  alias RNS.Cryptography.Token

  describe "constants" do
    test "TOKEN_OVERHEAD is 48 bytes" do
      assert Token.token_overhead() == 48
    end
  end

  describe "generate_key/0" do
    test "generates a 64-byte key (AES-256-CBC default)" do
      key = Token.generate_key()
      assert byte_size(key) == 64
    end

    test "generates unique keys each time" do
      key1 = Token.generate_key()
      key2 = Token.generate_key()
      assert key1 != key2
    end
  end

  describe "new/1" do
    test "creates token with 64-byte key (AES-256-CBC)" do
      key = :crypto.strong_rand_bytes(64)
      token = Token.new(key)
      assert %Token{} = token
    end

    test "creates token with 32-byte key (AES-128-CBC)" do
      key = :crypto.strong_rand_bytes(32)
      token = Token.new(key)
      assert %Token{} = token
    end

    test "raises on invalid key length" do
      assert_raise ArgumentError, fn ->
        Token.new(:crypto.strong_rand_bytes(48))
      end
    end

    test "raises on nil key" do
      assert_raise ArgumentError, fn ->
        Token.new(nil)
      end
    end
  end

  describe "encrypt/2 and decrypt/2 roundtrip" do
    test "roundtrip with AES-256-CBC (64-byte key)" do
      key = Token.generate_key()
      token = Token.new(key)
      plaintext = "Hello, Reticulum!"

      ciphertext = Token.encrypt(token, plaintext)
      assert Token.decrypt(token, ciphertext) == plaintext
    end

    test "roundtrip with AES-128-CBC (32-byte key)" do
      key = :crypto.strong_rand_bytes(32)
      token = Token.new(key)
      plaintext = "Hello, Reticulum!"

      ciphertext = Token.encrypt(token, plaintext)
      assert Token.decrypt(token, ciphertext) == plaintext
    end

    test "roundtrip with empty data" do
      key = Token.generate_key()
      token = Token.new(key)
      plaintext = ""

      ciphertext = Token.encrypt(token, plaintext)
      assert Token.decrypt(token, ciphertext) == plaintext
    end

    test "roundtrip with large data" do
      key = Token.generate_key()
      token = Token.new(key)
      plaintext = :crypto.strong_rand_bytes(10_000)

      ciphertext = Token.encrypt(token, plaintext)
      assert Token.decrypt(token, ciphertext) == plaintext
    end

    test "roundtrip with binary data" do
      key = Token.generate_key()
      token = Token.new(key)
      plaintext = <<0, 1, 2, 3, 255, 254, 253, 0, 0, 0>>

      ciphertext = Token.encrypt(token, plaintext)
      assert Token.decrypt(token, ciphertext) == plaintext
    end

    test "roundtrip with block-aligned data (16 bytes)" do
      key = Token.generate_key()
      token = Token.new(key)
      plaintext = :crypto.strong_rand_bytes(16)

      ciphertext = Token.encrypt(token, plaintext)
      assert Token.decrypt(token, ciphertext) == plaintext
    end

    test "roundtrip with block-aligned data (32 bytes)" do
      key = Token.generate_key()
      token = Token.new(key)
      plaintext = :crypto.strong_rand_bytes(32)

      ciphertext = Token.encrypt(token, plaintext)
      assert Token.decrypt(token, ciphertext) == plaintext
    end
  end

  describe "token overhead" do
    test "ciphertext is plaintext padded to block + 48 bytes overhead" do
      key = Token.generate_key()
      token = Token.new(key)

      # For 10 bytes of plaintext: PKCS7 pads to 16 bytes, + 16 IV + 32 HMAC = 64
      plaintext = :crypto.strong_rand_bytes(10)
      ciphertext = Token.encrypt(token, plaintext)
      # padded_len = 16 (10 bytes padded to 16), overhead = 48
      assert byte_size(ciphertext) == 16 + 48

      # For 16 bytes: PKCS7 adds full block → 32, + overhead = 80
      plaintext = :crypto.strong_rand_bytes(16)
      ciphertext = Token.encrypt(token, plaintext)
      assert byte_size(ciphertext) == 32 + 48

      # For 1 byte: pads to 16, + overhead = 64
      plaintext = <<42>>
      ciphertext = Token.encrypt(token, plaintext)
      assert byte_size(ciphertext) == 16 + 48
    end
  end

  describe "verify_hmac/2" do
    test "returns true for valid token" do
      key = Token.generate_key()
      token = Token.new(key)
      ciphertext = Token.encrypt(token, "test data")

      assert Token.verify_hmac(token, ciphertext) == true
    end

    test "returns false for tampered ciphertext" do
      key = Token.generate_key()
      token = Token.new(key)
      ciphertext = Token.encrypt(token, "test data")

      # Flip a bit in the IV/ciphertext portion (before HMAC)
      <<first_byte, rest::binary>> = ciphertext
      tampered = <<Bitwise.bxor(first_byte, 0x01), rest::binary>>

      assert Token.verify_hmac(token, tampered) == false
    end

    test "returns false for tampered HMAC" do
      key = Token.generate_key()
      token = Token.new(key)
      ciphertext = Token.encrypt(token, "test data")

      # Flip a bit in the last byte (HMAC portion)
      size = byte_size(ciphertext)
      <<prefix::binary-size(size - 1), last_byte>> = ciphertext
      tampered = <<prefix::binary, Bitwise.bxor(last_byte, 0x01)>>

      assert Token.verify_hmac(token, tampered) == false
    end

    test "raises on token too short for HMAC verification" do
      key = Token.generate_key()
      token = Token.new(key)

      assert_raise ArgumentError, fn ->
        Token.verify_hmac(token, :crypto.strong_rand_bytes(32))
      end
    end
  end

  describe "tampering detection in decrypt" do
    test "decrypt raises on tampered ciphertext" do
      key = Token.generate_key()
      token = Token.new(key)
      ciphertext = Token.encrypt(token, "secret message")

      <<first_byte, rest::binary>> = ciphertext
      tampered = <<Bitwise.bxor(first_byte, 0x01), rest::binary>>

      assert_raise ArgumentError, fn ->
        Token.decrypt(token, tampered)
      end
    end

    test "decrypt raises on wrong key" do
      key1 = Token.generate_key()
      key2 = Token.generate_key()
      token1 = Token.new(key1)
      token2 = Token.new(key2)

      ciphertext = Token.encrypt(token1, "secret message")

      assert_raise ArgumentError, fn ->
        Token.decrypt(token2, ciphertext)
      end
    end

    test "decrypt raises on truncated token" do
      key = Token.generate_key()
      token = Token.new(key)
      ciphertext = Token.encrypt(token, "secret message")

      truncated = binary_part(ciphertext, 0, byte_size(ciphertext) - 1)

      assert_raise ArgumentError, fn ->
        Token.decrypt(token, truncated)
      end
    end
  end

  describe "encryption produces different output each time" do
    test "same plaintext encrypts to different ciphertext (random IV)" do
      key = Token.generate_key()
      token = Token.new(key)
      plaintext = "identical data"

      c1 = Token.encrypt(token, plaintext)
      c2 = Token.encrypt(token, plaintext)

      assert c1 != c2
      # But both decrypt to the same plaintext
      assert Token.decrypt(token, c1) == plaintext
      assert Token.decrypt(token, c2) == plaintext
    end
  end

  if Code.ensure_loaded?(StreamData) do
    use ExUnitProperties

    describe "property-based tests" do
      property "encrypt/decrypt roundtrip for arbitrary data (AES-256)" do
        key = Token.generate_key()
        token = Token.new(key)

        check all data <- StreamData.binary() do
          ciphertext = Token.encrypt(token, data)
          assert Token.decrypt(token, ciphertext) == data
        end
      end

      property "ciphertext size is always padded_plaintext + 48" do
        key = Token.generate_key()
        token = Token.new(key)

        check all data <- StreamData.binary() do
          ciphertext = Token.encrypt(token, data)
          padded_len = div(byte_size(data), 16) * 16 + 16
          assert byte_size(ciphertext) == padded_len + 48
        end
      end
    end
  end
end
