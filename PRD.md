# PRD: Elixir Port of Reticulum Network Stack

## Overview

Port the complete Reticulum Network Stack (RNS) from Python to Elixir, producing a high-quality, fully tested, idiomatic OTP application that can be imported and used in Elixir programs as a drop-in networking stack. The Python reference implementation lives in `python/RNS/` — read the corresponding Python source when implementing each module. The result should be publishable as a community hex package (`rns_ex`).

## Architecture

```
mix.exs
lib/
  rns.ex                              # Main entry, public API, re-exports
  rns/
    application.ex                    # OTP Application, supervision tree
    version.ex
    log.ex                            # Logging (8 RNS log levels wrapping Logger)
    cryptography/
      hashes.ex                       # SHA-256, SHA-512
      hmac.ex                         # HMAC-SHA256/512
      hkdf.ex                         # HKDF key derivation
      pkcs7.ex                        # PKCS7 padding
      aes.ex                          # AES-256-CBC
      x25519.ex                       # X25519 ECDH key exchange
      ed25519.ex                      # Ed25519 signatures (wraps eddy)
      token.ex                        # Fernet-like authenticated encryption
    identity.ex
    packet.ex
    destination.ex
    transport.ex
    transport/
      path_management.ex              # Path table, path discovery
      announce_handler.ex             # Announce processing, rate limiting
      tunnel_management.ex            # Tunnel creation and maintenance
    link.ex
    channel.ex
    resource.ex
    buffer.ex
    resolver.ex
    discovery.ex
    reticulum.ex                      # Main system class, config, startup
    interfaces/
      interface.ex                    # Behaviour definition + shared logic
      udp_interface.ex
      tcp_interface.ex
      local_interface.ex
      auto_interface.ex
      serial_interface.ex
      kiss_interface.ex
      ax25_kiss_interface.ex
      backbone_interface.ex
      pipe_interface.ex
      i2p_interface.ex
      rnode_interface.ex
      rnode_multi_interface.ex
      weave_interface.ex
    vendor/
      platform_utils.ex
      config_obj.ex                   # INI-style config parser
test/
  test_helper.exs
  rns/
    cryptography/
      hashes_test.exs
      hmac_test.exs
      hkdf_test.exs
      pkcs7_test.exs
      aes_test.exs
      x25519_test.exs
      ed25519_test.exs
      token_test.exs
    identity_test.exs
    packet_test.exs
    destination_test.exs
    transport_test.exs
    link_test.exs
    channel_test.exs
    resource_test.exs
    buffer_test.exs
    reticulum_test.exs
    interfaces/
      interface_test.exs
      udp_interface_test.exs
      tcp_interface_test.exs
      local_interface_test.exs
      auto_interface_test.exs
    integration/
      announce_test.exs
      link_establishment_test.exs
      file_transfer_test.exs
      multi_interface_test.exs
```

## OTP Supervision Tree

```
RNS.Application
├── RNS.IdentityStore (GenServer — known destinations & ratchets, ETS-backed)
├── RNS.Transport (GenServer — routing tables in ETS, periodic jobs via Process.send_after)
├── RNS.Reticulum (GenServer — main coordinator, config, lifecycle)
├── RNS.InterfaceSupervisor (DynamicSupervisor — interface processes)
│   ├── RNS.Interfaces.UDP (GenServer)
│   ├── RNS.Interfaces.TCP.Server (GenServer)
│   └── ...
├── RNS.LinkSupervisor (DynamicSupervisor — link processes)
│   └── RNS.Link (GenServer per active link)
└── RNS.ResourceSupervisor (DynamicSupervisor — resource transfer processes)
    └── RNS.Resource (GenServer per active transfer)
```

## Dependencies (mix.exs)

```elixir
defp deps do
  [
    {:eddy, "~> 1.0"},                # Ed25519 pure-Elixir signatures
    {:msgpax, "~> 2.4"},              # MessagePack serialization
    # Dev/test only
    {:ex_doc, "~> 0.34", only: :dev, runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:stream_data, "~> 1.0", only: :test},
  ]
end
```

Erlang/OTP stdlib provides: `:crypto` (AES-256-CBC, HMAC, SHA-256/512, X25519, HKDF), `:gen_tcp`/`:gen_udp` sockets, `Logger`, binary pattern matching, ETS, GenServer/Supervisor.

Optional (add only if implementing serial interfaces):
```elixir
{:circuits_uart, "~> 1.5", optional: true}   # Serial port communication
```

## CAUTION: Network Impact During Testing

Running `mix test` on this project can cause **severe network degradation on the host machine**. The AutoInterface binds UDP multicast sockets to every network interface it discovers (including virtual ones like Tailscale, Docker, etc.), and each test run can open **thousands of sockets** with hundreds of multicast group memberships. Multiple concurrent test runs compound the problem.

