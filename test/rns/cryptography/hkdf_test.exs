defmodule RNS.Cryptography.HKDFTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RNS.Cryptography.HKDF

  # RFC 5869 Test Vectors for HKDF-SHA256

  describe "derive_key/4 RFC 5869 test vectors" do
    test "test case 1 - basic extraction and expansion" do
      ikm = :binary.copy(<<0x0B>>, 22)
      salt = Base.decode16!("000102030405060708090A0B0C", case: :upper)
      info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9", case: :upper)
      length = 42

      expected =
        Base.decode16!(
          "3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865",
          case: :upper
        )

      assert HKDF.derive_key(ikm, length, salt, info) == expected
    end

    test "test case 2 - longer inputs and outputs" do
      ikm =
        Base.decode16!(
          "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F404142434445464748494A4B4C4D4E4F",
          case: :upper
        )

      salt =
        Base.decode16!(
          "606162636465666768696A6B6C6D6E6F707172737475767778797A7B7C7D7E7F808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9FA0A1A2A3A4A5A6A7A8A9AAABACADAEAF",
          case: :upper
        )

      info =
        Base.decode16!(
          "B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBFC0C1C2C3C4C5C6C7C8C9CACBCCCDCECFD0D1D2D3D4D5D6D7D8D9DADBDCDDDEDFE0E1E2E3E4E5E6E7E8E9EAEBECEDEEEFF0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF",
          case: :upper
        )

      length = 82

      expected =
        Base.decode16!(
          "B11E398DC80327A1C8E7F78C596A49344F012EDA2D4EFAD8A050CC4C19AFA97C59045A99CAC7827271CB41C65E590E09DA3275600C2F09B8367793A9ACA3DB71CC30C58179EC3E87C14C01D5C1F3434F1D87",
          case: :upper
        )

      assert HKDF.derive_key(ikm, length, salt, info) == expected
    end

    test "test case 3 - zero-length salt and info" do
      ikm = :binary.copy(<<0x0B>>, 22)
      salt = <<>>
      info = <<>>
      length = 42

      expected =
        Base.decode16!(
          "8DA4E775A563C18F715F802A063C5A31B8A11F5C5EE1879EC3454E5F3C738D2D9D201395FAA4B61A96C8",
          case: :upper
        )

      assert HKDF.derive_key(ikm, length, salt, info) == expected
    end
  end

  describe "derive_key/4 with nil salt and info" do
    test "nil salt defaults to zero bytes" do
      ikm = :binary.copy(<<0x0B>>, 22)
      length = 42

      # nil salt should behave the same as empty salt
      result_nil = HKDF.derive_key(ikm, length, nil, <<>>)
      result_empty = HKDF.derive_key(ikm, length, <<>>, <<>>)
      assert result_nil == result_empty
    end

    test "nil info defaults to empty bytes" do
      ikm = :binary.copy(<<0x0B>>, 22)
      length = 42

      result_nil = HKDF.derive_key(ikm, length, <<>>, nil)
      result_empty = HKDF.derive_key(ikm, length, <<>>, <<>>)
      assert result_nil == result_empty
    end
  end

  describe "derive_key/4 error handling" do
    test "raises on invalid length (0)" do
      assert_raise ArgumentError, fn ->
        HKDF.derive_key(<<1, 2, 3>>, 0, nil, nil)
      end
    end

    test "raises on negative length" do
      assert_raise ArgumentError, fn ->
        HKDF.derive_key(<<1, 2, 3>>, -1, nil, nil)
      end
    end

    test "raises on empty input key material" do
      assert_raise ArgumentError, fn ->
        HKDF.derive_key(<<>>, 32, nil, nil)
      end
    end

    test "raises on nil input key material" do
      assert_raise ArgumentError, fn ->
        HKDF.derive_key(nil, 32, nil, nil)
      end
    end
  end

  describe "derive_key/4 output properties" do
    test "returns exactly the requested number of bytes" do
      ikm = :crypto.strong_rand_bytes(32)

      for length <- [1, 16, 32, 48, 64, 128] do
        result = HKDF.derive_key(ikm, length, nil, nil)
        assert byte_size(result) == length
      end
    end

    test "same inputs produce same output (deterministic)" do
      ikm = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(16)
      info = "context"

      result1 = HKDF.derive_key(ikm, 32, salt, info)
      result2 = HKDF.derive_key(ikm, 32, salt, info)
      assert result1 == result2
    end

    test "different IKM produces different output" do
      ikm1 = :crypto.strong_rand_bytes(32)
      ikm2 = :crypto.strong_rand_bytes(32)

      result1 = HKDF.derive_key(ikm1, 32, nil, nil)
      result2 = HKDF.derive_key(ikm2, 32, nil, nil)
      assert result1 != result2
    end
  end

  describe "extract/2 and expand/3" do
    test "extract produces 32-byte PRK for SHA-256" do
      ikm = :binary.copy(<<0x0B>>, 22)
      salt = Base.decode16!("000102030405060708090A0B0C", case: :upper)

      prk = HKDF.extract(ikm, salt)

      expected_prk =
        Base.decode16!(
          "077709362C2E32DF0DDC3F0DC47BBA6390B6C73BB50F9C3122EC844AD7C2B3E5",
          case: :upper
        )

      assert prk == expected_prk
      assert byte_size(prk) == 32
    end

    test "expand produces correct OKM from PRK" do
      prk =
        Base.decode16!(
          "077709362C2E32DF0DDC3F0DC47BBA6390B6C73BB50F9C3122EC844AD7C2B3E5",
          case: :upper
        )

      info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9", case: :upper)
      length = 42

      expected =
        Base.decode16!(
          "3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865",
          case: :upper
        )

      assert HKDF.expand(prk, length, info) == expected
    end
  end

  describe "property-based tests" do
    property "output length always matches requested length" do
      check all(
              ikm <- StreamData.binary(min_length: 1, max_length: 64),
              length <- StreamData.integer(1..128)
            ) do
        result = HKDF.derive_key(ikm, length, nil, nil)
        assert byte_size(result) == length
      end
    end

    property "deterministic for same inputs" do
      check all(
              ikm <- StreamData.binary(min_length: 1, max_length: 64),
              salt <- StreamData.binary(min_length: 0, max_length: 32),
              info <- StreamData.binary(min_length: 0, max_length: 32)
            ) do
        r1 = HKDF.derive_key(ikm, 32, salt, info)
        r2 = HKDF.derive_key(ikm, 32, salt, info)
        assert r1 == r2
      end
    end
  end
end
