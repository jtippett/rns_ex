# Packet encoding/decoding benchmark
# Run: mix run benchmarks/packet_bench.exs

alias RNS.Packet
alias RNS.Identity

# --- Setup ---
identity = Identity.new()

# Destination-like map for PLAIN type (no encryption during pack)
plain_dest = %{
  hash: :crypto.strong_rand_bytes(16),
  type: 0x02,
  link_id: nil,
  mtu: nil
}

# Destination-like map for SINGLE type with encryption
single_dest = %{
  hash: Identity.hash(identity),
  type: 0x00,
  link_id: nil,
  mtu: nil,
  encrypt: fn data -> Identity.encrypt(identity, data) end,
  latest_ratchet_id: nil
}

small_payload = :crypto.strong_rand_bytes(32)
medium_payload = :crypto.strong_rand_bytes(256)
max_payload = :crypto.strong_rand_bytes(464)

# Pre-build packets for packing
plain_pkt_small = Packet.new(plain_dest, small_payload, packet_type: Packet.data(), create_receipt: false)
plain_pkt_medium = Packet.new(plain_dest, medium_payload, packet_type: Packet.data(), create_receipt: false)
plain_pkt_max = Packet.new(plain_dest, max_payload, packet_type: Packet.data(), create_receipt: false)

# Pre-pack for unpacking benchmarks
packed_small = Packet.pack(plain_pkt_small)
packed_medium = Packet.pack(plain_pkt_medium)
packed_max = Packet.pack(plain_pkt_max)

# Announce packet (uses announce format)
announce_data = identity.pub_bytes <> identity.sig_pub_bytes <>
  :crypto.strong_rand_bytes(10) <> :crypto.strong_rand_bytes(10) <>
  :crypto.strong_rand_bytes(64)
announce_pkt = Packet.new(plain_dest, announce_data, packet_type: Packet.announce(), create_receipt: false)

IO.puts("\n=== RNS Packet Benchmarks ===\n")

# --- Packet construction ---
Benchee.run(
  %{
    "Packet.new PLAIN (32 B)" => fn -> Packet.new(plain_dest, small_payload, create_receipt: false) end,
    "Packet.new PLAIN (256 B)" => fn -> Packet.new(plain_dest, medium_payload, create_receipt: false) end,
    "Packet.new PLAIN (464 B)" => fn -> Packet.new(plain_dest, max_payload, create_receipt: false) end
  },
  title: "Packet Construction",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Packet packing (serialization) ---
Benchee.run(
  %{
    "Packet.pack PLAIN (32 B)" => fn -> Packet.pack(plain_pkt_small) end,
    "Packet.pack PLAIN (256 B)" => fn -> Packet.pack(plain_pkt_medium) end,
    "Packet.pack PLAIN (464 B)" => fn -> Packet.pack(plain_pkt_max) end,
    "Packet.pack ANNOUNCE" => fn -> Packet.pack(announce_pkt) end
  },
  title: "Packet Packing (Serialization)",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Packet unpacking (deserialization) ---
Benchee.run(
  %{
    "Packet.unpack (32 B payload)" => fn ->
      Packet.new(nil, packed_small.raw) |> Packet.unpack()
    end,
    "Packet.unpack (256 B payload)" => fn ->
      Packet.new(nil, packed_medium.raw) |> Packet.unpack()
    end,
    "Packet.unpack (464 B payload)" => fn ->
      Packet.new(nil, packed_max.raw) |> Packet.unpack()
    end
  },
  title: "Packet Unpacking (Deserialization)",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Pack/unpack roundtrip ---
Benchee.run(
  %{
    "Pack + unpack roundtrip (32 B)" => fn ->
      packed = Packet.pack(plain_pkt_small)
      Packet.new(nil, packed.raw) |> Packet.unpack()
    end,
    "Pack + unpack roundtrip (256 B)" => fn ->
      packed = Packet.pack(plain_pkt_medium)
      Packet.new(nil, packed.raw) |> Packet.unpack()
    end
  },
  title: "Pack/Unpack Roundtrip",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Packet hashing ---
Benchee.run(
  %{
    "Packet.hash (32 B)" => fn -> Packet.hash(packed_small) end,
    "Packet.hash (256 B)" => fn -> Packet.hash(packed_medium) end,
    "Packet.hash (464 B)" => fn -> Packet.hash(packed_max) end
  },
  title: "Packet Hashing",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Identity encrypt/decrypt (used in encrypted packet paths) ---
plaintext_small = :crypto.strong_rand_bytes(32)
plaintext_medium = :crypto.strong_rand_bytes(256)
ct_small = Identity.encrypt(identity, plaintext_small)
ct_medium = Identity.encrypt(identity, plaintext_medium)

Benchee.run(
  %{
    "Identity.encrypt (32 B)" => fn -> Identity.encrypt(identity, plaintext_small) end,
    "Identity.encrypt (256 B)" => fn -> Identity.encrypt(identity, plaintext_medium) end,
    "Identity.decrypt (32 B)" => fn -> Identity.decrypt(identity, ct_small) end,
    "Identity.decrypt (256 B)" => fn -> Identity.decrypt(identity, ct_medium) end,
    "Identity.sign (256 B)" => fn -> Identity.sign(identity, plaintext_medium) end,
    "Identity.validate (256 B)" => fn ->
      sig = Identity.sign(identity, plaintext_medium)
      Identity.validate(identity, sig, plaintext_medium)
    end
  },
  title: "Identity Crypto Operations",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)