### Prevention

- **Restrict AutoInterface to loopback only in tests.** Any test that instantiates AutoInterface or Reticulum must configure `allowed_interfaces` to only `["lo0"]` (macOS) or `["lo"]` (Linux). Never allow it to bind to all discovered interfaces during testing.
- **Use LocalInterface or loopback UDP/TCP for integration tests.** Do not use AutoInterface for integration tests unless specifically testing AutoInterface discovery — and even then, restrict to loopback.
- **Never run multiple `mix test` processes concurrently.** Wait for one to finish before starting another.
- **Prefer running individual test files** (`mix test test/rns/some_test.exs`) over the full suite when iterating on a single module.

### Recovery: If Networking Becomes Slow or Flaky

1. **Kill all BEAM processes:**
   ```
   pkill -9 -f beam.smp
   ```

2. **Verify no sockets remain open:**
   ```
   lsof -i -n -P | grep beam | wc -l
   ```
   Should return 0. If not, kill the specific PIDs.

3. **Flush mDNSResponder (macOS):**
   ```
   sudo killall -HUP mDNSResponder
   ```

4. **Flush DNS cache (macOS):**
   ```
   sudo dscacheutil -flushcache
   ```

5. **Verify recovery:** Try `curl -I https://example.com` or `ping -c 3 1.1.1.1`. If still slow, toggle Wi-Fi off/on or `sudo ifconfig en0 down && sudo ifconfig en0 up`.

## Key Porting Notes

- Python `threading.Thread` → Elixir `GenServer` / `Task.async` / `spawn_link`
- Python `queue.Queue` → Process mailbox / `GenServer.call/cast`
- Python `threading.Lock` → Not needed (process isolation); use `:atomics` for counters
- Python `threading.Event` → `receive` blocks / process messages
- Python `struct.pack/unpack` → Binary pattern matching `<<field::size(8), type::size(4), hops::size(4), rest::binary>>`
- Python `umsgpack` → `Msgpax`
- Python `configobj` → Custom INI parser (see vendor/config_obj.ex)
- Python `time.time()` → `System.system_time(:second)` or `System.monotonic_time(:millisecond)` for intervals
- Python `os.urandom(n)` → `:crypto.strong_rand_bytes(n)`
- Python `hashlib` → `:crypto.hash(:sha256, data)`
- Python `class Foo:` with `__init__` → `defmodule RNS.Foo do` with `defstruct` + `new/1`
- Python `None` → `nil` (use nilable typespecs `type | nil`)
- Python class-level shared state (`cls.var`) → ETS tables or GenServer state
- Python `isinstance(x, Foo)` → Pattern matching / guards / `is_struct(x, RNS.Foo)`
- Python `try/except` → `{:ok, val}` / `{:error, reason}` tuples; `with` chains; `try/rescue` only for truly exceptional cases
- Python `bytes` → Elixir binary `<<>>`
- Python `dict` → Elixir map `%{}`
- Python `set` → `MapSet`
- Python `@staticmethod` / `@classmethod` → Module functions (all Elixir functions are "static")
- Python mutable object state → GenServer state or ETS entries
- Maintain exact same constants, MTU values, hash lengths, and protocol behavior
- All public API methods must match the Python API semantics
- Use `@moduledoc` and `@doc` for all public modules and functions
- Use typespecs (`@spec`) on all public functions

## Constants Reference (must match exactly)

- MTU: 500 bytes
- Truncated hash length: 128 bits (16 bytes)
- Identity key size: 512 bits (256 encryption + 256 signing)
- Identity hash length: 256 bits
- Name hash length: 80 bits
- Ratchet size: 256 bits
- Token overhead: 48 bytes
- X25519 key: 32 bytes
- Ed25519 signature: 64 bytes
- Header min size: 19 bytes
- Header max size: 35 bytes
- Encrypted MDU: ~367 bytes
- Plain MDU: ~463 bytes
- Link MDU: ~383 bytes
- Link establishment timeout per hop: 6 seconds
- Link keepalive: 360 seconds
- Link stale time: 720 seconds
- Resource initial window: 4 segments
- Resource max window (fast): 75 segments
- Resource max efficient size: 16 MB

---

## Tasks

### Phase 1: Project Foundation

