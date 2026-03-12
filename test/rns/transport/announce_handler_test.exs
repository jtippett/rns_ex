defmodule RNS.Transport.AnnounceHandlerTest do
  use ExUnit.Case, async: false

  alias RNS.Transport
  alias RNS.Transport.AnnounceHandler
  alias RNS.Transport.AnnounceHandler.AnnounceEntry

  setup do
    # Restart Transport for clean ETS tables
    try do
      case GenServer.whereis(RNS.Transport) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end
    catch
      :exit, _ -> :ok
    end

    Process.sleep(10)
    {:ok, _pid} = Transport.start_link([])

    # Restart IdentityStore for clean ETS
    try do
      case GenServer.whereis(RNS.IdentityStore) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end
    catch
      :exit, _ -> :ok
    end

    Process.sleep(10)
    {:ok, _pid} = RNS.IdentityStore.start_link([])

    :ok
  end

  # ── AnnounceEntry struct ──────────────────────────────────────────

  describe "AnnounceEntry struct" do
    test "has all required fields" do
      entry = %AnnounceEntry{}
      assert Map.has_key?(entry, :timestamp)
      assert Map.has_key?(entry, :retransmit_timeout)
      assert Map.has_key?(entry, :retries)
      assert Map.has_key?(entry, :received_from)
      assert Map.has_key?(entry, :hops)
      assert Map.has_key?(entry, :packet)
      assert Map.has_key?(entry, :local_rebroadcasts)
      assert Map.has_key?(entry, :block_rebroadcasts)
      assert Map.has_key?(entry, :attached_interface)
    end

    test "defaults to zero/false/nil values" do
      entry = %AnnounceEntry{}
      assert entry.timestamp == nil
      assert entry.retries == nil
      assert entry.local_rebroadcasts == nil
      assert entry.block_rebroadcasts == nil
      assert entry.attached_interface == nil
    end
  end

  # ── Announce Table Operations ─────────────────────────────────────

  describe "put_announce_entry/2 and get_announce_entry/1" do
    test "stores and retrieves an announce entry" do
      hash = :crypto.strong_rand_bytes(16)
      entry = make_announce_entry()

      AnnounceHandler.put_announce_entry(hash, entry)
      retrieved = Transport.get_announce_entry(hash)

      assert retrieved.timestamp == entry.timestamp
      assert retrieved.hops == entry.hops
      assert retrieved.retries == entry.retries
    end

    test "returns nil for unknown hash" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.get_announce_entry(hash) == nil
    end

    test "overwrites existing entry" do
      hash = :crypto.strong_rand_bytes(16)
      entry1 = make_announce_entry(hops: 2)
      entry2 = make_announce_entry(hops: 5)

      AnnounceHandler.put_announce_entry(hash, entry1)
      AnnounceHandler.put_announce_entry(hash, entry2)

      retrieved = Transport.get_announce_entry(hash)
      assert retrieved.hops == 5
    end
  end

  describe "delete_announce_entry/1" do
    test "removes an announce entry" do
      hash = :crypto.strong_rand_bytes(16)
      entry = make_announce_entry()

      AnnounceHandler.put_announce_entry(hash, entry)
      assert Transport.get_announce_entry(hash) != nil

      AnnounceHandler.delete_announce_entry(hash)
      assert Transport.get_announce_entry(hash) == nil
    end

    test "no-op for unknown hash" do
      hash = :crypto.strong_rand_bytes(16)
      AnnounceHandler.delete_announce_entry(hash)
      assert Transport.get_announce_entry(hash) == nil
    end
  end

  # ── Timebase / Random Blob Helpers ────────────────────────────────

  describe "timebase_from_random_blob/1" do
    test "extracts emission timestamp from bytes 5-10 of a 10-byte blob" do
      # Emission time = 1_000_000 = 0x000F4240
      # Encoded as 5 bytes big-endian at positions 5..9
      emission_time = 1_000_000
      prefix = :crypto.strong_rand_bytes(5)
      suffix = <<emission_time::unsigned-big-integer-size(40)>>
      blob = prefix <> suffix

      assert AnnounceHandler.timebase_from_random_blob(blob) == emission_time
    end

    test "handles zero emission time" do
      blob = :crypto.strong_rand_bytes(5) <> <<0::40>>
      assert AnnounceHandler.timebase_from_random_blob(blob) == 0
    end

    test "handles max 5-byte value" do
      max_val = 0xFFFFFFFFFF
      blob = :crypto.strong_rand_bytes(5) <> <<max_val::unsigned-big-integer-size(40)>>
      assert AnnounceHandler.timebase_from_random_blob(blob) == max_val
    end
  end

  describe "timebase_from_random_blobs/1" do
    test "returns maximum emission timestamp from list of blobs" do
      blob1 = make_random_blob(100)
      blob2 = make_random_blob(500)
      blob3 = make_random_blob(300)

      assert AnnounceHandler.timebase_from_random_blobs([blob1, blob2, blob3]) == 500
    end

    test "returns 0 for empty list" do
      assert AnnounceHandler.timebase_from_random_blobs([]) == 0
    end

    test "handles single blob" do
      blob = make_random_blob(42)
      assert AnnounceHandler.timebase_from_random_blobs([blob]) == 42
    end
  end

  describe "announce_emitted/1" do
    test "extracts emission time from packet data" do
      emission_time = 12345
      packet = make_announce_packet(emission_time: emission_time)
      assert AnnounceHandler.announce_emitted(packet) == emission_time
    end
  end

  describe "extract_random_blob/1" do
    test "extracts 10-byte random blob from announce packet data" do
      emission_time = 99999
      packet = make_announce_packet(emission_time: emission_time)
      blob = AnnounceHandler.extract_random_blob(packet)
      assert byte_size(blob) == 10
      # The emission time should be recoverable
      assert AnnounceHandler.timebase_from_random_blob(blob) == emission_time
    end
  end

  # ── Rate Limiting ─────────────────────────────────────────────────

  describe "check_announce_rate/3" do
    test "first announce is never rate blocked" do
      hash = :crypto.strong_rand_bytes(16)
      interface = make_interface(announce_rate_target: 30)

      {rate_blocked, _} = AnnounceHandler.check_announce_rate(hash, interface)
      refute rate_blocked
    end

    test "announce within rate target triggers violation" do
      hash = :crypto.strong_rand_bytes(16)
      interface = make_interface(announce_rate_target: 30, announce_rate_grace: 0, announce_rate_penalty: 60)

      # First announce establishes baseline
      AnnounceHandler.check_announce_rate(hash, interface)

      # Second announce immediately (within rate target) - should cause violation
      # But with grace = 0, first violation should block
      # Actually with grace 0, violations > 0 is immediately > grace
      {rate_blocked, _} = AnnounceHandler.check_announce_rate(hash, interface)
      assert rate_blocked
    end

    test "announce outside rate target does not block" do
      hash = :crypto.strong_rand_bytes(16)
      # rate target of 0 means any interval is acceptable
      interface = make_interface(announce_rate_target: 0, announce_rate_grace: 5, announce_rate_penalty: 60)

      AnnounceHandler.check_announce_rate(hash, interface)
      {rate_blocked, _} = AnnounceHandler.check_announce_rate(hash, interface)
      refute rate_blocked
    end

    test "nil announce_rate_target skips rate limiting" do
      hash = :crypto.strong_rand_bytes(16)
      interface = make_interface(announce_rate_target: nil)

      {rate_blocked, _} = AnnounceHandler.check_announce_rate(hash, interface)
      refute rate_blocked
    end

    test "blocked_until prevents further announces" do
      hash = :crypto.strong_rand_bytes(16)
      interface = make_interface(announce_rate_target: 999_999, announce_rate_grace: 0, announce_rate_penalty: 60)

      # First announce establishes rate entry
      AnnounceHandler.check_announce_rate(hash, interface)
      # Second immediately - triggers block
      AnnounceHandler.check_announce_rate(hash, interface)
      # Third while still blocked
      {rate_blocked, _} = AnnounceHandler.check_announce_rate(hash, interface)
      assert rate_blocked
    end
  end

  # ── should_add Decision Logic ─────────────────────────────────────

  describe "should_add_path?/3" do
    test "adds unknown destination" do
      hash = :crypto.strong_rand_bytes(16)
      blob = make_random_blob(100)
      packet = make_announce_packet_with_blob(blob, hops: 1)

      assert AnnounceHandler.should_add_path?(hash, packet, blob)
    end

    test "adds when hop count is equal and emission is newer" do
      hash = :crypto.strong_rand_bytes(16)
      old_blob = make_random_blob(100)
      new_blob = make_random_blob(200)

      # Add existing path with old blob, 3 hops
      add_path_entry(hash, hops: 3, random_blobs: [old_blob])

      packet = make_announce_packet_with_blob(new_blob, hops: 3)
      assert AnnounceHandler.should_add_path?(hash, packet, new_blob)
    end

    test "adds when hop count is less and emission is newer" do
      hash = :crypto.strong_rand_bytes(16)
      old_blob = make_random_blob(100)
      new_blob = make_random_blob(200)

      add_path_entry(hash, hops: 5, random_blobs: [old_blob])

      packet = make_announce_packet_with_blob(new_blob, hops: 2)
      assert AnnounceHandler.should_add_path?(hash, packet, new_blob)
    end

    test "rejects when blob already seen (replay protection)" do
      hash = :crypto.strong_rand_bytes(16)
      blob = make_random_blob(100)

      add_path_entry(hash, hops: 3, random_blobs: [blob])

      packet = make_announce_packet_with_blob(blob, hops: 3)
      refute AnnounceHandler.should_add_path?(hash, packet, blob)
    end

    test "rejects when hop count is worse and path not expired and emission not newer" do
      hash = :crypto.strong_rand_bytes(16)
      old_blob = make_random_blob(200)
      new_blob = make_random_blob(100)  # older emission

      add_path_entry(hash, hops: 2, random_blobs: [old_blob],
        expires: System.system_time(:second) + 3600)

      packet = make_announce_packet_with_blob(new_blob, hops: 5)
      refute AnnounceHandler.should_add_path?(hash, packet, new_blob)
    end

    test "adds when hop count is worse but path expired" do
      hash = :crypto.strong_rand_bytes(16)
      old_blob = make_random_blob(100)
      new_blob = make_random_blob(200)

      add_path_entry(hash, hops: 2, random_blobs: [old_blob],
        expires: System.system_time(:second) - 100)

      packet = make_announce_packet_with_blob(new_blob, hops: 5)
      assert AnnounceHandler.should_add_path?(hash, packet, new_blob)
    end

    test "adds when hop count is worse but emission is more recent" do
      hash = :crypto.strong_rand_bytes(16)
      old_blob = make_random_blob(100)
      new_blob = make_random_blob(200)

      add_path_entry(hash, hops: 2, random_blobs: [old_blob],
        expires: System.system_time(:second) + 3600)

      packet = make_announce_packet_with_blob(new_blob, hops: 5)
      assert AnnounceHandler.should_add_path?(hash, packet, new_blob)
    end

    test "adds when same emission but path is unresponsive" do
      hash = :crypto.strong_rand_bytes(16)
      old_blob = make_random_blob(100)
      new_blob = make_random_blob(100)  # same emission time, different blob

      add_path_entry(hash, hops: 2, random_blobs: [old_blob],
        expires: System.system_time(:second) + 3600)
      Transport.mark_path_unresponsive(hash)

      packet = make_announce_packet_with_blob(new_blob, hops: 5)
      assert AnnounceHandler.should_add_path?(hash, packet, new_blob)
    end

    test "rejects when same emission and path is responsive" do
      hash = :crypto.strong_rand_bytes(16)
      blob = make_random_blob(100)
      new_blob = make_random_blob_with_same_emission(100, blob)

      add_path_entry(hash, hops: 2, random_blobs: [blob],
        expires: System.system_time(:second) + 3600)

      packet = make_announce_packet_with_blob(new_blob, hops: 5)
      refute AnnounceHandler.should_add_path?(hash, packet, new_blob)
    end

    test "rejects when hops exceed PATHFINDER_M" do
      hash = :crypto.strong_rand_bytes(16)
      blob = make_random_blob(100)

      packet = make_announce_packet_with_blob(blob, hops: 129)
      refute AnnounceHandler.should_add_path?(hash, packet, blob)
    end

    test "rejects when destination is local" do
      hash = :crypto.strong_rand_bytes(16)
      blob = make_random_blob(100)

      # Register a local destination with this hash
      dest = %{hash: hash, direction: 0x11, type: 0x00, mtu: 500}
      Transport.register_destination(dest)

      packet = make_announce_packet_with_blob(blob, hops: 1)
      refute AnnounceHandler.should_add_path?(hash, packet, blob)
    end
  end

  # ── Process Announce Queue ────────────────────────────────────────

  describe "process_announce_queue/0" do
    test "removes entries that exceed retry limit" do
      hash = :crypto.strong_rand_bytes(16)
      entry = make_announce_entry(
        retries: Transport.pathfinder_r() + 1,
        retransmit_timeout: 0.0
      )

      AnnounceHandler.put_announce_entry(hash, entry)
      {_outgoing, completed} = AnnounceHandler.process_announce_queue()

      assert hash in completed
      assert Transport.get_announce_entry(hash) == nil
    end

    test "removes entries that exceed local rebroadcast limit with retries > 0" do
      hash = :crypto.strong_rand_bytes(16)
      entry = make_announce_entry(
        retries: 1,
        local_rebroadcasts: Transport.local_rebroadcasts_max(),
        retransmit_timeout: System.system_time(:second) + 9999
      )

      AnnounceHandler.put_announce_entry(hash, entry)
      {_outgoing, completed} = AnnounceHandler.process_announce_queue()

      assert hash in completed
      assert Transport.get_announce_entry(hash) == nil
    end

    test "increments retries and updates timeout when retransmit time reached" do
      hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      # Make a minimal packet-like map for retransmission
      packet = make_announce_packet(emission_time: now)
      entry = make_announce_entry(
        retries: 0,
        retransmit_timeout: now - 10,
        packet: packet,
        hops: 2,
        block_rebroadcasts: false,
        attached_interface: nil
      )

      AnnounceHandler.put_announce_entry(hash, entry)
      {_outgoing, completed} = AnnounceHandler.process_announce_queue()

      # Should not be completed (retries was 0, now 1 which is <= PATHFINDER_R)
      refute hash in completed

      # Entry should have been updated
      updated = Transport.get_announce_entry(hash)
      assert updated.retries == 1
      assert updated.retransmit_timeout > now
    end

    test "does not process entries whose retransmit timeout hasn't been reached" do
      hash = :crypto.strong_rand_bytes(16)
      future_time = System.system_time(:second) + 9999

      entry = make_announce_entry(
        retries: 0,
        retransmit_timeout: future_time
      )

      AnnounceHandler.put_announce_entry(hash, entry)
      {outgoing, completed} = AnnounceHandler.process_announce_queue()

      assert outgoing == []
      assert completed == []

      # Entry should be unchanged
      unchanged = Transport.get_announce_entry(hash)
      assert unchanged.retries == 0
    end
  end

  # ── Rebroadcast Tracking ──────────────────────────────────────────

  describe "handle_rebroadcast_tracking/3" do
    test "increments local_rebroadcasts when hops-1 matches entry hops" do
      hash = :crypto.strong_rand_bytes(16)
      entry = make_announce_entry(hops: 3, retries: 0, local_rebroadcasts: 0)
      AnnounceHandler.put_announce_entry(hash, entry)

      # Packet with hops = 4 (hops-1 == 3 == entry.hops)
      AnnounceHandler.handle_rebroadcast_tracking(hash, 4, entry)

      updated = Transport.get_announce_entry(hash)
      assert updated.local_rebroadcasts == 1
    end

    test "removes entry when local rebroadcasts reach limit and retries > 0" do
      hash = :crypto.strong_rand_bytes(16)
      entry = make_announce_entry(
        hops: 3,
        retries: 1,
        local_rebroadcasts: Transport.local_rebroadcasts_max() - 1
      )
      AnnounceHandler.put_announce_entry(hash, entry)

      # This increments to LOCAL_REBROADCASTS_MAX
      AnnounceHandler.handle_rebroadcast_tracking(hash, 4, entry)

      assert Transport.get_announce_entry(hash) == nil
    end

    test "removes entry when next hop has picked it up (hops-1 == entry.hops+1)" do
      hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)
      entry = make_announce_entry(
        hops: 3,
        retries: 1,
        retransmit_timeout: now + 100  # not yet timed out
      )
      AnnounceHandler.put_announce_entry(hash, entry)

      # Packet with hops = 5 (hops-1 == 4 == entry.hops+1) and retries > 0, before timeout
      AnnounceHandler.handle_rebroadcast_tracking(hash, 5, entry)

      assert Transport.get_announce_entry(hash) == nil
    end

    test "does not remove when next hop picked up but timeout already passed" do
      hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)
      entry = make_announce_entry(
        hops: 3,
        retries: 1,
        retransmit_timeout: now - 100  # already timed out
      )
      AnnounceHandler.put_announce_entry(hash, entry)

      # Packet with hops-1 == entry.hops+1 but timeout passed
      AnnounceHandler.handle_rebroadcast_tracking(hash, 5, entry)

      # Entry should still exist
      assert Transport.get_announce_entry(hash) != nil
    end
  end

  # ── Expiry Calculation ────────────────────────────────────────────

  describe "calculate_path_expiry/1" do
    test "uses AP_PATH_TIME for access point mode interfaces" do
      interface = make_interface(mode: :mode_access_point)
      expiry = AnnounceHandler.calculate_path_expiry(interface)
      now = System.system_time(:second)

      assert_in_delta expiry, now + Transport.ap_path_time(), 2
    end

    test "uses ROAMING_PATH_TIME for roaming mode interfaces" do
      interface = make_interface(mode: :mode_roaming)
      expiry = AnnounceHandler.calculate_path_expiry(interface)
      now = System.system_time(:second)

      assert_in_delta expiry, now + Transport.roaming_path_time(), 2
    end

    test "uses PATHFINDER_E for other interfaces" do
      interface = make_interface(mode: :mode_full)
      expiry = AnnounceHandler.calculate_path_expiry(interface)
      now = System.system_time(:second)

      assert_in_delta expiry, now + Transport.pathfinder_e(), 2
    end

    test "uses PATHFINDER_E when mode is nil" do
      interface = make_interface(mode: nil)
      expiry = AnnounceHandler.calculate_path_expiry(interface)
      now = System.system_time(:second)

      assert_in_delta expiry, now + Transport.pathfinder_e(), 2
    end
  end

  # ── Update Random Blobs ──────────────────────────────────────────

  describe "update_random_blobs/2" do
    test "adds new blob to empty list" do
      blob = make_random_blob(100)
      result = AnnounceHandler.update_random_blobs([], blob)
      assert result == [blob]
    end

    test "adds new blob to existing list" do
      blob1 = make_random_blob(100)
      blob2 = make_random_blob(200)
      result = AnnounceHandler.update_random_blobs([blob1], blob2)
      assert result == [blob1, blob2]
    end

    test "does not add duplicate blob" do
      blob = make_random_blob(100)
      result = AnnounceHandler.update_random_blobs([blob], blob)
      assert result == [blob]
    end

    test "truncates to MAX_RANDOM_BLOBS" do
      # Create MAX_RANDOM_BLOBS + 1 blobs
      max = Transport.max_random_blobs()
      existing = for i <- 1..max, do: make_random_blob(i)
      new_blob = make_random_blob(max + 1)

      result = AnnounceHandler.update_random_blobs(existing, new_blob)
      assert length(result) == max
      # The oldest blob should be dropped
      refute List.first(existing) in result
      assert new_blob in result
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp make_announce_entry(opts \\ []) do
    %AnnounceEntry{
      timestamp: opts[:timestamp] || System.system_time(:second),
      retransmit_timeout: opts[:retransmit_timeout] || System.system_time(:second) + 5,
      retries: opts[:retries] || 0,
      received_from: opts[:received_from] || :crypto.strong_rand_bytes(16),
      hops: opts[:hops] || 1,
      packet: opts[:packet] || make_announce_packet(),
      local_rebroadcasts: opts[:local_rebroadcasts] || 0,
      block_rebroadcasts: opts[:block_rebroadcasts] || false,
      attached_interface: opts[:attached_interface]
    }
  end

  defp make_random_blob(emission_time) do
    prefix = :crypto.strong_rand_bytes(5)
    suffix = <<emission_time::unsigned-big-integer-size(40)>>
    prefix <> suffix
  end

  defp make_random_blob_with_same_emission(emission_time, existing_blob) do
    # Same emission time but different prefix to make unique blob
    new_prefix = :crypto.strong_rand_bytes(5)
    # Ensure different from existing
    existing_prefix = binary_part(existing_blob, 0, 5)
    prefix = if new_prefix == existing_prefix, do: :crypto.strong_rand_bytes(5), else: new_prefix
    suffix = <<emission_time::unsigned-big-integer-size(40)>>
    prefix <> suffix
  end

  defp make_announce_packet(opts \\ []) do
    emission_time = opts[:emission_time] || System.system_time(:second)
    hops = opts[:hops] || 1

    # Announce data layout:
    # - public_key: KEYSIZE//8 = 64 bytes
    # - name_hash: NAME_HASH_LENGTH//8 = 10 bytes
    # - random_blob: 10 bytes (bytes 5-10 contain emission timestamp)
    # - signature: SIGLENGTH//8 = 64 bytes
    pub_key = :crypto.strong_rand_bytes(64)
    name_hash = :crypto.strong_rand_bytes(10)
    random_prefix = :crypto.strong_rand_bytes(5)
    random_suffix = <<emission_time::unsigned-big-integer-size(40)>>
    random_blob = random_prefix <> random_suffix
    signature = :crypto.strong_rand_bytes(64)

    data = pub_key <> name_hash <> random_blob <> signature

    %{
      data: data,
      hops: hops,
      destination_hash: opts[:destination_hash] || :crypto.strong_rand_bytes(16),
      transport_id: opts[:transport_id],
      packet_type: 0x01,
      context: opts[:context] || 0x00,
      context_flag: opts[:context_flag] || 0x00,
      receiving_interface: opts[:receiving_interface] || make_interface(),
      packet_hash: opts[:packet_hash] || :crypto.strong_rand_bytes(16)
    }
  end

  defp make_announce_packet_with_blob(blob, opts) do
    hops = opts[:hops] || 1

    pub_key = :crypto.strong_rand_bytes(64)
    name_hash = :crypto.strong_rand_bytes(10)
    signature = :crypto.strong_rand_bytes(64)

    data = pub_key <> name_hash <> blob <> signature

    %{
      data: data,
      hops: hops,
      destination_hash: opts[:destination_hash] || :crypto.strong_rand_bytes(16),
      transport_id: opts[:transport_id],
      packet_type: 0x01,
      context: opts[:context] || 0x00,
      context_flag: opts[:context_flag] || 0x00,
      receiving_interface: opts[:receiving_interface] || make_interface(),
      packet_hash: opts[:packet_hash] || :crypto.strong_rand_bytes(16)
    }
  end

  defp make_interface(opts \\ []) do
    name = opts[:name] || "TestInterface#{:erlang.unique_integer([:positive])}"
    hash = RNS.Cryptography.Hashes.truncated_hash(name)

    %{
      name: name,
      hash: hash,
      online: true,
      bitrate: 1_000_000,
      mode: opts[:mode] || :mode_full,
      announce_rate_target: opts[:announce_rate_target],
      announce_rate_grace: opts[:announce_rate_grace] || 5,
      announce_rate_penalty: opts[:announce_rate_penalty] || 60
    }
  end

  defp add_path_entry(destination_hash, opts) do
    entry = %Transport.PathEntry{
      timestamp: opts[:timestamp] || System.system_time(:second),
      next_hop: opts[:next_hop] || :crypto.strong_rand_bytes(16),
      hops: opts[:hops] || 1,
      expires: opts[:expires] || System.system_time(:second) + Transport.pathfinder_e(),
      random_blobs: opts[:random_blobs] || [],
      interface: opts[:interface] || make_interface(),
      packet_hash: opts[:packet_hash] || :crypto.strong_rand_bytes(16)
    }

    Transport.put_path_entry(destination_hash, entry)
  end
end
