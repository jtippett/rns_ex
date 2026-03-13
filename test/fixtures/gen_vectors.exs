#!/usr/bin/env elixir
# Generate test vectors for cross-language compatibility verification
# Run: mix run test/fixtures/gen_vectors.exs

alias RNS.Cryptography.{Hashes, HMAC, HKDF, PKCS7, X25519, Ed25519, Token}

hex = fn data -> Base.encode16(data, case: :lower) end

IO.puts("=== HASH FIXTURES ===")
test_inputs = [
  {"empty", <<>>},
  {"hello", "hello"},
  {"rns", "Reticulum Network Stack"},
  {"range256", :binary.list_to_bin(Enum.to_list(0..255))},
  {"zeros32", :binary.copy(<<0>>, 32)},
  {"ff64", :binary.copy(<<0xFF>>, 64)},
]

for {name, data} <- test_inputs do
  sha256 = Hashes.sha256(data) |> hex.()
  trunc = Hashes.truncated_hash(data) |> hex.()
  IO.puts("#{name}: sha256=#{sha256}")
  IO.puts("#{name}: trunc=#{trunc}")
end

IO.puts("\n=== PKCS7 FIXTURES ===")
pkcs7_inputs = [
  {"empty", <<>>},
  {"A", "A"},
  {"AB", "AB"},
  {"15bytes", "ABCDEFGHIJKLMNO"},
  {"16bytes", "ABCDEFGHIJKLMNOP"},
  {"31bytes", :binary.list_to_bin(Enum.to_list(0..30))},
]

for {name, data} <- pkcs7_inputs do
  padded = PKCS7.pad(data) |> hex.()
  IO.puts("#{name}: padded=#{padded}")
end

IO.puts("\n=== HMAC FIXTURES ===")
hmac_tests = [
  {"test1", "key", "data"},
  {"test2", :binary.copy(<<0x0B>>, 20), "Hi There"},
  {"test3", :binary.list_to_bin(Enum.to_list(0..31)), :binary.list_to_bin(Enum.to_list(0..63))},
]

for {name, key, data} <- hmac_tests do
  digest = HMAC.digest(key, data) |> hex.()
  IO.puts("#{name}: hmac=#{digest}")
end

IO.puts("\n=== HKDF FIXTURES ===")
hkdf_tests = [
  {"rfc5869_1", :binary.copy(<<0x0B>>, 22), 42, :binary.list_to_bin(Enum.to_list(0..12)), :binary.list_to_bin(Enum.to_list(0xF0..0xF9))},
  {"rfc5869_2", :binary.list_to_bin(Enum.to_list(0..0x4F)), 82, :binary.list_to_bin(Enum.to_list(0x60..0xA0)), :binary.list_to_bin(Enum.to_list(0xB0..0xDF))},
  {"rfc5869_3", :binary.copy(<<0x0B>>, 22), 42, nil, nil},
  {"rns_pattern", :binary.copy(<<0xAA>>, 32), 64, :binary.copy(<<0xBB>>, 16), nil},
]

for {name, ikm, length, salt, info} <- hkdf_tests do
  derived = HKDF.derive_key(ikm, length, salt, info) |> hex.()
  IO.puts("#{name}: derived=#{derived}")
end

IO.puts("\n=== X25519 FIXTURES ===")
prv_a_bytes = :crypto.hash(:sha256, "x25519_key_a")
prv_b_bytes = :crypto.hash(:sha256, "x25519_key_b")

key_a = X25519.from_private_bytes(prv_a_bytes)
key_b = X25519.from_private_bytes(prv_b_bytes)
pub_a = X25519.public_key(key_a) |> hex.()
pub_b = X25519.public_key(key_b) |> hex.()
shared = X25519.exchange(key_a, X25519.public_key(key_b)) |> hex.()
IO.puts("prv_a=#{hex.(prv_a_bytes)}")
IO.puts("pub_a=#{pub_a}")
IO.puts("prv_b=#{hex.(prv_b_bytes)}")
IO.puts("pub_b=#{pub_b}")
IO.puts("shared=#{shared}")

IO.puts("\n=== ED25519 FIXTURES ===")
ed_prv1 = :crypto.hash(:sha256, "ed25519_key_1")
ed_key1 = Ed25519.from_private_bytes(ed_prv1)
ed_pub1 = Ed25519.public_key(ed_key1) |> hex.()
sig1 = Ed25519.sign(ed_key1, "test") |> hex.()
sig_empty = Ed25519.sign(ed_key1, <<>>) |> hex.()
sig_rns = Ed25519.sign(ed_key1, "Reticulum") |> hex.()

