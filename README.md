# RNS — Reticulum Network Stack for Elixir

An Elixir/OTP port of the [Reticulum Network Stack](https://reticulum.network/) — encrypted, self-configuring mesh networking with zero infrastructure requirements.

RNS provides cryptographic identities, named destinations, encrypted links, reliable channels, stream buffers, and large resource transfers over a wide range of physical and virtual interface types including UDP, TCP, LoRa (via RNode), I2P, serial, and more.

This implementation is wire-compatible with the Python reference implementation.

## Installation

Add `rns_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rns_ex, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a cryptographic identity
identity = RNS.Identity.new()

# Create a named destination
destination = RNS.Destination.new(identity, :out, :single, "myapp", "service")

# Get the destination hash for sharing
hash = RNS.Destination.hash(destination)
IO.puts("Listening on #{RNS.hexrep(hash, false)}")

# Send an announce so others can find this destination
RNS.Destination.announce(destination)

# Set up a packet callback
destination = RNS.Destination.set_packet_callback(destination, fn packet ->
  IO.puts("Received: #{packet.data}")
end)
```

### Encrypted Links

```elixir
# Server side — accept incoming links
server_destination = RNS.Destination.new(identity, :in, :single, "myapp", "service")
server_destination = RNS.Destination.set_link_established_callback(server_destination, fn link ->
  IO.puts("Link established with #{RNS.hexrep(link.destination_hash, false)}")
end)

# Client side — establish an encrypted link
link = RNS.Link.new(destination)
```

### Channels and Messages

```elixir
# Define a custom message type
defmodule MyMessage do
  @behaviour RNS.Channel.MessageBase

  defstruct [:text]

  def msgtype, do: 0x0101
  def new, do: %__MODULE__{}
  def pack(%__MODULE__{text: text}), do: text
  def unpack(%__MODULE__{}, raw), do: %__MODULE__{text: raw}
end

# Send messages over a channel
channel = RNS.Link.channel(link)
channel = RNS.Channel.register_message_type(channel, MyMessage)
{:ok, channel, _env} = RNS.Channel.send(channel, %MyMessage{text: "Hello!"})
```

## Architecture

RNS is built as an OTP application with a supervision tree:

```
RNS.Application
├── RNS.IdentityStore        — Known destinations & ratchets (ETS-backed)
├── RNS.Transport             — Routing tables, announce handling, packet forwarding
├── RNS.Reticulum             — Main coordinator, config, lifecycle
├── RNS.InterfaceSupervisor   — Dynamic supervisor for network interfaces
├── RNS.LinkSupervisor        — Dynamic supervisor for encrypted links
└── RNS.ResourceSupervisor    — Dynamic supervisor for resource transfers
```

## Core Modules

| Module | Description |
|--------|-------------|
| `RNS.Identity` | Cryptographic identity (X25519 + Ed25519 keypairs) |
| `RNS.Destination` | Named, addressable endpoints for communication |
| `RNS.Packet` | Wire-format packet encoding/decoding |
| `RNS.Transport` | Routing, announce handling, path management |
| `RNS.Link` | Encrypted bidirectional communication channels |
| `RNS.Channel` | Ordered, reliable message delivery over Links |
| `RNS.Buffer` | Stream-oriented I/O over Channels |
| `RNS.Resource` | Large data transfers with segmentation and compression |
| `RNS.Reticulum` | System configuration and startup |

## Cryptography

All cryptographic operations use Erlang's `:crypto` module (OpenSSL) and the `eddy` library for Ed25519:

- **X25519** — Elliptic-curve Diffie-Hellman key exchange
- **Ed25519** — Digital signatures
- **AES-256-CBC** — Symmetric encryption with PKCS7 padding
- **HMAC-SHA256/512** — Message authentication
- **HKDF** — Key derivation (RFC 5869)
- **Fernet-like tokens** — Authenticated encryption (AES-CBC + HMAC)

## Interfaces

RNS supports many interface types for connecting to networks:

| Interface | Description |
|-----------|-------------|
| `UDPInterface` | UDP unicast/broadcast |
| `TCPInterface` | TCP client and server |
| `LocalInterface` | Shared instance IPC |
| `AutoInterface` | Zero-config UDP multicast peer discovery |
| `SerialInterface` | HDLC-framed serial ports |
| `KISSInterface` | KISS TNC protocol |
| `AX25KISSInterface` | AX.25 over KISS |
| `BackboneInterface` | High-bandwidth TCP/UDP backbone |
| `PipeInterface` | External program via stdin/stdout |
| `I2PInterface` | Anonymous networking via I2P SAM |
| `RNodeInterface` | LoRa radio via RNode hardware |
| `RNodeMultiInterface` | Dual-radio LoRa multiplexing |
| `WeaveInterface` | Weave Device Command Language |

## CLI Utilities

The following command-line utilities are included:

- **rnsd** — RNS daemon
- **rnstatus** — Display interface and transport status
- **rnpath** — Path table management and lookup
- **rnprobe** — Network probe with RTT measurement
- **rnid** — Identity management (generate, import, export, encrypt, sign)
- **rncp** — Remote file copy via Resources
- **rnx** — Remote command execution via Links
- **rnir** — Distributed identity resolver
- **rnpkg** — Meta package manager

### Not Yet Supported

The following Python RNS utilities are **not included** in this release:

- **rnodeconf** — RNode hardware configuration and firmware management. This utility requires serial port communication with RNode LoRa hardware devices (ESP32, AVR, nRF52) and depends on platform-specific tools like `esptool`. It is out of scope for the initial Elixir release.

## Examples

Runnable example scripts are in the `examples/` directory:

```bash
# Minimal setup
mix run examples/minimal.exs

# Echo server and client
mix run examples/echo.exs -- --server
mix run examples/echo.exs -- <destination_hash>

# Announce and discover
mix run examples/announce.exs

# Encrypted link communication
mix run examples/link.exs -- --server
mix run examples/link.exs -- <destination_hash>

# File transfer
mix run examples/filetransfer.exs -- --server
mix run examples/filetransfer.exs -- <destination_hash>
```

See the full list: `minimal`, `echo`, `announce`, `broadcast`, `link`, `request`, `identify`, `channel`, `buffer`, `resource`, `filetransfer`, `speedtest`, `ratchets`.

## Protocol Constants

These wire-critical constants match the Python reference implementation exactly:

| Constant | Value |
|----------|-------|
| MTU | 500 bytes |
| Truncated hash length | 128 bits (16 bytes) |
| Identity key size | 512 bits (256 encryption + 256 signing) |
| Identity hash length | 256 bits |
| Name hash length | 80 bits |
| Header min size | 19 bytes |
| Header max size | 35 bytes |
| Encrypted MDU | ~367 bytes |
| Plain MDU | ~463 bytes |
| Link MDU | ~383 bytes |

## Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Run a specific test file
mix test test/rns/identity_test.exs

# Lint
mix credo --strict

# Generate docs
mix docs

# Run benchmarks
mix run benchmarks/crypto_bench.exs
```

## Requirements

- Elixir ~> 1.15
- Erlang/OTP >= 26

## License

MIT License. See [LICENSE](LICENSE) for details.