- [x] **1.1 — Initialize Elixir Mix project**
  Create `mix.exs` (app: `:rns_ex`, module: `RNS`, version: "0.1.0", elixir: "~> 1.15", erlang OTP >= 26). Add all dependencies listed above. Create `lib/rns.ex` entry point with `defmodule RNS` and version constant. Create `lib/rns/version.ex`. Create `test/test_helper.exs` with `ExUnit.start()`. Create `.formatter.exs`. Create `.gitignore` for Elixir (`_build/`, `deps/`, `*.beam`, `.elixir_ls/`). Run `mix deps.get` to verify dependencies resolve. Write a trivial test that requires the library and passes.

- [x] **1.2 — Logging and utility infrastructure**
  Port `python/RNS/__init__.py` logging system → `lib/rns/log.ex`. Implement log levels: `LOG_CRITICAL` (0), `LOG_ERROR` (1), `LOG_WARNING` (2), `LOG_NOTICE` (3), `LOG_INFO` (4), `LOG_VERBOSE` (5), `LOG_DEBUG` (6), `LOG_EXTREME` (7). Implement `RNS.Log.log(message, level, override_destination)` wrapping Elixir's `Logger` with appropriate level mapping. Port `hexrep/1`, `prettysize/1`, `prettytime/1`, `phyparams/1`, `panic/1` as functions in `RNS` module. Create `lib/rns/vendor/platform_utils.ex` with OS detection (map Python's `platformutils`). Write tests for all utility functions.

- [x] **1.3 — OTP Application skeleton**
  Create `lib/rns/application.ex` with `use Application`. Define the supervision tree skeleton (supervisors for interfaces, links, resources — children started empty). Register the application in `mix.exs` with `mod: {RNS.Application, []}`. Ensure `mix test` starts the application and passes. This is the OTP foundation everything else plugs into.

### Phase 2: Cryptography Layer

Read `python/RNS/Cryptography/` for reference. Every crypto module must have tests with known test vectors.

- [x] **2.1 — Hashes: SHA-256 and SHA-512**
  Create `lib/rns/cryptography/hashes.ex`. Wrap `:crypto.hash/2` to provide `RNS.Cryptography.Hashes.sha256(data) :: binary()` and `sha512(data) :: binary()`. Port the truncated hash helper used throughout RNS: `truncated_hash(data)` returning the first 16 bytes of SHA-256. Write tests using NIST test vectors from `python/tests/hashes.py` and property-based tests with StreamData.

- [x] **2.2 — HMAC and HKDF**
  Create `lib/rns/cryptography/hmac.ex` wrapping `:crypto.mac(:hmac, algo, key, data)` to provide `RNS.Cryptography.HMAC.digest(key, data, algorithm)`. Create `lib/rns/cryptography/hkdf.ex` implementing HKDF (RFC 5869) using HMAC — implement `extract/3` and `expand/4` steps, provide `RNS.Cryptography.HKDF.derive_key(ikm, length, salt, info)`. Match the Python HKDF interface exactly — read `python/RNS/Cryptography/HKDF.py`. Write tests with RFC 5869 test vectors.

- [x] **2.3 — PKCS7 padding and AES-256-CBC**
  Create `lib/rns/cryptography/pkcs7.ex` — implement `pad(data, block_size)` and `unpad(data)`. Read `python/RNS/Cryptography/PKCS7.py`. Create `lib/rns/cryptography/aes.ex` wrapping `:crypto.crypto_one_time/5` — provide `encrypt(plaintext, key, iv)` and `decrypt(ciphertext, key, iv)` for AES-256-CBC with PKCS7 padding. Write tests: roundtrip encryption, known test vectors, invalid padding detection, property-based tests.

- [x] **2.4 — X25519 key exchange**
  Create `lib/rns/cryptography/x25519.ex`. Use `:crypto.generate_key(:ecdh, :x25519)` and `:crypto.compute_key(:ecdh, peer_pub, own_priv, :x25519)`. Implement `X25519.generate_keypair/0`, `X25519.from_private_bytes/1`, `X25519.private_bytes/1`, `X25519.public_key/1`, `X25519.exchange/2`. Match the API from `python/RNS/Cryptography/X25519.py`. Write tests: key generation, ECDH exchange between two parties produces same shared secret, RFC 7748 test vectors.

- [x] **2.5 — Ed25519 signatures**
  Create `lib/rns/cryptography/ed25519.ex`. Wrap the `eddy` hex package. Implement `Ed25519.generate_keypair/0`, `Ed25519.from_private_bytes/1`, `Ed25519.private_bytes/1`, `Ed25519.public_key/1`, `Ed25519.sign/2`, `Ed25519.verify/3`. Match `python/RNS/Cryptography/Ed25519.py`. Write tests: sign/verify roundtrip, invalid signature rejection, key serialization roundtrip, RFC 8032 test vectors.

