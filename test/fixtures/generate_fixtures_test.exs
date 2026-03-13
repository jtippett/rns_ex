defmodule GenerateFixturesTest do
  @moduledoc """
  Generates the protocol_compatibility.json fixture file.
  Excluded from normal `mix test` — run explicitly to regenerate:

      mix test test/fixtures/generate_fixtures_test.exs --include generate_fixtures
  """
  use ExUnit.Case

  import Bitwise

  alias RNS.Cryptography.{AES, Ed25519, Hashes, HKDF, PKCS7, Token, X25519}
  alias RNS.Identity

  defp to_hex(nil), do: nil
  defp to_hex(data) when is_binary(data), do: Base.encode16(data, case: :lower)
  defp sha256(data), do: :crypto.hash(:sha256, data)

  @tag :generate_fixtures
  test "generate protocol compatibility fixtures" do
    fixtures = %{}

    # 1. HASH COMPUTATION
    test_inputs = [
      <<>>,
      "hello",
      "Reticulum Network Stack",
      :binary.list_to_bin(Enum.to_list(0..255)),
      :binary.copy(<<0x00>>, 32),
      :binary.copy(<<0xFF>>, 64)
    ]

    hash_fixtures =
      Enum.map(test_inputs, fn inp ->
        %{
          "input" => to_hex(inp),
          "sha256" => to_hex(Hashes.sha256(inp)),
          "sha512" => to_hex(Hashes.sha512(inp)),
          "truncated_hash" => to_hex(Hashes.truncated_hash(inp)),
          "full_hash" => to_hex(Identity.full_hash(inp))
        }
      end)

    fixtures = Map.put(fixtures, "hashes", hash_fixtures)

    # 2. IDENTITY KEY OPERATIONS
    known_prv_bytes_list = [
      :binary.list_to_bin(Enum.map(0..63, &rem(&1, 256))),
      sha256("test_key_pair_2") <> sha256("test_sign_pair_2"),
      :binary.copy(<<0x42>>, 64)
    ]

    identity_fixtures =
      Enum.with_index(known_prv_bytes_list, fn prv_bytes, idx ->
        id = Identity.from_bytes(prv_bytes)
        pub_key = Identity.public_key(id)
        test_message = "test message #{idx}"
        signature = Identity.sign(id, test_message)

        %{
          "private_key" => to_hex(prv_bytes),
          "public_key" => to_hex(pub_key),
          "x25519_pub" => to_hex(id.pub_bytes),
          "ed25519_pub" => to_hex(id.sig_pub_bytes),
          "identity_hash" => to_hex(id.hash),
          "hexhash" => id.hexhash,
          "test_message" => to_hex(test_message),
          "signature" => to_hex(signature)
        }
      end)

    fixtures = Map.put(fixtures, "identities", identity_fixtures)

    # 3. DESTINATION HASH COMPUTATION
    id = Identity.from_bytes(Enum.at(known_prv_bytes_list, 0))

    dest_configs = [
      {"test_app", []},
      {"test_app", ["aspect1"]},
      {"test_app", ["aspect1", "aspect2"]},
      {"myapp", ["echo", "request"]},
      {"rns_ex", ["compatibility", "test", "vectors"]}
    ]

    name_hash_len = div(Identity.name_hash_length(), 8)
    truncated_hash_len = div(RNS.Reticulum.truncated_hashlength(), 8)

    dest_fixtures =
      Enum.map(dest_configs, fn {app_name, aspects} ->
        name_string =
          if aspects == [], do: app_name, else: app_name <> "." <> Enum.join(aspects, ".")

        <<name_hash::binary-size(name_hash_len), _::binary>> =
          Identity.full_hash(name_string)

        addr_hash_material = name_hash <> id.hash
        <<dest_hash::binary-size(truncated_hash_len), _::binary>> = Identity.full_hash(addr_hash_material)
        <<plain_hash::binary-size(truncated_hash_len), _::binary>> = Identity.full_hash(name_hash)

        %{
          "app_name" => app_name,
          "aspects" => aspects,
          "name_string" => name_string,
          "name_hash" => to_hex(name_hash),
          "identity_hash" => to_hex(id.hash),
          "single_dest_hash" => to_hex(dest_hash),
          "plain_dest_hash" => to_hex(plain_hash)
        }
      end)

    fixtures = Map.put(fixtures, "destinations", dest_fixtures)

    # 4. HKDF KEY DERIVATION
    hkdf_configs = [
      {:binary.copy(<<0x0B>>, 22), 42,
       :binary.list_to_bin(Enum.to_list(0x00..0x0C)),
       :binary.list_to_bin(Enum.to_list(0xF0..0xF9)),
       "RFC 5869 Test Case 1"},
      {:binary.list_to_bin(Enum.to_list(0..0x4F)), 82,
       :binary.list_to_bin(Enum.to_list(0x60..0xA0)),
       :binary.list_to_bin(Enum.to_list(0xB0..0xDF)),
       "RFC 5869 Test Case 2"},
      {:binary.copy(<<0x0B>>, 22), 42, nil, nil, "RFC 5869 Test Case 3 (no salt, no info)"},
      {:binary.copy(<<0xAA>>, 32), 64, :binary.copy(<<0xBB>>, 16), nil,
       "RNS Identity decrypt pattern"},
      {sha256("shared_key"), 64,
       binary_part(sha256("identity"), 0, 16), nil,
       "RNS typical ECDH derived key"}
    ]

    hkdf_fixtures =
      Enum.map(hkdf_configs, fn {ikm, length, salt, info, desc} ->
        derived = HKDF.derive_key(ikm, length, salt, info)
        %{
          "description" => desc,
          "ikm" => to_hex(ikm),
          "length" => length,
          "salt" => to_hex(salt),
          "info" => to_hex(info),
          "derived_key" => to_hex(derived)
        }
      end)

    fixtures = Map.put(fixtures, "hkdf", hkdf_fixtures)

    # 5. TOKEN ENCRYPT/DECRYPT
    known_keys = [
      :binary.copy(<<0x01>>, 64),
      :binary.copy(<<0x02>>, 32)
    ]

    known_plaintexts = [
      "Hello, Reticulum!",
      <<>>,
      :binary.copy("A", 100),
      :binary.list_to_bin(Enum.to_list(0..255))
    ]

    token_fixtures =
      for key <- known_keys, plaintext <- known_plaintexts do
        token = Token.new(key)
        ciphertext = Token.encrypt(token, plaintext)
        ^plaintext = Token.decrypt(token, ciphertext)

        iv = binary_part(ciphertext, 0, 16)
        ct_body = binary_part(ciphertext, 16, byte_size(ciphertext) - 16 - 32)
        hmac_val = binary_part(ciphertext, byte_size(ciphertext) - 32, 32)

        %{
          "key" => to_hex(key),
          "key_size" => byte_size(key),
          "plaintext" => to_hex(plaintext),
          "ciphertext" => to_hex(ciphertext),
          "iv" => to_hex(iv),
          "encrypted_body" => to_hex(ct_body),
          "hmac" => to_hex(hmac_val)
        }
      end

    fixtures = Map.put(fixtures, "tokens", token_fixtures)

    # 6. PKCS7 PADDING
    pkcs7_data = [
      <<>>,
      "A",
      "AB",
      "ABCDEFGHIJKLMNO",
      "ABCDEFGHIJKLMNOP",
      :binary.list_to_bin(Enum.to_list(0..30))
    ]

    pkcs7_fixtures =
      Enum.map(pkcs7_data, fn data ->
        padded = PKCS7.pad(data)
        %{"input" => to_hex(data), "padded" => to_hex(padded), "block_size" => 16}
      end)

    fixtures = Map.put(fixtures, "pkcs7", pkcs7_fixtures)

    # 7. X25519 ECDH KEY EXCHANGE
    prv_a_bytes = sha256("x25519_key_a")
    prv_b_bytes = sha256("x25519_key_b")

    key_a = X25519.from_private_bytes(prv_a_bytes)
    key_b = X25519.from_private_bytes(prv_b_bytes)
    pub_a = X25519.public_key(key_a)
    pub_b = X25519.public_key(key_b)
    shared_ab = X25519.exchange(key_a, pub_b)
    shared_ba = X25519.exchange(key_b, pub_a)
    assert shared_ab == shared_ba

    x25519_fixtures = [
      %{
        "private_a" => to_hex(X25519.private_bytes(key_a)),
        "public_a" => to_hex(pub_a),
        "private_b" => to_hex(X25519.private_bytes(key_b)),
        "public_b" => to_hex(pub_b),
        "shared_secret" => to_hex(shared_ab)
      }
    ]

    fixtures = Map.put(fixtures, "x25519", x25519_fixtures)

    # 8. ED25519 SIGNATURES
    ed_prv_bytes_list = [
      sha256("ed25519_key_1"),
      sha256("ed25519_key_2")
    ]

    ed25519_fixtures =
      Enum.map(ed_prv_bytes_list, fn ed_prv_bytes ->
        ed_key = Ed25519.from_private_bytes(ed_prv_bytes)
        ed_pub = Ed25519.public_key(ed_key)
        messages = ["test", <<>>, "Reticulum", :binary.list_to_bin(Enum.to_list(0..99))]

        sigs =
          Enum.map(messages, fn msg ->
            sig = Ed25519.sign(ed_key, msg)
            %{"message" => to_hex(msg), "signature" => to_hex(sig)}
          end)

        %{
          "private_key" => to_hex(ed_prv_bytes),
          "public_key" => to_hex(ed_pub),
          "signatures" => sigs
        }
      end)

    fixtures = Map.put(fixtures, "ed25519", ed25519_fixtures)

    # 9. IDENTITY ENCRYPT/DECRYPT
    id_receiver = Identity.from_bytes(Enum.at(known_prv_bytes_list, 1))

    enc_plaintexts = [
      "Hello!",
      "Cross-language compatibility test",
      :binary.list_to_bin(Enum.to_list(0..199))
    ]

    enc_fixtures =
      Enum.map(enc_plaintexts, fn pt ->
        ct = Identity.encrypt(id_receiver, pt)
        ^pt = Identity.decrypt(id_receiver, ct)

        ephemeral_pub = binary_part(ct, 0, 32)
        token_data = binary_part(ct, 32, byte_size(ct) - 32)

        %{
          "receiver_private_key" => to_hex(Enum.at(known_prv_bytes_list, 1)),
          "receiver_public_key" => to_hex(Identity.public_key(id_receiver)),
          "receiver_hash" => to_hex(id_receiver.hash),
          "plaintext" => to_hex(pt),
          "ciphertext" => to_hex(ct),
          "ephemeral_pub" => to_hex(ephemeral_pub),
          "token_data" => to_hex(token_data)
        }
      end)

    fixtures = Map.put(fixtures, "identity_encryption", enc_fixtures)

    # 10. PACKET ENCODING
    flag_tests = [
      {0, 0, 0, 0, 0}, {1, 0, 0, 0, 0}, {0, 1, 0, 0, 0}, {0, 0, 1, 0, 0},
      {0, 0, 0, 1, 0}, {0, 0, 0, 0, 1}, {0, 0, 0, 0, 2}, {0, 0, 0, 0, 3},
      {1, 1, 1, 3, 3}, {0, 0, 0, 0, 1}
    ]

    packet_fixtures =
      Enum.map(flag_tests, fn {ht, cf, tt, dt, pt} ->
        flags = (ht <<< 6) ||| (cf <<< 5) ||| (tt <<< 4) ||| (dt <<< 2) ||| pt
        %{
          "header_type" => ht, "context_flag" => cf, "transport_type" => tt,
          "dest_type" => dt, "packet_type" => pt, "flags_byte" => flags
        }
      end)

    fixtures = Map.put(fixtures, "packet_flags", packet_fixtures)

    dest_hash_h = :binary.copy(<<0xAA>>, 16)
    transport_id_h = :binary.copy(<<0xBB>>, 16)
    flags_h1 = 0
    hops = 3
    context = 0x00
    header1 = <<flags_h1, hops>> <> dest_hash_h <> <<context>>

    flags_h2 = (1 <<< 6) ||| (1 <<< 4)
    header2 = <<flags_h2, hops>> <> transport_id_h <> dest_hash_h <> <<context>>

    header_tests = [
      %{
        "type" => "HEADER_1", "flags" => flags_h1, "hops" => hops,
        "dest_hash" => to_hex(dest_hash_h), "context" => context,
        "header" => to_hex(header1), "header_size" => byte_size(header1)
      },
      %{
        "type" => "HEADER_2", "flags" => flags_h2, "hops" => hops,
        "transport_id" => to_hex(transport_id_h), "dest_hash" => to_hex(dest_hash_h),
        "context" => context, "header" => to_hex(header2), "header_size" => byte_size(header2)
      }
    ]

    fixtures = Map.put(fixtures, "packet_headers", header_tests)

    # 11. ANNOUNCE FORMAT
    id_announce = Identity.from_bytes(Enum.at(known_prv_bytes_list, 0))
    app_name = "test_app"
    aspects_list = [["echo"], ["transfer", "large"]]

    announce_fixtures =
      Enum.map(aspects_list, fn aspects ->
        name_string = app_name <> "." <> Enum.join(aspects, ".")
        <<n_hash::binary-size(name_hash_len), _::binary>> = Identity.full_hash(name_string)
        <<d_hash::binary-size(truncated_hash_len), _::binary>> = Identity.full_hash(n_hash <> id_announce.hash)
        random_hash = <<0xDE, 0xAD, 0xBE, 0xEF, 0x42>> <> <<1_700_000_000::unsigned-big-size(40)>>
        pub_key = Identity.public_key(id_announce)
        signed_data = d_hash <> pub_key <> n_hash <> random_hash
        signature = Identity.sign(id_announce, signed_data)
        announce_data = pub_key <> n_hash <> random_hash <> signature

        %{
          "app_name" => app_name, "aspects" => aspects, "name_string" => name_string,
          "name_hash" => to_hex(n_hash), "dest_hash" => to_hex(d_hash),
          "random_hash" => to_hex(random_hash), "public_key" => to_hex(pub_key),
          "signed_data" => to_hex(signed_data), "signature" => to_hex(signature),
          "announce_data" => to_hex(announce_data),
          "identity_private_key" => to_hex(Enum.at(known_prv_bytes_list, 0))
        }
      end)

    # With app_data
    aspects = ["echo"]
    name_string = app_name <> "." <> Enum.join(aspects, ".")
    <<n_hash::binary-size(name_hash_len), _::binary>> = Identity.full_hash(name_string)
    <<d_hash::binary-size(truncated_hash_len), _::binary>> = Identity.full_hash(n_hash <> id_announce.hash)
    random_hash = <<0xCA, 0xFE, 0xBA, 0xBE, 0x01>> <> <<1_700_000_000::unsigned-big-size(40)>>
    pub_key = Identity.public_key(id_announce)
    app_data = "Hello from Python RNS!"
    signed_data = d_hash <> pub_key <> n_hash <> random_hash <> app_data
    signature = Identity.sign(id_announce, signed_data)
    announce_data = pub_key <> n_hash <> random_hash <> signature <> app_data

    announce_fixtures =
      announce_fixtures ++ [
        %{
          "app_name" => app_name, "aspects" => ["echo"], "name_string" => name_string,
          "name_hash" => to_hex(n_hash), "dest_hash" => to_hex(d_hash),
          "random_hash" => to_hex(random_hash), "public_key" => to_hex(pub_key),
          "app_data" => to_hex(app_data), "signed_data" => to_hex(signed_data),
          "signature" => to_hex(signature), "announce_data" => to_hex(announce_data),
          "identity_private_key" => to_hex(Enum.at(known_prv_bytes_list, 0))
        }
      ]

    fixtures = Map.put(fixtures, "announces", announce_fixtures)

    # 12. CONSTANTS VERIFICATION
    fixtures =
      Map.put(fixtures, "constants", %{
        "MTU" => RNS.Reticulum.mtu(),
        "TRUNCATED_HASHLENGTH" => RNS.Reticulum.truncated_hashlength(),
        "HEADER_MINSIZE" => RNS.Reticulum.header_minsize(),
        "HEADER_MAXSIZE" => RNS.Reticulum.header_maxsize(),
        "MDU" => RNS.Reticulum.mdu(),
        "IFAC_MIN_SIZE" => RNS.Reticulum.ifac_min_size(),
        "RESOURCE_CACHE" => RNS.Reticulum.resource_cache(),
        "IDENTITY_KEYSIZE" => Identity.keysize(),
        "IDENTITY_HASHLENGTH" => Identity.hashlength(),
        "IDENTITY_NAME_HASH_LENGTH" => Identity.name_hash_length(),
        "IDENTITY_RATCHETSIZE" => Identity.ratchetsize(),
        "IDENTITY_TRUNCATED_HASHLENGTH" => Identity.truncated_hashlength(),
        "TOKEN_OVERHEAD" => 48,
        "ANNOUNCE_CAP" => RNS.Reticulum.announce_cap(),
        "MINIMUM_BITRATE" => RNS.Reticulum.minimum_bitrate(),
        "DEFAULT_PER_HOP_TIMEOUT" => RNS.Reticulum.default_per_hop_timeout()
      })

    # 13. AES-256-CBC
    aes_tests = [
      %{key: :binary.copy(<<0x01>>, 32), iv: :binary.copy(<<0x02>>, 16), plaintext: "Hello AES-256-CBC!"},
      %{key: :binary.list_to_bin(Enum.to_list(0..31)), iv: :binary.list_to_bin(Enum.to_list(0..15)),
        plaintext: :binary.list_to_bin(Enum.to_list(0..47))},
      %{key: :binary.copy(<<0xFF>>, 32), iv: :binary.copy(<<0x00>>, 16), plaintext: <<>>}
    ]

    aes_fixtures =
      Enum.map(aes_tests, fn t ->
        padded = PKCS7.pad(t.plaintext)
        ciphertext = AES.encrypt(padded, t.key, t.iv)
        %{
          "key" => to_hex(t.key), "iv" => to_hex(t.iv),
          "plaintext" => to_hex(t.plaintext), "padded_plaintext" => to_hex(padded),
          "ciphertext" => to_hex(ciphertext)
        }
      end)

    fixtures = Map.put(fixtures, "aes", aes_fixtures)

    # 14. HMAC-SHA256
    hmac_tests = [
      {"key", "data"},
      {:binary.copy(<<0x0B>>, 20), "Hi There"},
      {:binary.list_to_bin(Enum.to_list(0..31)), :binary.list_to_bin(Enum.to_list(0..63))}
    ]

    hmac_fixtures =
      Enum.map(hmac_tests, fn {key, data} ->
        digest = :crypto.mac(:hmac, :sha256, key, data)
        %{"key" => to_hex(key), "data" => to_hex(data), "digest" => to_hex(digest)}
      end)

    fixtures = Map.put(fixtures, "hmac", hmac_fixtures)

    # Write output
    output_path = Path.join([__DIR__, "protocol_compatibility.json"])
    json = Jason.encode!(fixtures, pretty: true)
    File.write!(output_path, json)

    IO.puts("\nFixtures written to #{output_path}")
    assert File.exists?(output_path)
  end
end
