#!/usr/bin/env python3
"""
Generate deterministic cross-language compatibility test fixtures for RNS.

This script uses the Python RNS implementation to generate test vectors
that the Elixir implementation must match exactly (byte-identical outputs).

Usage:
    python3 test/fixtures/generate_fixtures.py

Outputs JSON to test/fixtures/protocol_compatibility.json
"""

import sys
import os
import json
import hashlib
import struct
import time

# Add the python RNS source to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'python'))

import RNS
from RNS.Cryptography import X25519, Ed25519, Token, HKDF, PKCS7
from RNS.Cryptography.Hashes import sha256, sha512, truncated_hash

def to_hex(data):
    """Convert bytes to hex string."""
    if data is None:
        return None
    return data.hex()

def generate_fixtures():
    fixtures = {}

    # =========================================================================
    # 1. HASH COMPUTATION
    # =========================================================================
    print("Generating hash fixtures...")

    # Known test inputs
    test_inputs = [
        b"",
        b"hello",
        b"Reticulum Network Stack",
        bytes(range(256)),
        b"\x00" * 32,
        b"\xff" * 64,
    ]

    hash_fixtures = []
    for inp in test_inputs:
        hash_fixtures.append({
            "input": to_hex(inp),
            "sha256": to_hex(sha256(inp)),
            "sha512": to_hex(sha512(inp)),
            "truncated_hash": to_hex(truncated_hash(inp)),
            "full_hash": to_hex(RNS.Identity.full_hash(inp)),
        })
    fixtures["hashes"] = hash_fixtures

    # =========================================================================
    # 2. IDENTITY KEY OPERATIONS
    # =========================================================================
    print("Generating identity fixtures...")

    # Use deterministic key material (64 bytes: 32 X25519 + 32 Ed25519)
    # These are known private key bytes
    known_prv_bytes_list = [
        # Key pair 1: simple deterministic bytes
        bytes([i % 256 for i in range(64)]),
        # Key pair 2: different bytes
        hashlib.sha256(b"test_key_pair_2").digest() + hashlib.sha256(b"test_sign_pair_2").digest(),
        # Key pair 3: all 0x42
        bytes([0x42] * 64),
    ]

    identity_fixtures = []
    for idx, prv_bytes in enumerate(known_prv_bytes_list):
        identity = RNS.Identity(create_keys=False)
        identity.load_private_key(prv_bytes)

        pub_key = identity.get_public_key()
        id_hash = identity.hash
        hexhash = identity.hexhash

        # Sign a known message
        test_message = f"test message {idx}".encode("utf-8")
        signature = identity.sign(test_message)

        # Compute name hash (used in destination hash computation)
        app_name = "test_app"
        aspects = ["aspect1", "aspect2"]

        identity_fixtures.append({
            "private_key": to_hex(prv_bytes),
            "public_key": to_hex(pub_key),
            "x25519_pub": to_hex(identity.pub_bytes),
            "ed25519_pub": to_hex(identity.sig_pub_bytes),
            "identity_hash": to_hex(id_hash),
            "hexhash": hexhash,
            "test_message": to_hex(test_message),
            "signature": to_hex(signature),
        })
    fixtures["identities"] = identity_fixtures

    # =========================================================================
    # 3. DESTINATION HASH COMPUTATION
    # =========================================================================
    print("Generating destination hash fixtures...")

    dest_fixtures = []

    # Use the first identity for destination tests
    identity = RNS.Identity(create_keys=False)
    identity.load_private_key(known_prv_bytes_list[0])

    # Test various app_name / aspects combinations
    dest_configs = [
        ("test_app", []),
        ("test_app", ["aspect1"]),
        ("test_app", ["aspect1", "aspect2"]),
        ("myapp", ["echo", "request"]),
        ("rns_ex", ["compatibility", "test", "vectors"]),
    ]

    for app_name, aspects in dest_configs:
        # Compute name hash manually
        if aspects:
            name_string = app_name + "." + ".".join(aspects)
        else:
            name_string = app_name
        name_hash = RNS.Identity.full_hash(name_string.encode("utf-8"))[:RNS.Identity.NAME_HASH_LENGTH//8]

        # Compute destination hash for SINGLE type (with identity)
        addr_hash_material = name_hash + identity.hash
        dest_hash = RNS.Identity.full_hash(addr_hash_material)[:RNS.Reticulum.TRUNCATED_HASHLENGTH//8]

        # Compute destination hash for PLAIN type (no identity)
        plain_hash = RNS.Identity.full_hash(name_hash)[:RNS.Reticulum.TRUNCATED_HASHLENGTH//8]

        dest_fixtures.append({
            "app_name": app_name,
            "aspects": aspects,
            "name_string": name_string,
            "name_hash": to_hex(name_hash),
            "identity_hash": to_hex(identity.hash),
            "single_dest_hash": to_hex(dest_hash),
            "plain_dest_hash": to_hex(plain_hash),
        })
    fixtures["destinations"] = dest_fixtures

    # =========================================================================
    # 4. HKDF KEY DERIVATION
    # =========================================================================
    print("Generating HKDF fixtures...")

    hkdf_fixtures = []

    # RFC 5869 test vectors and RNS-specific scenarios
    hkdf_configs = [
        # (ikm, length, salt, info, description)
        (b"\x0b" * 22, 42, b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c", b"\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9", "RFC 5869 Test Case 1"),
        (bytes(range(0x50)), 82, bytes(range(0x60, 0xa1)), bytes(range(0xb0, 0xe0)), "RFC 5869 Test Case 2"),
        (b"\x0b" * 22, 42, None, None, "RFC 5869 Test Case 3 (no salt, no info)"),
        # RNS-specific: 32-byte shared key, 64-byte output, 16-byte salt (identity hash)
        (b"\xaa" * 32, 64, b"\xbb" * 16, None, "RNS Identity decrypt pattern"),
        (hashlib.sha256(b"shared_key").digest(), 64, hashlib.sha256(b"identity")[:16].digest()[:16], None, "RNS typical ECDH derived key"),
    ]

    for ikm, length, salt, info, desc in hkdf_configs:
        derived = RNS.Cryptography.hkdf(
            length=length,
            derive_from=ikm,
            salt=salt,
            context=info
        )
        hkdf_fixtures.append({
            "description": desc,
            "ikm": to_hex(ikm),
            "length": length,
            "salt": to_hex(salt),
            "info": to_hex(info),
            "derived_key": to_hex(derived),
        })
    fixtures["hkdf"] = hkdf_fixtures

    # =========================================================================
    # 5. TOKEN ENCRYPT/DECRYPT (deterministic with known IV)
    # =========================================================================
    print("Generating Token fixtures...")

    token_fixtures = []

    # We can't make Token.encrypt deterministic easily since it uses random IV.
    # Instead, test the structure: given known key, encrypt with Python, provide
    # the ciphertext for Elixir to decrypt. And verify HMAC computation.

    # Test HMAC computation with known data
    known_keys = [
        bytes([0x01] * 64),  # 64-byte key for AES-256-CBC
        bytes([0x02] * 32),  # 32-byte key for AES-128-CBC
    ]

    known_plaintexts = [
        b"Hello, Reticulum!",
        b"",
        b"A" * 100,
        bytes(range(256)),
    ]

    for key in known_keys:
        token = Token.Token(key)
        for plaintext in known_plaintexts:
            ciphertext = token.encrypt(plaintext)
            # Verify it decrypts correctly
            decrypted = token.decrypt(ciphertext)
            assert decrypted == plaintext, f"Roundtrip failed for key={key.hex()[:8]}..."

            # Extract parts for verification
            iv = ciphertext[:16]
            ct_body = ciphertext[16:-32]
            hmac_val = ciphertext[-32:]

            token_fixtures.append({
                "key": to_hex(key),
                "key_size": len(key),
                "plaintext": to_hex(plaintext),
                "ciphertext": to_hex(ciphertext),
                "iv": to_hex(iv),
                "encrypted_body": to_hex(ct_body),
                "hmac": to_hex(hmac_val),
            })
    fixtures["tokens"] = token_fixtures

    # =========================================================================
    # 6. PKCS7 PADDING
    # =========================================================================
    print("Generating PKCS7 fixtures...")

    pkcs7_fixtures = []
    test_data = [
        b"",
        b"A",
        b"AB",
        b"ABCDEFGHIJKLMNO",  # 15 bytes
        b"ABCDEFGHIJKLMNOP",  # 16 bytes (full block)
        bytes(range(31)),
    ]

    for data in test_data:
        padded = PKCS7.PKCS7.pad(data)
        pkcs7_fixtures.append({
            "input": to_hex(data),
            "padded": to_hex(padded),
            "block_size": 16,
        })
    fixtures["pkcs7"] = pkcs7_fixtures

    # =========================================================================
    # 7. X25519 ECDH KEY EXCHANGE
    # =========================================================================
    print("Generating X25519 fixtures...")

    x25519_fixtures = []

    # Use deterministic key pairs
    prv_a_bytes = hashlib.sha256(b"x25519_key_a").digest()
    prv_b_bytes = hashlib.sha256(b"x25519_key_b").digest()

    key_a = X25519.X25519PrivateKey.from_private_bytes(prv_a_bytes)
    key_b = X25519.X25519PrivateKey.from_private_bytes(prv_b_bytes)

    pub_a = key_a.public_key()
    pub_b = key_b.public_key()

    shared_ab = key_a.exchange(pub_b)
    shared_ba = key_b.exchange(pub_a)
    assert shared_ab == shared_ba, "ECDH exchange mismatch"

    x25519_fixtures.append({
        "private_a": to_hex(key_a.private_bytes()),
        "public_a": to_hex(pub_a.public_bytes()),
        "private_b": to_hex(key_b.private_bytes()),
        "public_b": to_hex(pub_b.public_bytes()),
        "shared_secret": to_hex(shared_ab),
    })
    fixtures["x25519"] = x25519_fixtures

    # =========================================================================
    # 8. ED25519 SIGNATURES
    # =========================================================================
    print("Generating Ed25519 fixtures...")

    ed25519_fixtures = []

    ed_prv_bytes_list = [
        hashlib.sha256(b"ed25519_key_1").digest(),
        hashlib.sha256(b"ed25519_key_2").digest(),
    ]

    for ed_prv_bytes in ed_prv_bytes_list:
        ed_key = Ed25519.Ed25519PrivateKey.from_private_bytes(ed_prv_bytes)
        ed_pub = ed_key.public_key()

        messages = [b"test", b"", b"Reticulum", bytes(range(100))]
        sigs = []
        for msg in messages:
            sig = ed_key.sign(msg)
            sigs.append({
                "message": to_hex(msg),
                "signature": to_hex(sig),
            })

        ed25519_fixtures.append({
            "private_key": to_hex(ed_prv_bytes),
            "public_key": to_hex(ed_pub.public_bytes()),
            "signatures": sigs,
        })
    fixtures["ed25519"] = ed25519_fixtures

    # =========================================================================
    # 9. IDENTITY ENCRYPT/DECRYPT
    # =========================================================================
    print("Generating identity encryption fixtures...")

    # Create two identities with known keys
    id_sender = RNS.Identity(create_keys=False)
    id_sender.load_private_key(known_prv_bytes_list[0])

    id_receiver = RNS.Identity(create_keys=False)
    id_receiver.load_private_key(known_prv_bytes_list[1])

    # Encrypt data from sender to receiver (uses receiver's public key)
    enc_fixtures = []
    enc_plaintexts = [
        b"Hello!",
        b"Cross-language compatibility test",
        bytes(range(200)),
    ]

    for pt in enc_plaintexts:
        ct = id_receiver.encrypt(pt)
        # Verify decryption
        dt = id_receiver.decrypt(ct)
        assert dt == pt, f"Roundtrip failed"

        # The ciphertext includes ephemeral public key (32 bytes) + token
        ephemeral_pub = ct[:32]
        token_data = ct[32:]

        enc_fixtures.append({
            "receiver_private_key": to_hex(known_prv_bytes_list[1]),
            "receiver_public_key": to_hex(id_receiver.get_public_key()),
            "receiver_hash": to_hex(id_receiver.hash),
            "plaintext": to_hex(pt),
            "ciphertext": to_hex(ct),
            "ephemeral_pub": to_hex(ephemeral_pub),
            "token_data": to_hex(token_data),
        })
    fixtures["identity_encryption"] = enc_fixtures

    # =========================================================================
    # 10. PACKET ENCODING
    # =========================================================================
    print("Generating packet encoding fixtures...")

    packet_fixtures = []

    # Test packet flags computation
    # Flags byte: header_type(2) | context_flag(1) | transport_type(1) | dest_type(2) | packet_type(2)
    flag_tests = [
        # (header_type, context_flag, transport_type, dest_type, packet_type)
        (0, 0, 0, 0, 0),   # All zeros
        (1, 0, 0, 0, 0),   # HEADER_2
        (0, 1, 0, 0, 0),   # context_flag set
        (0, 0, 1, 0, 0),   # transport
        (0, 0, 0, 1, 0),   # GROUP dest
        (0, 0, 0, 0, 1),   # ANNOUNCE type
        (0, 0, 0, 0, 2),   # LINKREQUEST type
        (0, 0, 0, 0, 3),   # PROOF type
        (1, 1, 1, 3, 3),   # All bits set (max values)
        (0, 0, 0, 0, 1),   # DATA=0x00 type, SINGLE=0x00 dest (common case)
    ]

    for ht, cf, tt, dt, pt in flag_tests:
        flags = (ht << 6) | (cf << 5) | (tt << 4) | (dt << 2) | pt
        packet_fixtures.append({
            "header_type": ht,
            "context_flag": cf,
            "transport_type": tt,
            "dest_type": dt,
            "packet_type": pt,
            "flags_byte": flags,
        })
    fixtures["packet_flags"] = packet_fixtures

    # Test packet header construction
    # HEADER_1: [flags:1][hops:1][dest_hash:16][context:1] = 19 bytes
    # HEADER_2: [flags:1][hops:1][transport_id:16][dest_hash:16][context:1] = 35 bytes
    header_tests = []

    dest_hash = bytes([0xAA] * 16)
    transport_id = bytes([0xBB] * 16)

    # HEADER_1 test
    flags_h1 = (0 << 6) | (0 << 5) | (0 << 4) | (0 << 2) | 0  # DATA, SINGLE, HEADER_1
    hops = 3
    context = 0x00
    header1 = bytes([flags_h1, hops]) + dest_hash + bytes([context])
    header_tests.append({
        "type": "HEADER_1",
        "flags": flags_h1,
        "hops": hops,
        "dest_hash": to_hex(dest_hash),
        "context": context,
        "header": to_hex(header1),
        "header_size": len(header1),
    })

    # HEADER_2 test
    flags_h2 = (1 << 6) | (0 << 5) | (1 << 4) | (0 << 2) | 0  # DATA, SINGLE, HEADER_2, TRANSPORT
    header2 = bytes([flags_h2, hops]) + transport_id + dest_hash + bytes([context])
    header_tests.append({
        "type": "HEADER_2",
        "flags": flags_h2,
        "hops": hops,
        "transport_id": to_hex(transport_id),
        "dest_hash": to_hex(dest_hash),
        "context": context,
        "header": to_hex(header2),
        "header_size": len(header2),
    })

    fixtures["packet_headers"] = header_tests

    # =========================================================================
    # 11. ANNOUNCE FORMAT
    # =========================================================================
    print("Generating announce format fixtures...")

    announce_fixtures = []

    id_announce = RNS.Identity(create_keys=False)
    id_announce.load_private_key(known_prv_bytes_list[0])

    # Build announce data manually (matching Destination.announce logic)
    app_name = "test_app"
    aspects_list = [["echo"], ["transfer", "large"]]

    for aspects in aspects_list:
        # Compute name hash
        name_string = app_name + "." + ".".join(aspects)
        name_hash = RNS.Identity.full_hash(name_string.encode("utf-8"))[:RNS.Identity.NAME_HASH_LENGTH//8]

        # Compute destination hash
        addr_hash_material = name_hash + id_announce.hash
        dest_hash = RNS.Identity.full_hash(addr_hash_material)[:RNS.Reticulum.TRUNCATED_HASHLENGTH//8]

        # Build announce signed data (without ratchet, without app_data)
        random_hash = bytes([0xDE, 0xAD, 0xBE, 0xEF, 0x42]) + int(1700000000).to_bytes(5, "big")
        pub_key = id_announce.get_public_key()

        signed_data = dest_hash + pub_key + name_hash + random_hash

        signature = id_announce.sign(signed_data)

        # Announce payload = pub_key + name_hash + random_hash + signature
        announce_data = pub_key + name_hash + random_hash + signature

        announce_fixtures.append({
            "app_name": app_name,
            "aspects": aspects,
            "name_string": name_string,
            "name_hash": to_hex(name_hash),
            "dest_hash": to_hex(dest_hash),
            "random_hash": to_hex(random_hash),
            "public_key": to_hex(pub_key),
            "signed_data": to_hex(signed_data),
            "signature": to_hex(signature),
            "announce_data": to_hex(announce_data),
            "identity_private_key": to_hex(known_prv_bytes_list[0]),
        })

    # With app_data
    aspects = ["echo"]
    name_string = app_name + "." + ".".join(aspects)
    name_hash = RNS.Identity.full_hash(name_string.encode("utf-8"))[:RNS.Identity.NAME_HASH_LENGTH//8]
    addr_hash_material = name_hash + id_announce.hash
    dest_hash = RNS.Identity.full_hash(addr_hash_material)[:RNS.Reticulum.TRUNCATED_HASHLENGTH//8]
    random_hash = bytes([0xCA, 0xFE, 0xBA, 0xBE, 0x01]) + int(1700000000).to_bytes(5, "big")
    pub_key = id_announce.get_public_key()
    app_data = b"Hello from Python RNS!"
    signed_data = dest_hash + pub_key + name_hash + random_hash + app_data
    signature = id_announce.sign(signed_data)
    announce_data = pub_key + name_hash + random_hash + signature + app_data

    announce_fixtures.append({
        "app_name": app_name,
        "aspects": ["echo"],
        "name_string": name_string,
        "name_hash": to_hex(name_hash),
        "dest_hash": to_hex(dest_hash),
        "random_hash": to_hex(random_hash),
        "public_key": to_hex(pub_key),
        "app_data": to_hex(app_data),
        "signed_data": to_hex(signed_data),
        "signature": to_hex(signature),
        "announce_data": to_hex(announce_data),
        "identity_private_key": to_hex(known_prv_bytes_list[0]),
    })

    fixtures["announces"] = announce_fixtures

    # =========================================================================
    # 12. CONSTANTS VERIFICATION
    # =========================================================================
    print("Generating constants fixtures...")

    fixtures["constants"] = {
        "MTU": RNS.Reticulum.MTU,
        "TRUNCATED_HASHLENGTH": RNS.Reticulum.TRUNCATED_HASHLENGTH,
        "HEADER_MINSIZE": RNS.Reticulum.HEADER_MINSIZE,
        "HEADER_MAXSIZE": RNS.Reticulum.HEADER_MAXSIZE,
        "MDU": RNS.Reticulum.MDU,
        "IFAC_MIN_SIZE": RNS.Reticulum.IFAC_MIN_SIZE,
        "RESOURCE_CACHE": RNS.Reticulum.RESOURCE_CACHE,
        "IDENTITY_KEYSIZE": RNS.Identity.KEYSIZE,
        "IDENTITY_HASHLENGTH": RNS.Identity.HASHLENGTH,
        "IDENTITY_NAME_HASH_LENGTH": RNS.Identity.NAME_HASH_LENGTH,
        "IDENTITY_RATCHETSIZE": RNS.Identity.RATCHETSIZE,
        "IDENTITY_TRUNCATED_HASHLENGTH": RNS.Identity.TRUNCATED_HASHLENGTH,
        "TOKEN_OVERHEAD": 48,
        "ANNOUNCE_CAP": RNS.Reticulum.ANNOUNCE_CAP,
        "MINIMUM_BITRATE": RNS.Reticulum.MINIMUM_BITRATE,
        "DEFAULT_PER_HOP_TIMEOUT": RNS.Reticulum.DEFAULT_PER_HOP_TIMEOUT,
    }

    # =========================================================================
    # 13. AES-256-CBC with known IV
    # =========================================================================
    print("Generating AES fixtures...")

    from RNS.Cryptography.AES import AES_128_CBC, AES_256_CBC

    aes_fixtures = []
    # Known key, IV, plaintext
    aes_tests = [
        {
            "key": bytes([0x01] * 32),
            "iv": bytes([0x02] * 16),
            "plaintext": b"Hello AES-256-CBC!",
        },
        {
            "key": bytes(range(32)),
            "iv": bytes(range(16)),
            "plaintext": bytes(range(48)),
        },
        {
            "key": bytes([0xFF] * 32),
            "iv": bytes([0x00] * 16),
            "plaintext": b"",
        },
    ]

    for test in aes_tests:
        padded = PKCS7.PKCS7.pad(test["plaintext"])
        ciphertext = AES_256_CBC.encrypt(
            plaintext=padded,
            key=test["key"],
            iv=test["iv"],
        )
        aes_fixtures.append({
            "key": to_hex(test["key"]),
            "iv": to_hex(test["iv"]),
            "plaintext": to_hex(test["plaintext"]),
            "padded_plaintext": to_hex(padded),
            "ciphertext": to_hex(ciphertext),
        })
    fixtures["aes"] = aes_fixtures

    # =========================================================================
    # 14. HMAC-SHA256
    # =========================================================================
    print("Generating HMAC fixtures...")

    import hmac as hmaclib

    hmac_fixtures = []
    hmac_tests = [
        (b"key", b"data"),
        (bytes([0x0b] * 20), b"Hi There"),
        (bytes(range(32)), bytes(range(64))),
    ]

    for key, data in hmac_tests:
        digest = hmaclib.new(key, data, hashlib.sha256).digest()
        hmac_fixtures.append({
            "key": to_hex(key),
            "data": to_hex(data),
            "digest": to_hex(digest),
        })
    fixtures["hmac"] = hmac_fixtures

    # =========================================================================
    # Write output
    # =========================================================================
    output_path = os.path.join(os.path.dirname(__file__), "protocol_compatibility.json")
    with open(output_path, "w") as f:
        json.dump(fixtures, f, indent=2)

    print(f"\nFixtures written to {output_path}")
    print(f"Total sections: {len(fixtures)}")
    for section, data in fixtures.items():
        if isinstance(data, list):
            print(f"  {section}: {len(data)} fixtures")
        elif isinstance(data, dict):
            print(f"  {section}: {len(data)} entries")

if __name__ == "__main__":
    generate_fixtures()