- [x] **2.6 — Token (Fernet-like authenticated encryption)**
  Create `lib/rns/cryptography/token.ex`. Port `python/RNS/Cryptography/Token.py` exactly. Implement `Token` module with `@token_overhead 48`, `generate_key/0`, `encrypt/2`, `decrypt/2`, `verify_hmac/2`. This uses AES-256-CBC + HMAC-SHA256. Write tests: roundtrip encrypt/decrypt, tampering detection, overhead constant verification. Create `lib/rns/cryptography.ex` that re-exports all crypto modules as `RNS.Cryptography`.

### Phase 3: Core Protocol

- [x] **3.1 — Identity module**
  Port `python/RNS/Identity.py` (821 LOC) → `lib/rns/identity.ex`. Key constants: `@curve "Curve25519"`, `@keysize 512`, `@hashlength 256`, `@name_hash_length 80`, `@ratchetsize 256`, `@ratchet_expiry`, `@truncated_hashlength 128`. Implement `RNS.Identity` as a struct + GenServer-backed store (`RNS.IdentityStore`) for known destinations/ratchets (backed by ETS). Functions: `new/0`, `create_keys/1`, `get_private_key/1`, `load_private_key/2`, `load_public_key/2`, `encrypt/2`, `decrypt/2`, `sign/2`, `validate/3`, `prove/3`, `hash/1`, `hexhash/1`, `from_bytes/1`, `from_file/1`, `to_file/2`. Store functions: `remember/4`, `recall/1`, `recall_app_data/1`, `save_known_destinations/0`, `load_known_destinations/1`. Static: `full_hash/1`, `truncated_hash/1`, `get_random_hash/0`. Write thorough tests: key generation, sign/verify, encrypt/decrypt, hash computation, recall/remember, serialization.

- [x] **3.2 — Packet module**
  Port `python/RNS/Packet.py` (602 LOC) → `lib/rns/packet.ex`. Define all constants as module attributes: `@data 0x00`, `@announce 0x01`, `@linkrequest 0x02`, `@proof 0x03`. Header types, transport types, context types. Implement `RNS.Packet` as a struct: `new/2`, `pack/1`, `unpack/1`, `encrypt/1`, `decrypt/1`, `send/1`, `resend/1`, `prove/2`, `update_hash/1`, `get_hash/1`. Implement `RNS.PacketReceipt` struct with callbacks: `set_timeout/2`, `set_delivery_callback/2`, status tracking. Implement `RNS.ProofDestination`. Port MTU/MDU constants. Use binary pattern matching for pack/unpack — this is where Elixir shines. Write tests: packet creation, pack/unpack roundtrip, hash computation, header encoding, MTU boundaries.

- [x] **3.3 — Destination module**
  Port `python/RNS/Destination.py` (691 LOC) → `lib/rns/destination.ex`. Define types: `@single 0x00`, `@group 0x01`, `@plain 0x02`, `@link 0x03`. Directions: `@in 0x11`, `@out 0x12`. Proof strategies. Implement `RNS.Destination` as a struct: `new/4` (identity, direction, type, app_name, aspects), `hash/1`, `hexhash/1`, `announce/2`, `accepts_links?/1`, `set_link_established_callback/2`, `set_packet_callback/2`, `set_proof_requested_callback/2`, `set_proof_strategy/2`, `register_request_handler/4`, `encrypt/2`, `decrypt/2`, `sign/2`. Handle ratchets. Wire registration with `RNS.Transport.register_destination/1`. Write tests: destination creation, hash derivation matches Python, encryption/decryption, announce generation.

### Phase 4: Transport Layer

This is the largest module (3312 LOC in Python). Split into manageable sub-modules. Transport is a GenServer with ETS tables for concurrent read access.

- [x] **4.1 — Transport core and data structures**
  Create `lib/rns/transport.ex` and `lib/rns/transport/path_management.ex`. Implement `RNS.Transport` as a GenServer. Define all constants. Set up ETS tables on init: `:rns_interfaces`, `:rns_destinations`, `:rns_pending_links`, `:rns_active_links`, `:rns_packet_hashlist`, `:rns_receipts`, `:rns_announce_table`, `:rns_destination_table`, `:rns_path_table`, `:rns_reverse_table`, `:rns_tunnel_table`, `:rns_link_table`. Implement `register_destination/1`, `deregister_destination/1`, `register_interface/1`, `deregister_interface/1`, `has_path/1`, `hops_to/1`, `next_hop/1`, `next_hop_interface/1`, `expire_path/1`, `request_path/2`. Path persistence: `save_path_table/0`, `load_path_table/0`. Write tests.

