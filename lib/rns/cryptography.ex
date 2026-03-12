defmodule RNS.Cryptography do
  @moduledoc """
  Cryptography module for RNS.

  Re-exports all cryptographic primitives used by the Reticulum Network Stack:

  - `RNS.Cryptography.Hashes` — SHA-256, SHA-512, truncated hash
  - `RNS.Cryptography.HMAC` — HMAC-SHA256/512
  - `RNS.Cryptography.HKDF` — HKDF key derivation (RFC 5869)
  - `RNS.Cryptography.PKCS7` — PKCS7 padding
  - `RNS.Cryptography.AES` — AES-256-CBC encryption
  - `RNS.Cryptography.X25519` — X25519 ECDH key exchange
  - `RNS.Cryptography.Ed25519` — Ed25519 digital signatures
  - `RNS.Cryptography.Token` — Fernet-like authenticated encryption

  Matches `python/RNS/Cryptography/__init__.py`.
  """
end
