defmodule RNS.Cryptography.PKCS7Test do
  use ExUnit.Case, async: true

  alias RNS.Cryptography.PKCS7

  @block_size 16

  describe "pad/2" do
    test "pads empty data to full block of 0x10 bytes" do
      padded = PKCS7.pad(<<>>, @block_size)
      assert padded == :binary.copy(<<16>>, 16)
      assert byte_size(padded) == 16
    end

    test "pads 1-byte data to 16 bytes" do
      padded = PKCS7.pad(<<0xAA>>, @block_size)
      assert padded == <<0xAA>> <> :binary.copy(<<15>>, 15)
      assert byte_size(padded) == 16
    end

    test "pads 15-byte data to 16 bytes with single pad byte" do
      data = :binary.copy(<<0xFF>>, 15)
      padded = PKCS7.pad(data, @block_size)
      assert padded == data <> <<1>>
      assert byte_size(padded) == 16
    end

    test "pads exactly block-sized data to two blocks" do
      data = :binary.copy(<<0xBB>>, 16)
      padded = PKCS7.pad(data, @block_size)
      assert padded == data <> :binary.copy(<<16>>, 16)
      assert byte_size(padded) == 32
    end

    test "pads 17-byte data to 32 bytes" do
      data = :binary.copy(<<0xCC>>, 17)
      padded = PKCS7.pad(data, @block_size)
      assert padded == data <> :binary.copy(<<15>>, 15)
      assert byte_size(padded) == 32
    end

    test "result is always a multiple of block size" do
      for len <- 0..48 do
        data = :crypto.strong_rand_bytes(len)
        padded = PKCS7.pad(data, @block_size)
        assert rem(byte_size(padded), @block_size) == 0,
               "Length #{len} produced non-aligned output of #{byte_size(padded)} bytes"
      end
    end

    test "works with non-default block sizes" do
      # Block size 8
      data = <<1, 2, 3>>
      padded = PKCS7.pad(data, 8)
      assert padded == <<1, 2, 3, 5, 5, 5, 5, 5>>
      assert byte_size(padded) == 8

      # Block size 32
      data = :binary.copy(<<0xDD>>, 20)
      padded = PKCS7.pad(data, 32)
      assert byte_size(padded) == 32
      assert binary_part(padded, 20, 12) == :binary.copy(<<12>>, 12)
    end

    test "default block size is 16" do
      data = <<1, 2, 3>>
      assert PKCS7.pad(data) == PKCS7.pad(data, 16)
    end
  end

  describe "unpad/2" do
    test "unpads single pad byte" do
      padded = :binary.copy(<<0xFF>>, 15) <> <<1>>
      assert PKCS7.unpad(padded, @block_size) == :binary.copy(<<0xFF>>, 15)
    end

    test "unpads full block of padding (empty original data)" do
      padded = :binary.copy(<<16>>, 16)
      assert PKCS7.unpad(padded, @block_size) == <<>>
    end

    test "unpads half-block padding" do
      data = :binary.copy(<<0xAA>>, 8)
      padded = data <> :binary.copy(<<8>>, 8)
      assert PKCS7.unpad(padded, @block_size) == data
    end

    test "roundtrip pad then unpad preserves data" do
      data = "Hello, Reticulum!"
      assert PKCS7.unpad(PKCS7.pad(data, @block_size), @block_size) == data
    end

    test "roundtrip for various lengths" do
      for len <- 0..64 do
        data = :crypto.strong_rand_bytes(len)
        assert PKCS7.unpad(PKCS7.pad(data, @block_size), @block_size) == data,
               "Roundtrip failed for length #{len}"
      end
    end

    test "raises on invalid padding value exceeding block size" do
      # Last byte is 17, which exceeds block size of 16
      invalid = :binary.copy(<<0>>, 15) <> <<17>>

      assert_raise ArgumentError, ~r/invalid padding/, fn ->
        PKCS7.unpad(invalid, @block_size)
      end
    end

    test "raises on zero padding value" do
      invalid = :binary.copy(<<0>>, 16)

      assert_raise ArgumentError, ~r/invalid padding/, fn ->
        PKCS7.unpad(invalid, @block_size)
      end
    end

    test "raises on empty data" do
      assert_raise ArgumentError, fn ->
        PKCS7.unpad(<<>>, @block_size)
      end
    end

    test "default block size is 16" do
      padded = :binary.copy(<<0xFF>>, 15) <> <<1>>
      assert PKCS7.unpad(padded) == PKCS7.unpad(padded, 16)
    end
  end

  if Code.ensure_loaded?(StreamData) do
    use ExUnitProperties

    describe "property-based tests" do
      property "pad/unpad roundtrip for arbitrary data and default block size" do
        check all data <- StreamData.binary(min_length: 0, max_length: 512) do
          assert PKCS7.unpad(PKCS7.pad(data)) == data
        end
      end

      property "padded output is always longer than input" do
        check all data <- StreamData.binary(min_length: 0, max_length: 512) do
          padded = PKCS7.pad(data)
          assert byte_size(padded) > byte_size(data)
        end
      end

      property "padded output is always block-aligned" do
        check all data <- StreamData.binary(min_length: 0, max_length: 512),
                  bs <- StreamData.member_of([8, 16, 32]) do
          padded = PKCS7.pad(data, bs)
          assert rem(byte_size(padded), bs) == 0
        end
      end
    end
  end
end