- [x] **4.2 — Transport announce handling**
  Create `lib/rns/transport/announce_handler.ex`. Port announce processing: `inbound_announce/3`, `outbound_announce/1`, `process_announce_queue/1`, `should_forward_announce/2`, `mark_path_unknown_for_destination/1`, rate limiting, deduplication, validation. Handle announce table: entry creation, expiry, retransmission timing. Handle path responses. Write tests: announce validation, rate limiting, deduplication, forwarding decisions.

- [x] **4.3 — Transport packet routing and delivery**
  Complete `lib/rns/transport.ex` with packet routing: `inbound/2`, `outbound/1`, `forward/1`, `transmit/2`, `internal_inbound/2`. Link management: `register_link/1`, `activate_link/1`, `find_link_for_request_packet/1`, `find_best_link/1`. Tunnel management in `lib/rns/transport/tunnel_management.ex`: `register_tunnel/2`, `tunnel_synthesize_handler/0`. Transport periodic jobs via `Process.send_after` — path/link/receipt expiry, cache cleaning. Write tests: packet routing decisions, link registration, receipt handling.

- [x] **4.4 — Transport caching and persistence**
  Implement caching: `cache/2`, packet hash deduplication, cache file storage. `save_packet_hashlist/0`, `load_packet_hashlist/0`, `save_tunnel_table/0`, `load_tunnel_table/0`. Wire up periodic job scheduling in GenServer `handle_info`. All ETS operations should be wrapped in clean function APIs. Write integration tests: cache persistence roundtrip, packet hashlist save/load, tunnel table persistence.

### Phase 5: Communication Layer

- [x] **5.1 — Channel module**
  Port `python/RNS/Channel.py` (705 LOC) → `lib/rns/channel.ex`. Define `MessageState` (`:new`, `:sent`, `:delivered`, `:failed`). Define `MessageBase` behaviour with `pack/1`, `unpack/1`, `msgtype/0` callbacks. Implement `RNS.Channel.Envelope` struct: wraps messages with sequence numbers, timestamps, retry tracking. Implement `RNS.Channel` as a struct/process: `send/2`, `register_message_type/2`, `add_message_handler/2`, `remove_message_handler/2`, `get_mdu/1`, `is_ready_to_send?/1`. Implement `LinkChannelOutlet`. Handle message ordering, delivery confirmation, retry, windowing. Write tests: message serialization, ordering, delivery confirmation, windowing.

- [x] **5.2 — Link module — establishment and encryption**
  Port `python/RNS/Link.py` (1549 LOC, part 1) → `lib/rns/link.ex`. Define constants. Implement `RNS.Link` as a GenServer. 3-step ECDH handshake: (1) initiator generates ephemeral X25519 keypair, sends link request, (2) responder validates, generates own keypair, derives shared secret, sends proof, (3) initiator verifies proof, derives same shared secret. `derive_keys/1` using HKDF. `encrypt/2`, `decrypt/2` with derived keys. `identify/2` and `request/5`. Write tests: key exchange, encrypt/decrypt roundtrip, link state transitions.

- [ ] **5.3 — Link module — lifecycle management**
  Complete `lib/rns/link.ex`. `send/3`, `receive/2`, `prove/2`, `prove_packet/1`, `validate_proof/1`. Keepalive via `Process.send_after`: `send_keepalive/1`, response handling. Teardown: `teardown/1`, `teardown_packet/1`. RTT tracking. `inactive_for/1`, `no_inbound_for/1`, `no_outbound_for/1`, `no_data_for/1`. Stale detection and auto-teardown. Wire callbacks. Write tests: keepalive timing, stale detection, teardown, RTT.

- [ ] **5.4 — Resource module**
  Port `python/RNS/Resource.py` (1361 LOC) → `lib/rns/resource.ex`. Implement `RNS.Resource` as a GenServer for large data transfers over Links. Constants: `@window 4`, `@window_min 2`, `@window_max 75`, `@window_max_slow 10`, rate constants, `@max_efficient_size 16_777_215`, `@max_retries`, etc. States: `:queued`, `:advertised`, `:transferring`, `:awaiting_proof`, `:complete`, `:failed`, `:corrupt`. Sender: `advertise/1`, `send_part/1`, segmentation, window management, adaptive rate. Receiver: `accept/1`, `reject/1`, `cancel/1`, reassembly, proof generation. `ResourceAdvertisement` struct. Handle `:zlib` compression. Write tests: segmentation/reassembly roundtrip, window growth/shrink, compression, advertisement pack/unpack.

### Phase 6: High-Level Modules

- [ ] **6.1 — Buffer module**
  Port `python/RNS/Buffer.py` (369 LOC) → `lib/rns/buffer.ex`. Implement `StreamDataMessage` (a Channel message for stream data). Implement `RNS.Buffer.Reader` (reads from Channel). Implement `RNS.Buffer.Writer` (writes to Channel). Module functions: `create_reader/3`, `create_writer/2`, `create_bidirectional_buffer/4`. Wire buffering, flow control, close semantics. Write tests: read/write roundtrip, bidirectional buffer, flow control.

