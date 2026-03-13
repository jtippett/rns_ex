# Crypto operations benchmark
# Run: mix run benchmarks/crypto_bench.exs

alias RNS.Cryptography.{Hashes, HMAC, HKDF, AES, PKCS7, X25519, Ed25519, Token}

# --- Test data ---
small_data = :crypto.strong_rand_bytes(64)
medium_data = :crypto.strong_rand_bytes(1024)
large_data = :crypto.strong_rand_bytes(65_536)

aes_key = :crypto.strong_rand_bytes(32)
aes_iv = :crypto.strong_rand_bytes(16)
aes_padded_small = PKCS7.pad(small_data)
aes_padded_medium = PKCS7.pad(medium_data)
aes_padded_large = PKCS7.pad(large_data)
aes_ct_small = AES.encrypt(aes_padded_small, aes_key, aes_iv)
aes_ct_medium = AES.encrypt(aes_padded_medium, aes_key, aes_iv)
aes_ct_large = AES.encrypt(aes_padded_large, aes_key, aes_iv)

hmac_key = :crypto.strong_rand_bytes(32)

hkdf_ikm = :crypto.strong_rand_bytes(32)
hkdf_salt = :crypto.strong_rand_bytes(16)
hkdf_info = "RNS benchmark context"

x25519_alice = X25519.generate_keypair()
x25519_bob = X25519.generate_keypair()

ed25519_kp = Ed25519.generate_keypair()
ed25519_sig = Ed25519.sign(ed25519_kp, medium_data)

token_key = Token.generate_key()
token = Token.new(token_key)
token_ct_small = Token.encrypt(token, small_data)
token_ct_medium = Token.encrypt(token, medium_data)

IO.puts("\n=== RNS Cryptography Benchmarks ===\n")

# --- Hashing ---
Benchee.run(
  %{
    "SHA-256 (64 B)" => fn -> Hashes.sha256(small_data) end,
    "SHA-256 (1 KB)" => fn -> Hashes.sha256(medium_data) end,
    "SHA-256 (64 KB)" => fn -> Hashes.sha256(large_data) end,
    "SHA-512 (64 B)" => fn -> Hashes.sha512(small_data) end,
    "SHA-512 (1 KB)" => fn -> Hashes.sha512(medium_data) end,
    "SHA-512 (64 KB)" => fn -> Hashes.sha512(large_data) end,
    "Truncated hash (64 B)" => fn -> Hashes.truncated_hash(small_data) end
  },
  title: "Hash Functions",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- HMAC ---
Benchee.run(
  %{
    "HMAC-SHA256 (64 B)" => fn -> HMAC.digest(hmac_key, small_data) end,
    "HMAC-SHA256 (1 KB)" => fn -> HMAC.digest(hmac_key, medium_data) end,
    "HMAC-SHA256 (64 KB)" => fn -> HMAC.digest(hmac_key, large_data) end,
    "HMAC-SHA512 (1 KB)" => fn -> HMAC.digest(hmac_key, medium_data, :sha512) end
  },
  title: "HMAC",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- HKDF ---
Benchee.run(
  %{
    "HKDF derive 32 B" => fn -> HKDF.derive_key(hkdf_ikm, 32, hkdf_salt, hkdf_info) end,
    "HKDF derive 64 B" => fn -> HKDF.derive_key(hkdf_ikm, 64, hkdf_salt, hkdf_info) end,
    "HKDF derive 128 B" => fn -> HKDF.derive_key(hkdf_ikm, 128, hkdf_salt, hkdf_info) end
  },
  title: "HKDF Key Derivation",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- PKCS7 ---
Benchee.run(
  %{
    "PKCS7 pad (64 B)" => fn -> PKCS7.pad(small_data) end,
    "PKCS7 pad (1 KB)" => fn -> PKCS7.pad(medium_data) end,
    "PKCS7 unpad (64 B)" => fn -> PKCS7.unpad(aes_padded_small) end,
    "PKCS7 unpad (1 KB)" => fn -> PKCS7.unpad(aes_padded_medium) end
  },
  title: "PKCS7 Padding",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- AES-256-CBC ---
Benchee.run(
  %{
    "AES-256-CBC encrypt (64 B)" => fn -> AES.encrypt(aes_padded_small, aes_key, aes_iv) end,
    "AES-256-CBC encrypt (1 KB)" => fn -> AES.encrypt(aes_padded_medium, aes_key, aes_iv) end,
    "AES-256-CBC encrypt (64 KB)" => fn -> AES.encrypt(aes_padded_large, aes_key, aes_iv) end,
    "AES-256-CBC decrypt (64 B)" => fn -> AES.decrypt(aes_ct_small, aes_key, aes_iv) end,
    "AES-256-CBC decrypt (1 KB)" => fn -> AES.decrypt(aes_ct_medium, aes_key, aes_iv) end,
    "AES-256-CBC decrypt (64 KB)" => fn -> AES.decrypt(aes_ct_large, aes_key, aes_iv) end
  },
  title: "AES-256-CBC",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- X25519 ---
Benchee.run(
  %{
    "X25519 keypair generation" => fn -> X25519.generate_keypair() end,
    "X25519 from_private_bytes" => fn ->
      X25519.from_private_bytes(:crypto.strong_rand_bytes(32))
    end,
    "X25519 ECDH exchange" => fn -> X25519.exchange(x25519_alice, x25519_bob.public_key) end
  },
  title: "X25519 Key Exchange",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Ed25519 ---
Benchee.run(
  %{
    "Ed25519 keypair generation" => fn -> Ed25519.generate_keypair() end,
    "Ed25519 sign (64 B)" => fn -> Ed25519.sign(ed25519_kp, small_data) end,
    "Ed25519 sign (1 KB)" => fn -> Ed25519.sign(ed25519_kp, medium_data) end,
    "Ed25519 verify (1 KB)" => fn -> Ed25519.verify(ed25519_sig, medium_data, ed25519_kp) end
  },
  title: "Ed25519 Signatures",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Token (authenticated encryption) ---
Benchee.run(
  %{
    "Token encrypt (64 B)" => fn -> Token.encrypt(token, small_data) end,
    "Token encrypt (1 KB)" => fn -> Token.encrypt(token, medium_data) end,
    "Token decrypt (64 B)" => fn -> Token.decrypt(token, token_ct_small) end,
    "Token decrypt (1 KB)" => fn -> Token.decrypt(token, token_ct_medium) end,
    "Token key generation" => fn -> Token.generate_key() end
  },
  title: "Token Authenticated Encryption",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)
