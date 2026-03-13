defmodule RNS.Cryptography.HMACTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RNS.Cryptography.HMAC

  # RFC 4231 Test Vectors for HMAC-SHA-256 and HMAC-SHA-512

  describe "digest/3 with HMAC-SHA-256" do
    test "RFC 4231 test case 1 - short key" do
      key = :binary.copy(<<0x0B>>, 20)
      data = "Hi There"

      expected =
        Base.decode16!(
          "B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha256) == expected
    end

    test "RFC 4231 test case 2 - key is 'Jefe'" do
      key = "Jefe"
      data = "what do ya want for nothing?"

      expected =
        Base.decode16!(
          "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha256) == expected
    end

    test "RFC 4231 test case 3 - key and data of 0xAA and 0xDD" do
      key = :binary.copy(<<0xAA>>, 20)
      data = :binary.copy(<<0xDD>>, 50)

      expected =
        Base.decode16!(
          "773EA91E36800E46854DB8EBD09181A72959098B3EF8C122D9635514CED565FE",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha256) == expected
    end

    test "RFC 4231 test case 4 - incrementing key and data" do
      key = Base.decode16!("0102030405060708090A0B0C0D0E0F10111213141516171819", case: :upper)
      data = :binary.copy(<<0xCD>>, 50)

      expected =
        Base.decode16!(
          "82558A389A443C0EA4CC819899F2083A85F0FAA3E578F8077A2E3FF46729665B",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha256) == expected
    end

    test "RFC 4231 test case 6 - large key (131 bytes)" do
      key = :binary.copy(<<0xAA>>, 131)
      data = "Test Using Larger Than Block-Size Key - Hash Key First"

      expected =
        Base.decode16!(
          "60E431591EE0B67F0D8A26AACBF5B77F8E0BC6213728C5140546040F0EE37F54",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha256) == expected
    end

    test "RFC 4231 test case 7 - large key and data" do
      key = :binary.copy(<<0xAA>>, 131)

      data =
        "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."

      expected =
        Base.decode16!(
          "9B09FFA71B942FCB27635FBCD5B0E944BFDC63644F0713938A7F51535C3A35E2",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha256) == expected
    end
  end

  describe "digest/3 with HMAC-SHA-512" do
    test "RFC 4231 test case 1 - short key" do
      key = :binary.copy(<<0x0B>>, 20)
      data = "Hi There"

      expected =
        Base.decode16!(
          "87AA7CDEA5EF619D4FF0B4241A1D6CB02379F4E2CE4EC2787AD0B30545E17CDEDAA833B7D6B8A702038B274EAEA3F4E4BE9D914EEB61F1702E696C203A126854",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha512) == expected
    end

    test "RFC 4231 test case 2 - key is 'Jefe'" do
      key = "Jefe"
      data = "what do ya want for nothing?"

      expected =
        Base.decode16!(
          "164B7A7BFCF819E2E395FBE73B56E0A387BD64222E831FD610270CD7EA2505549758BF75C05A994A6D034F65F8F0E6FDCAEAB1A34D4A6B4B636E070A38BCE737",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha512) == expected
    end

    test "RFC 4231 test case 3 - key and data of 0xAA and 0xDD" do
      key = :binary.copy(<<0xAA>>, 20)
      data = :binary.copy(<<0xDD>>, 50)

      expected =
        Base.decode16!(
          "FA73B0089D56A284EFB0F0756C890BE9B1B5DBDD8EE81A3655F83E33B2279D39BF3E848279A722C806B485A47E67C807B946A337BEE8942674278859E13292FB",
          case: :upper
        )

      assert HMAC.digest(key, data, :sha512) == expected
    end
  end

  describe "digest/3 defaults to SHA-256" do
    test "defaults to :sha256 when algorithm not specified" do
      key = "secret"
      data = "message"

      assert HMAC.digest(key, data) == HMAC.digest(key, data, :sha256)
    end
  end

  describe "digest/3 produces correct output lengths" do
    test "SHA-256 produces 32-byte output" do
      assert byte_size(HMAC.digest("key", "data", :sha256)) == 32
    end

    test "SHA-512 produces 64-byte output" do
      assert byte_size(HMAC.digest("key", "data", :sha512)) == 64
    end
  end

  describe "property-based tests" do
    property "HMAC-SHA256 matches :crypto.mac directly" do
      check all(
              key <- StreamData.binary(min_length: 1, max_length: 64),
              data <- StreamData.binary(min_length: 0, max_length: 256)
            ) do
        assert HMAC.digest(key, data, :sha256) == :crypto.mac(:hmac, :sha256, key, data)
      end
    end

    property "HMAC-SHA512 matches :crypto.mac directly" do
      check all(
              key <- StreamData.binary(min_length: 1, max_length: 64),
              data <- StreamData.binary(min_length: 0, max_length: 256)
            ) do
        assert HMAC.digest(key, data, :sha512) == :crypto.mac(:hmac, :sha512, key, data)
      end
    end
  end
end