- [ ] **6.2 — Resolver module (stub)**
  Port `python/RNS/Resolver.py` (34 LOC) → `lib/rns/resolver.ex`. This is a stub/placeholder in Python. Create `RNS.Resolver` with matching interface for future expansion. Write a basic test.

### Phase 7: Interface System

- [ ] **7.1 — Interface behaviour and base module**
  Port `python/RNS/Interfaces/Interface.py` (302 LOC) → `lib/rns/interfaces/interface.ex`. Define `RNS.Interface` behaviour with callbacks: `process_outgoing/2`, `process_incoming/2`, `detach/1`. Create `use RNS.Interface` macro that injects shared logic: constants (`@mode_full`, `@mode_point_to_point`, `@mode_access_point`, `@mode_roaming`, `@mode_boundary`, `@mode_gateway`), default struct fields (`:name`, `:rxb`, `:txb`, `:online`, `:bitrate`, `:mtu`, `:announce_rate_target`, etc.), shared functions: `get_hash/1`, `should_ingress_limit/1`, `optimise_mtu/1`, `age/1`, `hold_announce/2`, `process_held_announces/1`, `received_announce/1`, `sent_announce/1`, announce frequency tracking, HDLC framing helpers, IFAC validation. Write tests: hash computation, announce rate limiting, HDLC framing, MTU optimization.

- [ ] **7.2 — UDP interface**
  Port `python/RNS/Interfaces/UDPInterface.py` (140 LOC) → `lib/rns/interfaces/udp_interface.ex`. Implement as GenServer using `:gen_udp`. Support: bind address/port, target address/port, broadcast mode. `process_outgoing/2` sends via UDP, receive loop in `handle_info`. Config from parsed config object. Write tests: send/receive over localhost UDP, config parsing.

- [ ] **7.3 — TCP interface (client and server)**
  Port `python/RNS/Interfaces/TCPInterface.py` (661 LOC) → `lib/rns/interfaces/tcp_interface.ex`. Implement `RNS.Interfaces.TCPClient` and `RNS.Interfaces.TCPServer` as GenServers using `:gen_tcp`. Client: connect, HDLC framing, reconnection via `Process.send_after`, keepalive. Server: `ThousandIsland` / raw `:gen_tcp.listen` + accept loop, manage client list. Connection timeouts, graceful disconnection, HDLC escape sequences. Write tests: client/server over localhost, HDLC framing roundtrip, reconnection.

- [ ] **7.4 — Local interface**
  Port `python/RNS/Interfaces/LocalInterface.py` (472 LOC) → `lib/rns/interfaces/local_interface.ex`. `RNS.Interfaces.LocalClient` and `RNS.Interfaces.LocalServer` using TCP on localhost (or Unix domain sockets via `:gen_tcp` with `{:local, path}` on supported OTP). Shared instance mode. Write tests: local client/server, multi-client handling.

- [ ] **7.5 — Auto interface (peer discovery)**
  Port `python/RNS/Interfaces/AutoInterface.py` (663 LOC) → `lib/rns/interfaces/auto_interface.ex`. UDP multicast peer discovery. Multicast group management, peer tracking (`AutoInterfacePeer`), link-local addressing, auto peer connect/disconnect, data scope management. Critical for zero-config networking. Write tests: peer discovery simulation, multicast group handling. **Remember: restrict to loopback in tests.**

- [ ] **7.6 — Serial interface**
  Port `python/RNS/Interfaces/SerialInterface.py` (227 LOC) → `lib/rns/interfaces/serial_interface.ex`. HDLC framing over serial. Baud rate config, port open/close. Use `circuits_uart` if available, fall back to Port-based implementation. Write tests: HDLC framing roundtrip using IO pipes (no hardware needed).

- [ ] **7.7 — KISS and AX.25 KISS interfaces**
  Port `python/RNS/Interfaces/KISSInterface.py` (387 LOC) → `lib/rns/interfaces/kiss_interface.ex`. Port `python/RNS/Interfaces/AX25KISSInterface.py` (400 LOC) → `lib/rns/interfaces/ax25_kiss_interface.ex`. KISS framing: FEND (0xC0), FESC (0xDB), TFEND (0xDC), TFESC (0xDD), commands. AX.25 adds callsign/SSID addressing. Write tests: KISS encode/decode, AX.25 addresses, roundtrip.

