defmodule RNS.PacketTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias RNS.Packet
  alias RNS.PacketReceipt
  alias RNS.ProofDestination
  alias RNS.Transport

  # Clear Transport ETS tables between tests for clean state.
  setup do
    RNS.Test.SupervisedHelpers.clear_transport_tables()
    :ok
  end

  # ── Constants ──────────────────────────────────────────────────────

  describe "packet type constants" do
    test "DATA is 0x00" do
      assert Packet.data() == 0x00
    end

    test "ANNOUNCE is 0x01" do
      assert Packet.announce() == 0x01
    end

    test "LINKREQUEST is 0x02" do
      assert Packet.linkrequest() == 0x02
    end

    test "PROOF is 0x03" do
      assert Packet.proof() == 0x03
    end

    test "types list" do
      assert Packet.types() == [0x00, 0x01, 0x02, 0x03]
    end
  end

  describe "header type constants" do
    test "HEADER_1 is 0x00" do
      assert Packet.header_1() == 0x00
    end

    test "HEADER_2 is 0x01" do
      assert Packet.header_2() == 0x01
    end

    test "header_types list" do
      assert Packet.header_types() == [0x00, 0x01]
    end
  end

  describe "context constants" do
    test "NONE is 0x00" do
      assert Packet.context_none() == 0x00
    end

    test "RESOURCE is 0x01" do
      assert Packet.context_resource() == 0x01
    end

    test "RESOURCE_ADV is 0x02" do
      assert Packet.context_resource_adv() == 0x02
    end

    test "RESOURCE_REQ is 0x03" do
      assert Packet.context_resource_req() == 0x03
    end

    test "RESOURCE_HMU is 0x04" do
      assert Packet.context_resource_hmu() == 0x04
    end

    test "RESOURCE_PRF is 0x05" do
      assert Packet.context_resource_prf() == 0x05
    end

    test "RESOURCE_ICL is 0x06" do
      assert Packet.context_resource_icl() == 0x06
    end

    test "RESOURCE_RCL is 0x07" do
      assert Packet.context_resource_rcl() == 0x07
    end

    test "CACHE_REQUEST is 0x08" do
      assert Packet.context_cache_request() == 0x08
    end

    test "REQUEST is 0x09" do
      assert Packet.context_request() == 0x09
    end

    test "RESPONSE is 0x0A" do
      assert Packet.context_response() == 0x0A
    end

    test "PATH_RESPONSE is 0x0B" do
      assert Packet.context_path_response() == 0x0B
    end

    test "COMMAND is 0x0C" do
      assert Packet.context_command() == 0x0C
    end

    test "COMMAND_STATUS is 0x0D" do
      assert Packet.context_command_status() == 0x0D
    end

    test "CHANNEL is 0x0E" do
      assert Packet.context_channel() == 0x0E
    end

    test "KEEPALIVE is 0xFA" do
      assert Packet.context_keepalive() == 0xFA
    end

    test "LINKIDENTIFY is 0xFB" do
      assert Packet.context_linkidentify() == 0xFB
    end

    test "LINKCLOSE is 0xFC" do
      assert Packet.context_linkclose() == 0xFC
    end

    test "LINKPROOF is 0xFD" do
      assert Packet.context_linkproof() == 0xFD
    end

    test "LRRTT is 0xFE" do
      assert Packet.context_lrrtt() == 0xFE
    end

    test "LRPROOF is 0xFF" do
      assert Packet.context_lrproof() == 0xFF
    end
  end

  describe "flag constants" do
    test "FLAG_SET is 0x01" do
      assert Packet.flag_set() == 0x01
    end

    test "FLAG_UNSET is 0x00" do
      assert Packet.flag_unset() == 0x00
    end
  end

  describe "size constants" do
    test "HEADER_MAXSIZE is 35" do
      assert Packet.header_maxsize() == 35
    end

    test "MTU is 500" do
      assert Packet.mtu() == 500
    end

    test "MDU is 464" do
      assert Packet.mdu() == 464
    end

    test "ENCRYPTED_MDU is 383" do
      assert Packet.encrypted_mdu() == 383
    end

    test "PLAIN_MDU equals MDU" do
      assert Packet.plain_mdu() == Packet.mdu()
    end

    test "TIMEOUT_PER_HOP is 6" do
      assert Packet.timeout_per_hop() == 6
    end
  end

  # ── Packet creation ────────────────────────────────────────────────

  # Helper to create a simple destination-like map for testing
  defp make_destination(opts \\ []) do
    %{
      hash: Keyword.get(opts, :hash, :crypto.strong_rand_bytes(16)),
      type: Keyword.get(opts, :type, 0x00),
      link_id: Keyword.get(opts, :link_id, nil),
      mtu: Keyword.get(opts, :mtu, nil)
    }
  end

  describe "new/2 with destination" do
    test "creates a packet with default parameters" do
      dest = make_destination()
      data = "hello"
      packet = Packet.new(dest, data)

      assert packet.destination == dest
      assert packet.data == data
      assert packet.packet_type == Packet.data()
      assert packet.header_type == Packet.header_1()
      assert packet.transport_type == 0x00
      assert packet.context == Packet.context_none()
      assert packet.context_flag == Packet.flag_unset()
      assert packet.hops == 0
      assert packet.packed == false
      assert packet.sent == false
      assert packet.create_receipt == true
      assert packet.receipt == nil
      assert packet.from_packed == false
      assert packet.mtu == 500
    end

    test "creates a packet with custom options" do
      dest = make_destination()

      packet =
        Packet.new(dest, "test",
          packet_type: Packet.announce(),
          context: Packet.context_none(),
          transport_type: 0x01,
          header_type: Packet.header_2(),
          transport_id: :crypto.strong_rand_bytes(16),
          create_receipt: false,
          context_flag: Packet.flag_set()
        )

      assert packet.packet_type == Packet.announce()
      assert packet.transport_type == 0x01
      assert packet.header_type == Packet.header_2()
      assert packet.create_receipt == false
      assert packet.context_flag == Packet.flag_set()
    end

    test "LINK destination uses destination mtu" do
      dest = make_destination(type: 0x03, mtu: 250)
      packet = Packet.new(dest, "data")

      assert packet.mtu == 250
    end

    test "non-LINK destination uses default MTU" do
      dest = make_destination(type: 0x00)
      packet = Packet.new(dest, "data")

      assert packet.mtu == 500
    end
  end

  describe "new/2 from raw bytes (nil destination)" do
    test "creates packet from raw bytes" do
      raw = :crypto.strong_rand_bytes(50)
      packet = Packet.new(nil, raw)

      assert packet.raw == raw
      assert packet.packed == true
      assert packet.from_packed == true
      assert packet.create_receipt == false
    end
  end

  # ── packed_flags ───────────────────────────────────────────────

  describe "packed_flags/1" do
    test "packs flags for default DATA packet" do
      # header_type=0, context_flag=0, transport_type=0, dest_type=0 (SINGLE), packet_type=0 (DATA)
      # flags = (0 << 6) | (0 << 5) | (0 << 4) | (0 << 2) | 0 = 0x00
      dest = make_destination(type: 0x00)
      packet = Packet.new(dest, "test")

      assert Packet.packed_flags(packet) == 0x00
    end

    test "packs flags for ANNOUNCE over transport" do
      # header_type=1, context_flag=0, transport_type=1, dest_type=0 (SINGLE), packet_type=1 (ANNOUNCE)
      # flags = (1 << 6) | (0 << 5) | (1 << 4) | (0 << 2) | 1 = 0x51
      dest = make_destination(type: 0x00)

      packet =
        Packet.new(dest, "test",
          header_type: Packet.header_2(),
          transport_type: 0x01,
          packet_type: Packet.announce()
        )

      assert Packet.packed_flags(packet) == 0x51
    end

    test "packs flags for GROUP DATA packet" do
      # header_type=0, context_flag=0, transport_type=0, dest_type=1 (GROUP), packet_type=0 (DATA)
      # flags = (0 << 6) | (0 << 5) | (0 << 4) | (1 << 2) | 0 = 0x04
      dest = make_destination(type: 0x01)
      packet = Packet.new(dest, "test")

      assert Packet.packed_flags(packet) == 0x04
    end

    test "LRPROOF context uses LINK destination type" do
      # For LRPROOF, destination type is forced to LINK (0x03)
      # header_type=0, context_flag=0, transport_type=0, dest_type=3 (LINK), packet_type=3 (PROOF)
      # flags = (0 << 6) | (0 << 5) | (0 << 4) | (3 << 2) | 3 = 0x0F
      dest = make_destination(type: 0x00)

      packet =
        Packet.new(dest, "test",
          packet_type: Packet.proof(),
          context: Packet.context_lrproof()
        )

      assert Packet.packed_flags(packet) == 0x0F
    end

    test "packs flags with context_flag set" do
      # header_type=0, context_flag=1, transport_type=0, dest_type=0, packet_type=0
      # flags = (0 << 6) | (1 << 5) | (0 << 4) | (0 << 2) | 0 = 0x20
      dest = make_destination(type: 0x00)
      packet = Packet.new(dest, "test", context_flag: Packet.flag_set())

      assert Packet.packed_flags(packet) == 0x20
    end
  end

  # ── Pack and Unpack ────────────────────────────────────────────────

  describe "pack/1" do
    test "packs an ANNOUNCE packet (HEADER_1, not encrypted)" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      payload = "announce data"
      packet = Packet.new(dest, payload, packet_type: Packet.announce())

      packed = Packet.pack(packet)

      assert packed.packed == true
      assert packed.raw != nil
      assert packed.destination_hash == dest_hash
      assert packed.ciphertext == payload

      # Verify binary structure: flags(1) + hops(1) + dest_hash(16) + context(1) + data
      expected_raw = <<packed.flags::8, 0::8>> <> dest_hash <> <<0x00>> <> payload
      assert packed.raw == expected_raw
    end

    test "packs a LINKREQUEST packet (HEADER_1, not encrypted)" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      payload = :crypto.strong_rand_bytes(32)
      packet = Packet.new(dest, payload, packet_type: Packet.linkrequest())

      packed = Packet.pack(packet)

      assert packed.ciphertext == payload
      assert packed.packed == true
    end

    test "packs a HEADER_2 packet with transport_id" do
      dest_hash = :crypto.strong_rand_bytes(16)
      transport_id = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      payload = "transport data"

      packet =
        Packet.new(dest, payload,
          packet_type: Packet.announce(),
          header_type: Packet.header_2(),
          transport_type: 0x01,
          transport_id: transport_id
        )

      packed = Packet.pack(packet)

      # Verify binary structure: flags(1) + hops(1) + transport_id(16) + dest_hash(16) + context(1) + data
      expected_raw = <<packed.flags::8, 0::8>> <> transport_id <> dest_hash <> <<0x00>> <> payload
      assert packed.raw == expected_raw
    end

    test "packs a HEADER_2 packet without transport_id raises error" do
      dest = make_destination()

      packet =
        Packet.new(dest, "data",
          header_type: Packet.header_2(),
          transport_type: 0x01
        )

      assert_raise RuntimeError, ~r/transport ID/, fn ->
        Packet.pack(packet)
      end
    end

    test "packs LRPROOF context with link_id" do
      link_id = :crypto.strong_rand_bytes(16)
      dest = make_destination(link_id: link_id, type: 0x00)
      proof_data = :crypto.strong_rand_bytes(32)

      packet =
        Packet.new(dest, proof_data,
          packet_type: Packet.proof(),
          context: Packet.context_lrproof()
        )

      packed = Packet.pack(packet)

      # LRPROOF uses link_id instead of dest hash
      expected_raw = <<packed.flags::8, 0::8>> <> link_id <> <<0xFF>> <> proof_data
      assert packed.raw == expected_raw
    end

    test "packs RESOURCE context without encryption" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      resource_data = :crypto.strong_rand_bytes(100)
      packet = Packet.new(dest, resource_data, context: Packet.context_resource())

      packed = Packet.pack(packet)

      assert packed.ciphertext == resource_data
    end

    test "packs KEEPALIVE context without encryption" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      packet = Packet.new(dest, <<>>, context: Packet.context_keepalive())

      packed = Packet.pack(packet)

      assert packed.ciphertext == <<>>
    end

    test "packs CACHE_REQUEST context without encryption" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      packet = Packet.new(dest, "cache req", context: Packet.context_cache_request())

      packed = Packet.pack(packet)

      assert packed.ciphertext == "cache req"
    end

    test "pack raises error when packet exceeds MTU" do
      dest = make_destination()
      # 500 - 19 (header) = 481 max data, so 482 bytes should exceed
      oversized = :crypto.strong_rand_bytes(482)
      packet = Packet.new(dest, oversized, packet_type: Packet.announce())

      assert_raise RuntimeError, ~r/exceeds MTU/, fn ->
        Packet.pack(packet)
      end
    end

    test "pack with encrypted data calls destination encrypt" do
      dest_hash = :crypto.strong_rand_bytes(16)
      plaintext = "secret message"
      encrypted = "ENCRYPTED:" <> plaintext

      dest = make_destination(hash: dest_hash, type: 0x00)
      dest = Map.put(dest, :encrypt, fn _data -> encrypted end)

      packet = Packet.new(dest, plaintext)
      packed = Packet.pack(packet)

      assert packed.ciphertext == encrypted
    end
  end

  describe "unpack/1" do
    test "unpacks a HEADER_1 packet" do
      dest_hash = :crypto.strong_rand_bytes(16)
      payload = "some data"

      # flags: header_type=0, context_flag=0, transport_type=0, dest_type=0 (SINGLE), packet_type=1 (ANNOUNCE)
      flags = 0x01
      raw = <<flags::8, 3::8>> <> dest_hash <> <<0x00>> <> payload

      packet = Packet.new(nil, raw)
      result = Packet.unpack(packet)

      assert result != false
      assert result.header_type == Packet.header_1()
      assert result.packet_type == Packet.announce()
      assert result.transport_type == 0x00
      assert result.destination_type == 0x00
      assert result.context_flag == 0x00
      assert result.destination_hash == dest_hash
      assert result.context == 0x00
      assert result.data == payload
      assert result.hops == 3
      assert result.transport_id == nil
      assert result.packed == false
    end

    test "unpacks a HEADER_2 packet" do
      transport_id = :crypto.strong_rand_bytes(16)
      dest_hash = :crypto.strong_rand_bytes(16)
      payload = "transport data"

      # flags: header_type=1, context_flag=0, transport_type=1, dest_type=0, packet_type=1 (ANNOUNCE)
      flags = 1 <<< 6 ||| 0 <<< 5 ||| 1 <<< 4 ||| 0 <<< 2 ||| 1
      raw = <<flags::8, 5::8>> <> transport_id <> dest_hash <> <<0x00>> <> payload

      packet = Packet.new(nil, raw)
      result = Packet.unpack(packet)

      assert result.header_type == Packet.header_2()
      assert result.packet_type == Packet.announce()
      assert result.transport_type == 0x01
      assert result.transport_id == transport_id
      assert result.destination_hash == dest_hash
      assert result.context == 0x00
      assert result.data == payload
      assert result.hops == 5
    end

    test "unpack returns false for malformed packet" do
      # Too short to contain valid header
      packet = Packet.new(nil, <<0x00>>)
      result = Packet.unpack(packet)

      assert result == false
    end

    test "unpack sets packed to false" do
      dest_hash = :crypto.strong_rand_bytes(16)
      raw = <<0x00, 0x00>> <> dest_hash <> <<0x00>> <> "data"
      packet = Packet.new(nil, raw)
      result = Packet.unpack(packet)

      assert result.packed == false
    end
  end

  describe "pack/unpack roundtrip" do
    test "HEADER_1 ANNOUNCE roundtrip preserves all fields" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      payload = :crypto.strong_rand_bytes(64)

      packed = Packet.new(dest, payload, packet_type: Packet.announce()) |> Packet.pack()
      unpacked = Packet.new(nil, packed.raw) |> Packet.unpack()

      assert unpacked.destination_hash == dest_hash
      assert unpacked.data == payload
      assert unpacked.packet_type == Packet.announce()
      assert unpacked.hops == 0
      assert unpacked.context == 0x00
    end

    test "HEADER_2 ANNOUNCE roundtrip preserves all fields" do
      dest_hash = :crypto.strong_rand_bytes(16)
      transport_id = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      payload = :crypto.strong_rand_bytes(32)

      packed =
        Packet.new(dest, payload,
          packet_type: Packet.announce(),
          header_type: Packet.header_2(),
          transport_type: 0x01,
          transport_id: transport_id
        )
        |> Packet.pack()

      unpacked = Packet.new(nil, packed.raw) |> Packet.unpack()

      assert unpacked.destination_hash == dest_hash
      assert unpacked.transport_id == transport_id
      assert unpacked.data == payload
      assert unpacked.packet_type == Packet.announce()
      assert unpacked.header_type == Packet.header_2()
      assert unpacked.transport_type == 0x01
    end

    test "LINKREQUEST roundtrip" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      payload = :crypto.strong_rand_bytes(48)

      packed = Packet.new(dest, payload, packet_type: Packet.linkrequest()) |> Packet.pack()
      unpacked = Packet.new(nil, packed.raw) |> Packet.unpack()

      assert unpacked.destination_hash == dest_hash
      assert unpacked.data == payload
      assert unpacked.packet_type == Packet.linkrequest()
    end
  end

  # ── Hash computation ───────────────────────────────────────────────

  describe "hash/1" do
    test "returns SHA-256 hash of hashable part" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      packet = Packet.new(dest, "test data", packet_type: Packet.announce()) |> Packet.pack()

      hash = Packet.hash(packet)

      assert byte_size(hash) == 32
      assert is_binary(hash)
    end

    test "same packet produces same hash" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      data = "deterministic"

      p1 = Packet.new(dest, data, packet_type: Packet.announce()) |> Packet.pack()
      p2 = Packet.new(dest, data, packet_type: Packet.announce()) |> Packet.pack()

      assert Packet.hash(p1) == Packet.hash(p2)
    end

    test "different data produces different hash" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)

      p1 = Packet.new(dest, "data1", packet_type: Packet.announce()) |> Packet.pack()
      p2 = Packet.new(dest, "data2", packet_type: Packet.announce()) |> Packet.pack()

      assert Packet.hash(p1) != Packet.hash(p2)
    end
  end

  describe "truncated_hash/1" do
    test "returns 16-byte truncated hash" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()

      truncated = Packet.truncated_hash(packet)

      assert byte_size(truncated) == 16
    end
  end

  describe "hashable_part/1" do
    test "HEADER_1: masks upper nibble of flags and includes from byte 2 onward" do
      dest_hash = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()

      hashable = Packet.hashable_part(packet)

      # First byte is flags & 0x0F (lower nibble only)
      <<masked_flags::8, rest::binary>> = hashable
      assert masked_flags == (packet.flags &&& 0x0F)
      # Rest is raw[2:] (everything after flags+hops)
      assert rest == binary_part(packet.raw, 2, byte_size(packet.raw) - 2)
    end

    test "HEADER_2: skips transport_id in hashable part" do
      dest_hash = :crypto.strong_rand_bytes(16)
      transport_id = :crypto.strong_rand_bytes(16)
      dest = make_destination(hash: dest_hash, type: 0x00)

      packet =
        Packet.new(dest, "test",
          packet_type: Packet.announce(),
          header_type: Packet.header_2(),
          transport_type: 0x01,
          transport_id: transport_id
        )
        |> Packet.pack()

      hashable = Packet.hashable_part(packet)

      # First byte is flags & 0x0F
      <<masked_flags::8, rest::binary>> = hashable
      assert masked_flags == (packet.flags &&& 0x0F)
      # Rest skips the transport_id (16 bytes after flags+hops)
      assert rest == binary_part(packet.raw, 18, byte_size(packet.raw) - 18)
    end
  end

  describe "update_hash/1" do
    test "sets packet_hash on the packet" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()

      updated = Packet.update_hash(packet)

      assert updated.packet_hash != nil
      assert byte_size(updated.packet_hash) == 32
      assert updated.packet_hash == Packet.hash(packet)
    end
  end

  # ── PacketReceipt ──────────────────────────────────────────────────

  describe "PacketReceipt constants" do
    test "FAILED is 0x00" do
      assert PacketReceipt.failed() == 0x00
    end

    test "SENT is 0x01" do
      assert PacketReceipt.sent() == 0x01
    end

    test "DELIVERED is 0x02" do
      assert PacketReceipt.delivered() == 0x02
    end

    test "CULLED is 0xFF" do
      assert PacketReceipt.culled() == 0xFF
    end

    test "EXPL_LENGTH is hash_length + sig_length in bytes" do
      # HASHLENGTH//8 + SIGLENGTH//8 = 256//8 + 512//8 = 32 + 64 = 96
      assert PacketReceipt.expl_length() == 96
    end

    test "IMPL_LENGTH is sig_length in bytes" do
      # SIGLENGTH//8 = 512//8 = 64
      assert PacketReceipt.impl_length() == 64
    end
  end

  describe "PacketReceipt creation" do
    test "creates receipt from packed packet" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()

      receipt = PacketReceipt.new(packet)

      assert receipt.hash == Packet.hash(packet)
      assert receipt.truncated_hash == Packet.truncated_hash(packet)
      assert receipt.sent == true
      assert receipt.status == PacketReceipt.sent()
      assert receipt.proved == false
      assert receipt.concluded_at == nil
      assert receipt.proof_packet == nil
      assert receipt.destination == dest
    end
  end

  describe "PacketReceipt status" do
    test "status returns current status" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)

      assert PacketReceipt.status(receipt) == PacketReceipt.sent()
    end
  end

  describe "PacketReceipt timeout" do
    test "set_timeout updates timeout value" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)

      updated = PacketReceipt.set_timeout(receipt, 30.0)

      assert updated.timeout == 30.0
    end

    test "is_timed_out returns false for fresh receipt" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet) |> PacketReceipt.set_timeout(60.0)

      refute PacketReceipt.is_timed_out(receipt)
    end

    test "is_timed_out returns true for expired receipt" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)
      # Set sent_at far in the past
      receipt = %{receipt | sent_at: System.system_time(:second) - 1000, timeout: 1.0}

      assert PacketReceipt.is_timed_out(receipt)
    end
  end

  describe "PacketReceipt callbacks" do
    test "set_delivery_callback stores callback" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)
      callback = fn _receipt -> :delivered end

      updated = PacketReceipt.set_delivery_callback(receipt, callback)

      assert updated.callbacks.delivery == callback
    end

    test "set_timeout_callback stores callback" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)
      callback = fn _receipt -> :timed_out end

      updated = PacketReceipt.set_timeout_callback(receipt, callback)

      assert updated.callbacks.timeout == callback
    end
  end

  describe "PacketReceipt check_timeout" do
    test "marks receipt as FAILED when timed out with positive timeout" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)
      receipt = %{receipt | sent_at: System.system_time(:second) - 100, timeout: 1.0}

      updated = PacketReceipt.check_timeout(receipt)

      assert updated.status == PacketReceipt.failed()
      assert updated.concluded_at != nil
    end

    test "marks receipt as CULLED when timed out with timeout of -1" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)
      receipt = %{receipt | sent_at: System.system_time(:second) - 100, timeout: -1}

      updated = PacketReceipt.check_timeout(receipt)

      assert updated.status == PacketReceipt.culled()
    end

    test "does not change status when not timed out" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet) |> PacketReceipt.set_timeout(60.0)

      updated = PacketReceipt.check_timeout(receipt)

      assert updated.status == PacketReceipt.sent()
    end

    test "invokes timeout callback when timing out" do
      test_pid = self()
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)
      receipt = %{receipt | sent_at: System.system_time(:second) - 100, timeout: 1.0}

      receipt =
        PacketReceipt.set_timeout_callback(receipt, fn r ->
          send(test_pid, {:timeout, r.status})
        end)

      PacketReceipt.check_timeout(receipt)

      assert_receive {:timeout, _status}, 1000
    end
  end

  describe "PacketReceipt rtt" do
    test "returns round-trip time" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      receipt = PacketReceipt.new(packet)
      now = System.system_time(:second)
      receipt = %{receipt | sent_at: now - 5, concluded_at: now}

      assert PacketReceipt.rtt(receipt) == 5
    end
  end

  # ── ProofDestination ───────────────────────────────────────────────

  describe "ProofDestination" do
    test "creates proof destination from packet" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()

      proof_dest = ProofDestination.new(packet)

      assert byte_size(proof_dest.hash) == 16
      # SINGLE
      assert proof_dest.type == 0x00
    end

    test "proof destination hash is truncated packet hash" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()

      proof_dest = ProofDestination.new(packet)
      expected_hash = binary_part(Packet.hash(packet), 0, 16)

      assert proof_dest.hash == expected_hash
    end

    test "encrypt returns plaintext unchanged" do
      dest = make_destination()
      packet = Packet.new(dest, "test", packet_type: Packet.announce()) |> Packet.pack()
      proof_dest = ProofDestination.new(packet)

      assert ProofDestination.encrypt(proof_dest, "hello") == "hello"
    end
  end

  # ── Send / Resend via Transport ───────────────────────────────────

  describe "send/1" do
    test "calls Transport.outbound and returns nil when no receipt requested" do
      test_pid = self()

      iface = make_test_interface("SendIface1", test_pid)
      Transport.register_interface(iface)

      dest = make_destination()
      packet = Packet.new(dest, "hello", create_receipt: false)

      result = Packet.send(packet)
      # With create_receipt: false, successful send returns nil
      assert result == nil
      assert_receive {:sent_on, "SendIface1", _raw}
    end

    test "calls Transport.outbound and returns receipt when requested" do
      test_pid = self()

      iface = make_test_interface("SendIface2", test_pid)
      Transport.register_interface(iface)

      dest = make_destination()
      packet = Packet.new(dest, "hello", create_receipt: true)

      result = Packet.send(packet)
      assert %PacketReceipt{} = result
      assert result.sent == true
      assert_receive {:sent_on, "SendIface2", _raw}
    end

    test "returns false when no interfaces are registered" do
      dest = make_destination()
      packet = Packet.new(dest, "hello", create_receipt: true)

      assert Packet.send(packet) == false
    end

    test "raises when packet was already sent" do
      test_pid = self()

      iface = make_test_interface("SendIface3", test_pid)
      Transport.register_interface(iface)

      dest = make_destination()
      packet = Packet.new(dest, "hello")
      # Manually mark as sent
      packet = %{packet | sent: true}

      assert_raise RuntimeError, "Packet was already sent", fn ->
        Packet.send(packet)
      end
    end

    test "drops packet over closed link destination" do
      dest = %{
        hash: :crypto.strong_rand_bytes(16),
        type: 0x03,
        status: 0x04,
        mtu: 500
      }

      packet = Packet.new(dest, "hello")
      assert Packet.send(packet) == false
    end

    test "packs unpacked packet before sending" do
      test_pid = self()

      iface = make_test_interface("SendIface4", test_pid)
      Transport.register_interface(iface)

      dest = make_destination()
      packet = Packet.new(dest, "hello")
      assert packet.packed == false

      Packet.send(packet)
      assert_receive {:sent_on, "SendIface4", raw}
      # raw should be a valid binary (pack was called)
      assert is_binary(raw)
      assert byte_size(raw) > 0
    end
  end

  describe "resend/1" do
    test "raises when packet was not sent yet" do
      dest = make_destination()
      packet = Packet.new(dest, "hello")

      assert_raise RuntimeError, "Packet was not sent yet", fn ->
        Packet.resend(packet)
      end
    end

    test "re-sends a previously sent packet" do
      test_pid = self()

      iface = make_test_interface("ResendIface", test_pid)
      Transport.register_interface(iface)

      dest = make_destination()
      packet = Packet.new(dest, "hello", create_receipt: false)
      # Mark as already sent and pack it (simulating previous send)
      packet = %{Packet.pack(packet) | sent: true}

      result = Packet.resend(packet)
      assert result == nil
      assert_receive {:sent_on, "ResendIface", _raw}
    end
  end

  # ── Test helpers ───────────────────────────────────────────────────

  defp make_test_interface(name, test_pid) do
    hash = RNS.Cryptography.Hashes.truncated_hash(name)

    %{
      name: name,
      hash: hash,
      online: true,
      out: true,
      bitrate: 1_000_000,
      process_outgoing: fn raw -> send(test_pid, {:sent_on, name, raw}) end
    }
  end
end
