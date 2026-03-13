# Resource transfer throughput benchmark
# Run: mix run benchmarks/resource_bench.exs
#
# Benchmarks resource preparation (segmentation, compression, encryption,
# hashing) and reassembly — the core data-plane operations that determine
# transfer throughput.

alias RNS.Cryptography.Token
alias RNS.Identity
alias RNS.Resource

# --- Setup ---
# Create a mock link map with a Token for encryption
token_key = Token.generate_key()
token = Token.new(token_key)

mock_link = %{
  mdu: 464,
  mtu: 500,
  traffic_timeout_factor: 6,
  token: token,
  stats: %{rtt: 0.1},
  encrypt_fn: fn data -> Token.encrypt(token, data) end,
  decrypt_fn: fn data -> Token.decrypt(token, data) end
}

# Test data at various sizes
data_1kb = :crypto.strong_rand_bytes(1024)
data_16kb = :crypto.strong_rand_bytes(16 * 1024)
data_64kb = :crypto.strong_rand_bytes(64 * 1024)
data_256kb = :crypto.strong_rand_bytes(256 * 1024)

# Pre-build resources for assembly benchmarks
resource_1kb = Resource.new(data_1kb, mock_link, auto_compress: false)
resource_16kb = Resource.new(data_16kb, mock_link, auto_compress: false)

IO.puts("\n=== RNS Resource Transfer Benchmarks ===\n")

# --- Resource preparation (no compression) ---
Benchee.run(
  %{
    "Resource.new 1 KB (no compress)" => fn ->
      Resource.new(data_1kb, mock_link, auto_compress: false)
    end,
    "Resource.new 16 KB (no compress)" => fn ->
      Resource.new(data_16kb, mock_link, auto_compress: false)
    end,
    "Resource.new 64 KB (no compress)" => fn ->
      Resource.new(data_64kb, mock_link, auto_compress: false)
    end,
    "Resource.new 256 KB (no compress)" => fn ->
      Resource.new(data_256kb, mock_link, auto_compress: false)
    end
  },
  title: "Resource Preparation (Encrypt + Segment, No Compression)",
  warmup: 1,
  time: 5,
  print: [configuration: false]
)

# --- Resource preparation (with compression) ---
# Use compressible data for meaningful compression benchmarks
compressible_1kb = String.duplicate("Hello, Reticulum Network Stack! ", 32)
compressible_16kb = String.duplicate("Hello, Reticulum Network Stack! ", 512)
compressible_64kb = String.duplicate("Hello, Reticulum Network Stack! ", 2048)

Benchee.run(
  %{
    "Resource.new 1 KB (compress)" => fn ->
      Resource.new(compressible_1kb, mock_link, auto_compress: true)
    end,
    "Resource.new 16 KB (compress)" => fn ->
      Resource.new(compressible_16kb, mock_link, auto_compress: true)
    end,
    "Resource.new 64 KB (compress)" => fn ->
      Resource.new(compressible_64kb, mock_link, auto_compress: true)
    end
  },
  title: "Resource Preparation (Compress + Encrypt + Segment)",
  warmup: 1,
  time: 5,
  print: [configuration: false]
)

# --- Resource assembly (receiver side) ---
# Build a receivable resource from the sender resource
assemble_resource = fn sender_resource ->
  # Simulate receiver: collect all parts as a list of binaries
  %{sender_resource |
    status: Resource.status_transferring(),
    parts: sender_resource.parts
  }
end

receiver_1kb = assemble_resource.(resource_1kb)
receiver_16kb = assemble_resource.(resource_16kb)

Benchee.run(
  %{
    "Resource.assemble 1 KB" => fn -> Resource.assemble(receiver_1kb) end,
    "Resource.assemble 16 KB" => fn -> Resource.assemble(receiver_16kb) end
  },
  title: "Resource Assembly (Decrypt + Verify)",
  warmup: 1,
  time: 5,
  print: [configuration: false]
)

# --- Advertisement pack/unpack ---
adv_1kb = Resource.Advertisement.new(resource_1kb)
packed_adv = Resource.Advertisement.pack(adv_1kb)

Benchee.run(
  %{
    "Advertisement.new (1 KB resource)" => fn ->
      Resource.Advertisement.new(resource_1kb)
    end,
    "Advertisement.pack" => fn ->
      Resource.Advertisement.pack(adv_1kb)
    end,
    "Advertisement.unpack" => fn ->
      Resource.Advertisement.unpack(packed_adv)
    end
  },
  title: "Resource Advertisement",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# --- Underlying operations (zlib, hashing) ---
Benchee.run(
  %{
    "zlib.compress 1 KB" => fn -> :zlib.compress(data_1kb) end,
    "zlib.compress 16 KB" => fn -> :zlib.compress(data_16kb) end,
    "zlib.compress 64 KB" => fn -> :zlib.compress(data_64kb) end,
    "zlib.uncompress 1 KB" => fn -> :zlib.uncompress(:zlib.compress(data_1kb)) end,
    "Identity.full_hash 1 KB" => fn -> Identity.full_hash(data_1kb) end,
    "Identity.full_hash 64 KB" => fn -> Identity.full_hash(data_64kb) end
  },
  title: "Underlying Operations (zlib, Hashing)",
  warmup: 1,
  time: 3,
  print: [configuration: false]
)