- [ ] **7.8 — Backbone interface**
  Port `python/RNS/Interfaces/BackboneInterface.py` (697 LOC) → `lib/rns/interfaces/backbone_interface.ex`. `RNS.Interfaces.Backbone` and `RNS.Interfaces.BackboneClient`. TCP and UDP modes, connection multiplexing, high-bandwidth optimization. Write tests: connection establishment, data transfer.

- [ ] **7.9 — Pipe interface**
  Port `python/RNS/Interfaces/PipeInterface.py` (205 LOC) → `lib/rns/interfaces/pipe_interface.ex`. Communicate with external programs via `Port.open/2` (stdin/stdout pipes). Process spawning, bidirectional I/O, lifecycle management. Write tests: pipe communication with simple echo subprocess.

- [ ] **7.10 — I2P interface**
  Port `python/RNS/Interfaces/I2PInterface.py` (1009 LOC) → `lib/rns/interfaces/i2p_interface.ex`. `RNS.Interfaces.I2P`, `I2PPeer`, `I2PController`. SAM protocol over TCP. Tunnel creation, destination management, session handling. Map Python asyncio → Elixir GenServer + message passing. Write tests: SAM protocol formatting, session state (no I2P daemon required).

- [ ] **7.11 — RNode interface (LoRa)**
  Port `python/RNS/Interfaces/RNodeInterface.py` (1558 LOC) → `lib/rns/interfaces/rnode_interface.ex`. LoRa radio via RNode hardware. KISS-based command protocol, radio params (frequency, bandwidth, spreading factor, coding rate, TX power), firmware detection, stats, serial connection. Most complex interface. Write tests: command encoding/decoding, radio param validation, KISS command framing.

- [ ] **7.12 — RNode Multi and Weave interfaces**
  Port `python/RNS/Interfaces/RNodeMultiInterface.py` (1148 LOC) → `lib/rns/interfaces/rnode_multi_interface.ex`. Dual-radio LoRa multiplexing. Port `python/RNS/Interfaces/WeaveInterface.py` (1091 LOC) → `lib/rns/interfaces/weave_interface.ex`. Weave Device Command Language (WDCL). Write tests for both.

### Phase 8: System Integration

- [ ] **8.1 — Configuration parser**
  Create `lib/rns/vendor/config_obj.ex`. Port INI-like config parsing that `python/RNS/Reticulum.py` uses. RNS configs use `configobj` format (INI with nested sections, type coercion). Implement: `parse/1`, `parse_file/1`, `to_string/1`. Handle nested `[[section]]` blocks, key=value parsing, comments, type coercion (booleans, integers, lists). Write tests with sample RNS config files (see `python/tests/rnsconfig/config`).

- [ ] **8.2 — Reticulum main class — initialization and configuration**
  Port `python/RNS/Reticulum.py` (1716 LOC, part 1) → `lib/rns/reticulum.ex`. Implement `RNS.Reticulum` as a GenServer (effectively singleton per node). Config dir detection (`~/.reticulum/` or custom), config parsing, storage/cache/resource path management. `init/1`: load config, set up paths, init Identity store, start Transport. `create_default_config/0`. Write tests: initialization, path management, default config.

- [ ] **8.3 — Reticulum main class — interface instantiation and lifecycle**
  Complete `lib/rns/reticulum.ex`. Interface instantiation from config: for each `[[interface_name]]` section, determine type, start appropriate interface GenServer under InterfaceSupervisor. `start_local_interface/1`, `start_remote_interface/1`. Exit handler via `GenServer.terminate/2` — save state (path tables, known destinations, packet hashlist), teardown interfaces, stop Transport. Shared instance mode (daemon). Write tests: interface instantiation from config, state persistence on shutdown.

- [ ] **8.4 — Discovery module**
  Port `python/RNS/Discovery.py` (733 LOC) → `lib/rns/discovery.ex`. `InterfaceAnnouncer` (creates/sends discovery announces). `InterfaceAnnounceHandler` (receives/processes). `InterfaceDiscovery` (coordinates across interfaces). `BlackholeUpdater` (network blackhole detection/distribution). Write tests: announce creation/validation, discovery state, blackhole list.

### Phase 9: Public API and Module Integration

- [ ] **9.1 — Wire up public API in lib/rns.ex**
  Update `lib/rns.ex` to require/alias all modules. Export public API matching Python's `RNS.__init__`: `RNS.Reticulum`, `RNS.Identity`, `RNS.Destination`, `RNS.Transport`, `RNS.Packet`, `RNS.Link`, `RNS.Channel`, `RNS.Buffer`, `RNS.Resource`, `RNS.Resolver`. Ensure `RNS.log/2`, `RNS.version/0`, `RNS.host_os/0`, `RNS.hexrep/1` are accessible at module level. Add `@moduledoc` with usage examples. Write a comprehensive test exercising the full public API: start application, create Identity, create Destination, verify exports.

