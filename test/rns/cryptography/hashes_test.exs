defmodule RNS.Cryptography.HashesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RNS.Cryptography.Hashes

  # NIST / Python RNS test vectors for SHA-256

  describe "sha256/1" do
    test "empty input" do
      assert Hashes.sha256("") ==
               Base.decode16!("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
    end

    test "less than block length ('abc')" do
      assert Hashes.sha256("abc") ==
               Base.decode16!("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
    end

    test "exactly one block length (64 bytes of 'a')" do
      assert Hashes.sha256(String.duplicate("a", 64)) ==
               Base.decode16!("FFE054FE7AE0CB6DC65C3AF9B61D5209F439851DB43D0BA5997337DF154668EB")
    end

    test "several blocks (1,000,000 bytes of 'a')" do
      assert Hashes.sha256(String.duplicate("a", 1_000_000)) ==
               Base.decode16!("CDC76E5C9914FB9281A1C7E284D73E67F1809A48A497200E046D39CCC7112CD0")
    end

    test "returns a 32-byte binary" do
      result = Hashes.sha256("test data")
      assert is_binary(result)
      assert byte_size(result) == 32
    end

    property "matches :crypto.hash for random data" do
      check all(data <- binary()) do
        assert Hashes.sha256(data) == :crypto.hash(:sha256, data)
      end
    end
  end

  # NIST / Python RNS test vectors for SHA-512

  describe "sha512/1" do
    test "empty input" do
      assert Hashes.sha512("") ==
               Base.decode16!(
                 "CF83E1357EEFB8BDF1542850D66D8007D620E4050B5715DC83F4A921D36CE9CE" <>
                   "47D0D13C5D85F2B0FF8318D2877EEC2F63B931BD47417A81A538327AF927DA3E"
               )
    end

    test "less than block length ('abc')" do
      assert Hashes.sha512("abc") ==
               Base.decode16!(
                 "DDAF35A193617ABACC417349AE20413112E6FA4E89A97EA20A9EEEE64B55D39A" <>
                   "2192992A274FC1A836BA3C23A3FEEBBD454D4423643CE80E2A9AC94FA54CA49F"
               )
    end

    test "exactly one block length (128 bytes of 'a')" do
      assert Hashes.sha512(String.duplicate("a", 128)) ==
               Base.decode16!(
                 "B73D1929AA615934E61A871596B3F3B33359F42B8175602E89F7E06E5F658A24" <>
                   "3667807ED300314B95CACDD579F3E33ABDFBE351909519A846D465C59582F321"
               )
    end

    test "several blocks (1,000,000 bytes of 'a')" do
      assert Hashes.sha512(String.duplicate("a", 1_000_000)) ==
               Base.decode16!(
                 "E718483D0CE769644E2E42C7BC15B4638E1F98B13B2044285632A803AFA973EB" <>
                   "DE0FF244877EA60A4CB0432CE577C31BEB009C5C2C49AA2E4EADB217AD8CC09B"
               )
    end

    test "returns a 64-byte binary" do
      result = Hashes.sha512("test data")
      assert is_binary(result)
      assert byte_size(result) == 64
    end

    property "matches :crypto.hash for random data" do
      check all(data <- binary()) do
        assert Hashes.sha512(data) == :crypto.hash(:sha512, data)
      end
    end
  end

  # Truncated hash: first 16 bytes (128 bits) of SHA-256

  describe "truncated_hash/1" do
    test "returns first 16 bytes of SHA-256" do
      full = Hashes.sha256("test")
      <<expected::binary-size(16), _rest::binary>> = full
      assert Hashes.truncated_hash("test") == expected
    end

    test "returns exactly 16 bytes" do
      result = Hashes.truncated_hash("hello world")
      assert byte_size(result) == 16
    end

    test "empty input" do
      full = Hashes.sha256("")
      <<expected::binary-size(16), _rest::binary>> = full
      assert Hashes.truncated_hash("") == expected
    end

    test "different inputs produce different truncated hashes" do
      assert Hashes.truncated_hash("foo") != Hashes.truncated_hash("bar")
    end

    property "always returns 16 bytes for any input" do
      check all(data <- binary()) do
        result = Hashes.truncated_hash(data)
        assert byte_size(result) == 16
      end
    end

    property "equals first 16 bytes of sha256" do
      check all(data <- binary()) do
        <<prefix::binary-size(16), _::binary>> = Hashes.sha256(data)
        assert Hashes.truncated_hash(data) == prefix
      end
    end
  end
end
