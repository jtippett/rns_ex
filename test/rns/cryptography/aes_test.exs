defmodule RNS.Cryptography.AESTest do
  use ExUnit.Case, async: true

  alias RNS.Cryptography.AES

  # NIST SP 800-38A AES-256-CBC test vector
  # See: https://csrc.nist.gov/publications/detail/sp/800-38a/final
  @nist_key Base.decode16!(
              "603DEB1015CA71BE2B73AEF0857D77811F352C073B6108D72D9810A30914DFF4"
            )
  @nist_iv Base.decode16!("000102030405060708090A0B0C0D0E0F")

  # NIST AES-256-CBC plaintext blocks (4 blocks = 64 bytes)
  @nist_plaintext Base.decode16!(
                    "6BC1BEE22E409F96E93D7E117393172A" <>
                      "AE2D8A571E03AC9C9EB76FAC45AF8E51" <>
                      "30C81C46A35CE411E5FBC1191A0A52EF" <>
                      "F69F2445DF4F9B17AD2B417BE66C3710"
                  )

  # NIST AES-256-CBC expected ciphertext
  @nist_ciphertext Base.decode16!(
                     "F58C4C04D6E5F1BA779EABFB5F7BFBD6" <>
                       "9CFC4E967EDB808D679F777BC6702C7D" <>
                       "39F23369A9D9BACFA530E26304231461" <>
                       "B2EB05E2C39BE9FCDA6C19078C6A9D1B"
                   )

  describe "encrypt/3" do
    test "encrypts with NIST AES-256-CBC test vector" do
      ciphertext = AES.encrypt(@nist_plaintext, @nist_key, @nist_iv)
      assert ciphertext == @nist_ciphertext
    end

    test "produces different ciphertext with different IVs" do
      iv1 = :crypto.strong_rand_bytes(16)
      iv2 = :crypto.strong_rand_bytes(16)
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Hello, Reticulum Network Stack!"
      padded = RNS.Cryptography.PKCS7.pad(plaintext)

      c1 = AES.encrypt(padded, key, iv1)
      c2 = AES.encrypt(padded, key, iv2)

      assert c1 != c2
    end

    test "raises on invalid key length" do
      iv = :crypto.strong_rand_bytes(16)
      plaintext = RNS.Cryptography.PKCS7.pad("test")

      assert_raise ArgumentError, ~r/invalid key length/i, fn ->
        AES.encrypt(plaintext, <<1, 2, 3>>, iv)
      end

      assert_raise ArgumentError, ~r/invalid key length/i, fn ->
        AES.encrypt(plaintext, :crypto.strong_rand_bytes(16), iv)
      end
    end

    test "output length equals input length (no padding added by AES itself)" do
      key = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(16)
      # Already padded to 32 bytes
      plaintext = RNS.Cryptography.PKCS7.pad(:crypto.strong_rand_bytes(20))

      ciphertext = AES.encrypt(plaintext, key, iv)
      assert byte_size(ciphertext) == byte_size(plaintext)
    end
  end

  describe "decrypt/3" do
    test "decrypts NIST AES-256-CBC test vector" do
      plaintext = AES.decrypt(@nist_ciphertext, @nist_key, @nist_iv)
      assert plaintext == @nist_plaintext
    end

    test "raises on invalid key length" do
      iv = :crypto.strong_rand_bytes(16)
      ciphertext = :crypto.strong_rand_bytes(32)

      assert_raise ArgumentError, ~r/invalid key length/i, fn ->
        AES.decrypt(ciphertext, <<1, 2, 3>>, iv)
      end
    end
  end

  describe "encrypt/decrypt roundtrip" do
    test "roundtrip with PKCS7 padding preserves data" do
      key = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(16)
      plaintext = "Hello, Reticulum!"

      padded = RNS.Cryptography.PKCS7.pad(plaintext)
      ciphertext = AES.encrypt(padded, key, iv)
      decrypted = AES.decrypt(ciphertext, key, iv)
      unpadded = RNS.Cryptography.PKCS7.unpad(decrypted)

      assert unpadded == plaintext
    end

    test "roundtrip with various data lengths" do
      key = :crypto.strong_rand_bytes(32)

      for len <- [0, 1, 15, 16, 17, 31, 32, 100, 255, 500] do
        iv = :crypto.strong_rand_bytes(16)
        data = :crypto.strong_rand_bytes(len)

        padded = RNS.Cryptography.PKCS7.pad(data)
        ciphertext = AES.encrypt(padded, key, iv)
        decrypted = AES.decrypt(ciphertext, key, iv)
        unpadded = RNS.Cryptography.PKCS7.unpad(decrypted)

        assert unpadded == data, "Roundtrip failed for length #{len}"
      end
    end

    test "wrong key produces wrong plaintext" do
      key1 = :crypto.strong_rand_bytes(32)
      key2 = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(16)
      plaintext = RNS.Cryptography.PKCS7.pad("secret message")

      ciphertext = AES.encrypt(plaintext, key1, iv)
      wrong_decrypt = AES.decrypt(ciphertext, key2, iv)

      assert wrong_decrypt != plaintext
    end
  end

  if Code.ensure_loaded?(StreamData) do
    use ExUnitProperties

    describe "property-based tests" do
      property "encrypt/decrypt roundtrip with PKCS7 for arbitrary data" do
        check all data <- StreamData.binary(min_length: 0, max_length: 512) do
          key = :crypto.strong_rand_bytes(32)
          iv = :crypto.strong_rand_bytes(16)

          padded = RNS.Cryptography.PKCS7.pad(data)
          ciphertext = AES.encrypt(padded, key, iv)
          decrypted = AES.decrypt(ciphertext, key, iv)
          unpadded = RNS.Cryptography.PKCS7.unpad(decrypted)

          assert unpadded == data
        end
      end

      property "ciphertext length equals padded plaintext length" do
        check all data <- StreamData.binary(min_length: 1, max_length: 256) do
          key = :crypto.strong_rand_bytes(32)
          iv = :crypto.strong_rand_bytes(16)

          padded = RNS.Cryptography.PKCS7.pad(data)
          ciphertext = AES.encrypt(padded, key, iv)

          assert byte_size(ciphertext) == byte_size(padded)
        end
      end
    end
  end
end