- [ ] **9.2 — Cross-module integration testing**
  Create `test/rns/integration/`. Write integration tests: (1) `announce_test.exs` — start Reticulum with LocalInterface, create Identity, create Destination, send announce, verify Transport processes it. (2) `link_establishment_test.exs` — two Reticulum instances via LocalInterface, establish Link, verify ECDH, send data. (3) `file_transfer_test.exs` — transfer Resource over Link, verify integrity. (4) `multi_interface_test.exs` — routing across multiple interfaces. Reference `python/tests/link.py` and `python/tests/channel.py`.

### Phase 10: Utilities and CLI Tools

- [ ] **10.1 — rnsd daemon**
  Port `python/RNS/Utilities/rnsd.py` (564 LOC) → Elixir escript or Mix release. Create `lib/rns/utilities/rnsd.ex`. Argument parsing (OptionParser), config dir, log level, Reticulum init, signal handling (`:os.set_signal_handler`), background execution. Write integration test: start/stop.

- [ ] **10.2 — rnstatus and rnpath utilities**
  Port `python/RNS/Utilities/rnstatus.py` (687 LOC) → `lib/rns/utilities/rnstatus.ex`. Interface status, transport stats, tables. Port `python/RNS/Utilities/rnpath.py` (548 LOC) → `lib/rns/utilities/rnpath.ex`. Path lookup/request/display. Write tests for output formatting.

- [ ] **10.3 — rnprobe and rnid utilities**
  Port `python/RNS/Utilities/rnprobe.py` (251 LOC) → `lib/rns/utilities/rnprobe.ex`. Network probe, RTT measurement. Port `python/RNS/Utilities/rnid.py` (611 LOC) → `lib/rns/utilities/rnid.ex`. Identity management CLI. Write tests.

- [ ] **10.4 — rncp and rnx utilities**
  Port `python/RNS/Utilities/rncp.py` (906 LOC) → `lib/rns/utilities/rncp.ex`. Remote file copy via Resources. Port `python/RNS/Utilities/rnx.py` (740 LOC) → `lib/rns/utilities/rnx.ex`. Remote command execution via Links. Write tests for protocol message formatting.

### Phase 11: Examples and Documentation

- [ ] **11.1 — Port core examples**
  Port `python/Examples/Minimal.py`, `Echo.py`, `Announce.py`, `Broadcast.py` → `examples/`. Each should be a standalone Elixir script (`mix run examples/minimal.exs`) demonstrating the API. Ensure examples compile and run.

- [ ] **11.2 — Port advanced examples**
  Port `python/Examples/Link.py`, `Request.py`, `Identify.py`, `Channel.py`, `Buffer.py` → `examples/`. Demonstrate encrypted links, request/response, identity verification, channels, buffers.

- [ ] **11.3 — Port file transfer and performance examples**
  Port `python/Examples/Resource.py`, `Filetransfer.py`, `Speedtest.py`, `Ratchets.py` → `examples/`. Large file transfers, performance testing, forward secrecy with ratchets.

### Phase 12: Quality and Compatibility

- [ ] **12.1 — Protocol compatibility verification**
  Write cross-language compatibility tests. Create test fixtures: known Identity keys, known Destination hashes, known Packet bytes, known announce data — generated by Python RNS. Verify the Elixir implementation produces byte-identical outputs for the same inputs. Focus on: hash computation, packet encoding, announce format, ECDH exchange, Token encrypt/decrypt. The Elixir port must be wire-compatible with Python RNS.

- [ ] **12.2 — Run Credo linter, Dialyzer, and fix all issues**
  Run `mix format` on all source files. Run `mix credo --strict`. Run `mix dialyzer`. Fix all warnings and errors. Ensure consistent code style. Review all `# TODO` and `# FIXME` comments and resolve them. Verify all typespecs are correct.

- [ ] **12.3 — Performance benchmarking**
  Create `benchmarks/` directory using Benchee. Benchmark: crypto operations (encrypt/decrypt, sign/verify, hash throughput), packet encoding/decoding, link establishment time, resource transfer throughput. Compare against Python RNS where possible. Optimize hot paths. Profile with `:fprof` or `:eprof` if needed.

- [ ] **12.4 — Final review and hex release preparation**
  Review all `@moduledoc` and `@doc` documentation. Ensure `mix.exs` metadata is complete (description, licenses, links, source_url). Verify `mix docs` generates complete API docs. Verify `mix test` passes all tests. Create `README.md` with: installation, quick start, API overview, examples link. Tag version 0.1.0. Verify `mix hex.build` succeeds.
