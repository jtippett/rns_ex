# Link establishment benchmark
# Run: mix run benchmarks/link_bench.exs
#
# Benchmarks the cryptographic operations involved in link establishment:
# - ECDH key generation and exchange
# - HKDF key derivation
# - Link handshake (combined ECDH + HKDF)
# - Link encrypt/decrypt with derived keys

alias RNS.Cryptography.{X25519, Ed25519, HKDF, Token}
alias RNS.Link
alias RNS.Link.{CryptoState, PeerState, Stats}
alias RNS.Identity

# --- Setup ---
# Simulate initiator and responder identities
initiator_identity = Identity.new()
responder_identity = Identity.new()

# Simulate link ID (truncated hash of public keys)
link_id = :crypto.strong_rand_bytes(16)

# Pre-generate keypairs for benchmarking exchange-only
initiator_prv = X25519.generate_keypair()
responder_prv = X25519.generate_keypair()

# Shared key from ECDH for key derivation benchmarks
shared_key = X25519.exchange(initiator_prv, responder_prv.public_key)

# Build link structs for handshake benchmarking
build_pending_link = fn ->
  prv = X25519.generate_keypair()

  %Link{
    link_id: link_id,
    status: Link.pending(),
    initiator: true,
    callbacks: %Link.Callbacks{},
    crypto: %CryptoState{
      prv: prv,
      pub_bytes: X25519.public_key(prv),
      sig_prv: Ed25519.from_private_bytes(initiator_identity.sig_prv_bytes),
      sig_pub_bytes: initiator_identity.sig_pub_bytes,
      mode: Link.mode_aes256_cbc()
    },
    peer: %PeerState{
      peer_pub_bytes: responder_identity.pub_bytes,
      peer_sig_pub_bytes: responder_identity.sig_pub_bytes
    },
    stats: %Stats{}
  }
end

# Pre-build a pending link for handshake
pending_link = build_pending_link.()

# Pre-handshake a link for encrypt/decrypt benchmarks
{:ok, handshaken_link} = Link.handshake(pending_link)

# Build token from derived key
token_256 = Token.new(handshaken_link.crypto.derived_key)

# Test data for link encryption
small_data = :crypto.strong_rand_bytes(32)
medium_data = :crypto.strong_rand_bytes(256)
ct_small = Token.encrypt(token_256, small_data)
ct_medium = Token.encrypt(token_256, medium_data)

IO.puts("\n=== RNS Link Establishment Benchmarks ===\n")

# --- Key generation (initiator side) ---
Benchee.run(
  %{
    "X25519 keypair (ephemeral)" => fn -> X25519.generate_keypair() end,
    "Ed25519 from_private_bytes" => fn ->
      Ed25519.from_private_bytes(initiator_identity.sig_prv_bytes)
    end,
    "Identity.new (full keypair)" => fn -> Identity.new() end
  },
  title: "Key Generation",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- ECDH exchange + key derivation ---
Benchee.run(
  %{
    "ECDH exchange only" => fn ->
      X25519.exchange(initiator_prv, responder_prv.public_key)
    end,
    "HKDF derive 64 B (AES-256)" => fn ->
      HKDF.derive_key(shared_key, 64, link_id, nil)
    end,
    "HKDF derive 32 B (AES-128)" => fn ->
      HKDF.derive_key(shared_key, 32, link_id, nil)
    end,
    "ECDH + HKDF (full exchange)" => fn ->
      sk = X25519.exchange(initiator_prv, responder_prv.public_key)
      HKDF.derive_key(sk, 64, link_id, nil)
    end
  },
  title: "Key Exchange + Derivation",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Link handshake (ECDH + HKDF in Link context) ---
Benchee.run(
  %{
    "Link.handshake (AES-256)" => fn ->
      link = build_pending_link.()
      Link.handshake(link)
    end,
    "Full link setup (keygen + handshake)" => fn ->
      prv = X25519.generate_keypair()

      link = %Link{
        link_id: link_id,
        status: Link.pending(),
        initiator: true,
        callbacks: %Link.Callbacks{},
        crypto: %CryptoState{
          prv: prv,
          pub_bytes: X25519.public_key(prv),
          sig_prv: Ed25519.from_private_bytes(initiator_identity.sig_prv_bytes),
          sig_pub_bytes: initiator_identity.sig_pub_bytes,
          mode: Link.mode_aes256_cbc()
        },
        peer: %PeerState{
          peer_pub_bytes: responder_identity.pub_bytes,
          peer_sig_pub_bytes: responder_identity.sig_pub_bytes
        },
        stats: %Stats{}
      }

      Link.handshake(link)
    end
  },
  title: "Link Handshake",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Link data encryption/decryption (post-handshake) ---
Benchee.run(
  %{
    "Link encrypt (32 B)" => fn -> Token.encrypt(token_256, small_data) end,
    "Link encrypt (256 B)" => fn -> Token.encrypt(token_256, medium_data) end,
    "Link decrypt (32 B)" => fn -> Token.decrypt(token_256, ct_small) end,
    "Link decrypt (256 B)" => fn -> Token.decrypt(token_256, ct_medium) end
  },
  title: "Link Data Encryption (Post-Handshake)",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Ed25519 signing for link proofs ---
proof_data = link_id <> initiator_prv.public_key <> responder_prv.public_key
ed_kp = Ed25519.from_private_bytes(initiator_identity.sig_prv_bytes)
proof_sig = Ed25519.sign(ed_kp, proof_data)

Benchee.run(
  %{
    "Sign link proof" => fn -> Ed25519.sign(ed_kp, proof_data) end,
    "Verify link proof" => fn ->
      Ed25519.verify(proof_sig, proof_data, ed_kp)
    end,
    "Sign + verify roundtrip" => fn ->
      sig = Ed25519.sign(ed_kp, proof_data)
      Ed25519.verify(sig, proof_data, ed_kp)
    end
  },
  title: "Link Proof Signing",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)
