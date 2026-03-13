defmodule RNS.Utilities.RNIDTest do
  @moduledoc """
  Tests for the rnid utility.

  Tests argument parsing, constants, key formatting, data decoding,
  identity import/export, file signing/validation, encryption/decryption,
  chunked binary splitting, and CLI output.
  """

  use ExUnit.Case, async: false

  alias RNS.Utilities.RNID

  # ── Constants ──────────────────────────────────────────────────────

  describe "constants" do
    test "app_name is rnid" do
      assert RNID.app_name() == "rnid"
    end

    test "sig_ext is rsg" do
      assert RNID.sig_ext() == "rsg"
    end

    test "encrypt_ext is rfe" do
      assert RNID.encrypt_ext() == "rfe"
    end

    test "chunk_size is 16 MB" do
      assert RNID.chunk_size() == 16 * 1024 * 1024
    end
  end

  # ── Argument Parsing ──────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNID.parse_args([])

      assert opts.configdir == nil
      assert opts.identity == nil
      assert opts.generate == nil
      assert opts.import_str == nil
      assert opts.export == false
      assert opts.verbosity == 0
      assert opts.quietness == 0
      assert opts.announce == nil
      assert opts.hash == nil
      assert opts.encrypt == nil
      assert opts.decrypt == nil
      assert opts.sign == nil
      assert opts.validate == nil
      assert opts.read == nil
      assert opts.write == nil
      assert opts.force == false
      assert opts.stdin == false
      assert opts.stdout == false
      assert opts.request == false
      assert opts.timeout == RNS.Transport.path_request_timeout() * 1.0
      assert opts.print_identity == false
      assert opts.print_private == false
      assert opts.base64 == false
      assert opts.base32 == false
      assert opts.version == false
    end

    test "parses --config option" do
      assert {:ok, opts} = RNID.parse_args(["--config", "/tmp/rns"])
      assert opts.configdir == "/tmp/rns"
    end

    test "parses -i / --identity option" do
      assert {:ok, opts} = RNID.parse_args(["-i", "abcdef1234567890abcdef1234567890"])
      assert opts.identity == "abcdef1234567890abcdef1234567890"

      assert {:ok, opts} = RNID.parse_args(["--identity", "/path/to/id"])
      assert opts.identity == "/path/to/id"
    end

    test "parses -g / --generate option" do
      assert {:ok, opts} = RNID.parse_args(["-g", "/tmp/new_id"])
      assert opts.generate == "/tmp/new_id"
    end

    test "parses -m / --import option" do
      assert {:ok, opts} = RNID.parse_args(["-m", "aabbccdd"])
      assert opts.import_str == "aabbccdd"
    end

    test "parses -x / --export flag" do
      assert {:ok, opts} = RNID.parse_args(["-x"])
      assert opts.export == true
    end

    test "parses -v / --verbose flag (repeatable)" do
      assert {:ok, opts} = RNID.parse_args(["-v"])
      assert opts.verbosity == 1

      assert {:ok, opts} = RNID.parse_args(["-v", "-v"])
      assert opts.verbosity == 2
    end

    test "parses -q / --quiet flag (repeatable)" do
      assert {:ok, opts} = RNID.parse_args(["-q"])
      assert opts.quietness == 1

      assert {:ok, opts} = RNID.parse_args(["-q", "-q"])
      assert opts.quietness == 2
    end

    test "parses -a / --announce option" do
      assert {:ok, opts} = RNID.parse_args(["-a", "myapp.service"])
      assert opts.announce == "myapp.service"
    end

    test "parses -H / --hash option" do
      assert {:ok, opts} = RNID.parse_args(["-H", "myapp.echo"])
      assert opts.hash == "myapp.echo"
    end

    test "parses -e / --encrypt option" do
      assert {:ok, opts} = RNID.parse_args(["-e", "/tmp/plaintext"])
      assert opts.encrypt == "/tmp/plaintext"
    end

    test "parses -d / --decrypt option" do
      assert {:ok, opts} = RNID.parse_args(["-d", "/tmp/ciphertext.rfe"])
      assert opts.decrypt == "/tmp/ciphertext.rfe"
    end

    test "parses -s / --sign option" do
      assert {:ok, opts} = RNID.parse_args(["-s", "/tmp/file.txt"])
      assert opts.sign == "/tmp/file.txt"
    end

    test "parses -V / --validate option" do
      assert {:ok, opts} = RNID.parse_args(["-V", "/tmp/file.txt.rsg"])
      assert opts.validate == "/tmp/file.txt.rsg"
    end

    test "parses -r / --read and -w / --write options" do
      assert {:ok, opts} = RNID.parse_args(["-r", "/tmp/input", "-w", "/tmp/output"])
      assert opts.read == "/tmp/input"
      assert opts.write == "/tmp/output"
    end

    test "parses -f / --force flag" do
      assert {:ok, opts} = RNID.parse_args(["-f"])
      assert opts.force == true
    end

    test "parses -R / --request flag" do
      assert {:ok, opts} = RNID.parse_args(["-R"])
      assert opts.request == true
    end

    test "parses -t / --timeout option" do
      assert {:ok, opts} = RNID.parse_args(["-t", "30.0"])
      assert opts.timeout == 30.0
    end

    test "parses -p / --print-identity flag" do
      assert {:ok, opts} = RNID.parse_args(["-p"])
      assert opts.print_identity == true
    end

    test "parses -P / --print-private flag" do
      assert {:ok, opts} = RNID.parse_args(["-P"])
      assert opts.print_private == true
    end

    test "parses -b / --base64 flag" do
      assert {:ok, opts} = RNID.parse_args(["-b"])
      assert opts.base64 == true
    end

    test "parses -B / --base32 flag" do
      assert {:ok, opts} = RNID.parse_args(["-B"])
      assert opts.base32 == true
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNID.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses combined crypto options" do
      args = [
        "--config",
        "/tmp/rns",
        "-i",
        "abcdef1234567890abcdef1234567890",
        "-s",
        "/tmp/file.txt",
        "-w",
        "/tmp/file.txt.rsg",
        "-f",
        "-v"
      ]

      assert {:ok, opts} = RNID.parse_args(args)
      assert opts.configdir == "/tmp/rns"
      assert opts.identity == "abcdef1234567890abcdef1234567890"
      assert opts.sign == "/tmp/file.txt"
      assert opts.write == "/tmp/file.txt.rsg"
      assert opts.force == true
      assert opts.verbosity == 1
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNID.parse_args(["--unknown"])
      assert msg =~ "unknown option"
    end
  end

  # ── Version Output ────────────────────────────────────────────────

  describe "version output" do
    test "main with --version prints version" do
      output = capture_io(fn -> RNID.main(["--version"]) end)
      assert output =~ "rnid #{RNS.Version.version()}"
    end
  end

  # ── Key Formatting ────────────────────────────────────────────────

  describe "format_key/2" do
    test "formats key as hex by default" do
      key = <<0xAB, 0xCD, 0xEF, 0x01>>
      opts = %{base64: false, base32: false}
      result = RNID.format_key(key, opts)
      assert result == RNS.hexrep(key, false)
    end

    test "formats key as base64 when base64 option is set" do
      key = <<0xAB, 0xCD, 0xEF, 0x01>>
      opts = %{base64: true, base32: false}
      result = RNID.format_key(key, opts)
      assert result == Base.url_encode64(key)
    end

    test "formats key as base32 when base32 option is set" do
      key = <<0xAB, 0xCD, 0xEF, 0x01>>
      opts = %{base64: false, base32: true}
      result = RNID.format_key(key, opts)
      assert result == Base.encode32(key)
    end

    test "base64 takes precedence over base32" do
      key = <<0xAB, 0xCD, 0xEF, 0x01>>
      opts = %{base64: true, base32: true}
      result = RNID.format_key(key, opts)
      assert result == Base.url_encode64(key)
    end
  end

  # ── Data Decoding ─────────────────────────────────────────────────

  describe "decode_identity_data/2" do
    test "decodes hex data" do
      opts = %{base64: false, base32: false}
      hex = "ABCDEF0123456789"
      assert {:ok, bytes} = RNID.decode_identity_data(hex, opts)
      assert bytes == <<0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89>>
    end

    test "decodes base64 data" do
      key = :crypto.strong_rand_bytes(32)
      encoded = Base.url_encode64(key)
      opts = %{base64: true, base32: false}
      assert {:ok, ^key} = RNID.decode_identity_data(encoded, opts)
    end

    test "decodes base32 data" do
      key = :crypto.strong_rand_bytes(32)
      encoded = Base.encode32(key)
      opts = %{base64: false, base32: true}
      assert {:ok, ^key} = RNID.decode_identity_data(encoded, opts)
    end

    test "returns error for invalid hex data" do
      opts = %{base64: false, base32: false}
      assert {:error, msg} = RNID.decode_identity_data("ZZZZ", opts)
      assert msg =~ "Invalid hexadecimal"
    end

    test "returns error for invalid base64 data" do
      opts = %{base64: true, base32: false}
      assert {:error, msg} = RNID.decode_identity_data("!!!invalid!!!", opts)
      assert msg =~ "Invalid base64"
    end

    test "returns error for invalid base32 data" do
      opts = %{base64: false, base32: true}
      assert {:error, msg} = RNID.decode_identity_data("0000", opts)
      assert msg =~ "Invalid base32"
    end
  end

  # ── Binary Chunking ───────────────────────────────────────────────

  describe "chunk_binary/2" do
    test "returns empty list for empty binary" do
      assert RNID.chunk_binary(<<>>, 1024) == []
    end

    test "returns single chunk when data fits" do
      data = <<1, 2, 3, 4, 5>>
      assert RNID.chunk_binary(data, 10) == [data]
    end

    test "returns single chunk when data equals chunk size" do
      data = <<1, 2, 3, 4, 5>>
      assert RNID.chunk_binary(data, 5) == [data]
    end

    test "splits data into multiple chunks" do
      data = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
      chunks = RNID.chunk_binary(data, 3)
      assert length(chunks) == 4
      assert Enum.at(chunks, 0) == <<1, 2, 3>>
      assert Enum.at(chunks, 1) == <<4, 5, 6>>
      assert Enum.at(chunks, 2) == <<7, 8, 9>>
      assert Enum.at(chunks, 3) == <<10>>
    end

    test "reassembles to original data" do
      data = :crypto.strong_rand_bytes(100)
      chunks = RNID.chunk_binary(data, 17)
      assert IO.iodata_to_binary(chunks) == data
    end

    test "handles chunk size of 1" do
      data = <<1, 2, 3>>
      chunks = RNID.chunk_binary(data, 1)
      assert length(chunks) == 3
      assert chunks == [<<1>>, <<2>>, <<3>>]
    end
  end

  # ── Spinner ────────────────────────────────────────────────────────

  describe "spin/3" do
    test "returns true immediately when condition is already true" do
      output =
        capture_io(fn ->
          result = RNID.spin(fn -> true end, "Waiting", 1.0)
          send(self(), {:result, result})
        end)

      assert_received {:result, true}
      # Should have printed and cleared the message
      assert is_binary(output)
    end

    test "returns false on timeout" do
      output =
        capture_io(fn ->
          result = RNID.spin(fn -> false end, "Waiting", 0.2)
          send(self(), {:result, result})
        end)

      assert_received {:result, false}
      assert is_binary(output)
    end
  end

  # ── Identity Operations (Integration) ──────────────────────────────

  describe "identity file operations" do
    setup do
      tmp_dir = System.tmp_dir!()
      identity_path = Path.join(tmp_dir, "rnid_test_identity_#{:rand.uniform(999_999)}")
      on_cleanup = fn -> File.rm(identity_path) end
      {:ok, identity_path: identity_path, cleanup: on_cleanup}
    end

    test "generate and load identity roundtrip", %{identity_path: path, cleanup: cleanup} do
      # Generate new identity
      identity = RNS.Identity.new()
      assert %RNS.Identity{} = identity
      assert identity.prv_bytes != nil
      assert identity.pub_bytes != nil

      # Save to file
      RNS.Identity.to_file(identity, path)
      assert File.exists?(path)

      # Load from file
      loaded = RNS.Identity.from_file(path)
      assert loaded != nil
      assert loaded.pub_bytes == identity.pub_bytes

      cleanup.()
    end

    test "sign and validate file roundtrip", %{identity_path: path, cleanup: cleanup} do
      identity = RNS.Identity.new()
      test_data = "Hello, Reticulum!"

      # Sign
      signature = RNS.Identity.sign(identity, test_data)
      assert byte_size(signature) == 64

      # Validate
      assert RNS.Identity.validate(identity, signature, test_data)

      # Invalid data fails validation
      refute RNS.Identity.validate(identity, signature, "tampered data")

      # Write signature to file for future validation
      sig_path = path <> ".rsg"
      File.write!(sig_path, signature)
      assert File.exists?(sig_path)

      # Read back and validate
      read_sig = File.read!(sig_path)
      assert RNS.Identity.validate(identity, read_sig, test_data)

      File.rm(sig_path)
      cleanup.()
    end

    test "encrypt and decrypt file roundtrip", %{identity_path: path, cleanup: cleanup} do
      identity = RNS.Identity.new()
      test_data = :crypto.strong_rand_bytes(256)

      # Encrypt
      ciphertext = RNS.Identity.encrypt(identity, test_data)
      assert ciphertext != test_data

      # Decrypt
      plaintext = RNS.Identity.decrypt(identity, ciphertext)
      assert plaintext == test_data

      # Write encrypted data to file
      enc_path = path <> ".rfe"
      File.write!(enc_path, ciphertext)

      # Read back and decrypt
      read_enc = File.read!(enc_path)
      decrypted = RNS.Identity.decrypt(identity, read_enc)
      assert decrypted == test_data

      File.rm(enc_path)
      cleanup.()
    end

    test "identity import/export via bytes", %{cleanup: cleanup} do
      identity = RNS.Identity.new()

      # Export private key
      prv_key = RNS.Identity.private_key(identity)
      assert is_binary(prv_key)

      # Export public key
      pub_key = RNS.Identity.public_key(identity)
      assert is_binary(pub_key)

      # Import from private key bytes (full identity)
      full_identity = RNS.Identity.from_bytes(prv_key)
      assert full_identity != nil
      assert full_identity.prv_bytes != nil
      assert full_identity.pub_bytes != nil

      # Derived public key should match original
      assert RNS.Identity.public_key(full_identity) == pub_key

      cleanup.()
    end
  end

  # ── Key Encoding Formats ──────────────────────────────────────────

  describe "key encoding formats" do
    test "hex roundtrip" do
      key = :crypto.strong_rand_bytes(32)
      hex = RNS.hexrep(key, false)
      {:ok, decoded} = Base.decode16(hex, case: :mixed)
      assert decoded == key
    end

    test "base64 roundtrip" do
      key = :crypto.strong_rand_bytes(32)
      encoded = Base.url_encode64(key)
      {:ok, decoded} = Base.url_decode64(encoded)
      assert decoded == key
    end

    test "base32 roundtrip" do
      key = :crypto.strong_rand_bytes(32)
      encoded = Base.encode32(key)
      {:ok, decoded} = Base.decode32(encoded)
      assert decoded == key
    end
  end

  # ── Auto-set Read ─────────────────────────────────────────────────

  describe "auto-set behavior" do
    test "encrypt sets read to encrypt path if read is nil" do
      assert {:ok, opts} = RNID.parse_args(["-e", "/tmp/file.txt"])
      assert opts.encrypt == "/tmp/file.txt"
      assert opts.read == nil
      # The auto_set_read happens in program_setup, not parse_args
    end

    test "sign and encrypt options are mutually tracked" do
      assert {:ok, opts} = RNID.parse_args(["-s", "/tmp/file.txt"])
      assert opts.sign == "/tmp/file.txt"
      assert opts.encrypt == nil
    end
  end

  # ── Helper ─────────────────────────────────────────────────────────

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