IO.puts("ed_prv1=#{hex.(ed_prv1)}")
IO.puts("ed_pub1=#{ed_pub1}")
IO.puts("sig_test=#{sig1}")
IO.puts("sig_empty=#{sig_empty}")
IO.puts("sig_rns=#{sig_rns}")

IO.puts("\n=== IDENTITY FIXTURES ===")
prv_bytes1 = :binary.list_to_bin(Enum.to_list(0..63))
prv_bytes2 = :crypto.hash(:sha256, "test_key_pair_2") <> :crypto.hash(:sha256, "test_sign_pair_2")
prv_bytes3 = :binary.copy(<<0x42>>, 64)

for {name, prv} <- [{"id1", prv_bytes1}, {"id2", prv_bytes2}, {"id3", prv_bytes3}] do
  id = RNS.Identity.from_bytes(prv)
  pub = RNS.Identity.public_key(id) |> hex.()
  hash = id.hash |> hex.()
  IO.puts("#{name}: pub=#{pub}")
  IO.puts("#{name}: hash=#{hash}")
end

IO.puts("\n=== DESTINATION HASH FIXTURES ===")
id1 = RNS.Identity.from_bytes(prv_bytes1)

dest_configs = [
  {"test_app", []},
  {"test_app", ["aspect1"]},
  {"test_app", ["aspect1", "aspect2"]},
  {"myapp", ["echo", "request"]},
  {"rns_ex", ["compatibility", "test", "vectors"]},
]

for {app_name, aspects} <- dest_configs do
  name_hash = RNS.Destination.compute_name_hash(app_name, aspects) |> hex.()
  single_hash = RNS.Destination.compute_hash(id1, app_name, aspects) |> hex.()
  plain_hash = RNS.Destination.compute_hash(nil, app_name, aspects) |> hex.()
  name_str = RNS.Destination.expand_name(nil, app_name, aspects)
  IO.puts("dest(#{name_str}): name_hash=#{name_hash} single=#{single_hash} plain=#{plain_hash}")
end

IO.puts("\n=== AES FIXTURES ===")
aes_tests = [
  {"test1", :binary.copy(<<0x01>>, 32), :binary.copy(<<0x02>>, 16), "Hello AES-256-CBC!"},
  {"test2", :binary.list_to_bin(Enum.to_list(0..31)), :binary.list_to_bin(Enum.to_list(0..15)), :binary.list_to_bin(Enum.to_list(0..47))},
  {"test3", :binary.copy(<<0xFF>>, 32), :binary.copy(<<0x00>>, 16), <<>>},
]

for {name, key, iv, plaintext} <- aes_tests do
  padded = PKCS7.pad(plaintext)
  ciphertext = RNS.Cryptography.AES.encrypt(padded, key, iv) |> hex.()
  IO.puts("#{name}: ct=#{ciphertext}")
end

IO.puts("\n=== ANNOUNCE FIXTURES ===")
id_announce = RNS.Identity.from_bytes(prv_bytes1)

announce_configs = [
  {"test_app", ["echo"], <<0xDE, 0xAD, 0xBE, 0xEF, 0x42>> <> <<0x00, 0x00, 0x00, 0x00, 0x65, 0x53, 0x60, 0x00::size(24)>>, nil},
]

for {app_name, aspects, random_hash, app_data} <- announce_configs do
  name_str = app_name <> "." <> Enum.join(aspects, ".")
  name_hash = RNS.Identity.full_hash(name_str) |> binary_part(0, 10)
  addr_material = name_hash <> id_announce.hash
  dest_hash = RNS.Identity.full_hash(addr_material) |> binary_part(0, 16)
  pub_key = RNS.Identity.public_key(id_announce)
  signed_data = dest_hash <> pub_key <> name_hash <> random_hash
  signed_data = if app_data, do: signed_data <> app_data, else: signed_data
  signature = RNS.Identity.sign(id_announce, signed_data)
  announce_data = pub_key <> name_hash <> random_hash <> signature
  announce_data = if app_data, do: announce_data <> app_data, else: announce_data

  IO.puts("announce: dest_hash=#{hex.(dest_hash)}")
  IO.puts("announce: name_hash=#{hex.(name_hash)}")
  IO.puts("announce: signed_data=#{hex.(signed_data)}")
  IO.puts("announce: signature=#{hex.(signature)}")
  IO.puts("announce: announce_data_len=#{byte_size(announce_data)}")
end

IO.puts("\nDone!")
