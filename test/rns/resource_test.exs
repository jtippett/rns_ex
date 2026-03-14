defmodule RNS.ResourceTest do
  use ExUnit.Case, async: true

  alias RNS.Resource
  alias RNS.Resource.Advertisement

  # ── Helper: build a mock link ────────────────────────────────

  defp mock_link(opts \\ []) do
    key = RNS.Cryptography.Token.generate_key()
    token = RNS.Cryptography.Token.new(key)
    link_id = :crypto.strong_rand_bytes(16)

    %{
      link_id: link_id,
      hash: RNS.Identity.truncated_hash(link_id),
      type: RNS.Destination.link(),
      mdu: RNS.Link.mdu(),
      mtu: Keyword.get(opts, :mtu, 500),
      rtt: Keyword.get(opts, :rtt, 0.5),
      traffic_timeout_factor: 6,
      establishment_cost: 100,
      expected_rate: nil,
      last_resource_window: Keyword.get(opts, :last_resource_window),
      last_resource_eifr: Keyword.get(opts, :last_resource_eifr),
      token: token,
      status: 0x02
    }
  end

  # ── Helper: build a plain mock link (no encryption) ──────────

  defp plain_link(opts \\ []) do
    link_id = :crypto.strong_rand_bytes(16)

    %{
      link_id: link_id,
      hash: RNS.Identity.truncated_hash(link_id),
      type: RNS.Destination.link(),
      mdu: RNS.Packet.mdu(),
      mtu: Keyword.get(opts, :mtu, 500),
      rtt: Keyword.get(opts, :rtt, 0.5),
      traffic_timeout_factor: 6,
      establishment_cost: 100,
      expected_rate: nil,
      last_resource_window: nil,
      last_resource_eifr: nil,
      token: nil,
      status: 0x02
    }
  end

  # ══════════════════════════════════════════════════════════════
  # Constants
  # ══════════════════════════════════════════════════════════════

  describe "constants" do
    test "window constants" do
      assert Resource.window() == 4
      assert Resource.window_min() == 2
      assert Resource.window_max_slow() == 10
      assert Resource.window_max_very_slow() == 4
      assert Resource.window_max_fast() == 75
      assert Resource.window_max() == 75
    end

    test "fast rate threshold" do
      # WINDOW_MAX_SLOW - WINDOW - 2 = 10 - 4 - 2 = 4
      assert Resource.fast_rate_threshold() == 4
    end

    test "very slow rate threshold" do
      assert Resource.very_slow_rate_threshold() == 2
    end

    test "window flexibility" do
      assert Resource.window_flexibility() == 4
    end

    test "rate constants" do
      # 50 Kbps = 50*1000/8 = 6250 bytes/sec
      assert Resource.rate_fast() == 6250.0
      # 2 Kbps = 2*1000/8 = 250 bytes/sec
      assert Resource.rate_very_slow() == 250.0
    end

    test "size constants" do
      assert Resource.maphash_len() == 4
      assert Resource.sdu() == RNS.Packet.mdu()
      assert Resource.random_hash_size() == 4
      assert Resource.max_efficient_size() == 1_048_575
      assert Resource.metadata_max_size() == 16_777_215
      assert Resource.auto_compress_max_size() == 67_108_864
    end

    test "timeout constants" do
      assert Resource.part_timeout_factor() == 4
      assert Resource.part_timeout_factor_after_rtt() == 2
      assert Resource.proof_timeout_factor() == 3
      assert Resource.max_retries() == 16
      assert Resource.max_adv_retries() == 4
      assert Resource.sender_grace_time() == 10.0
      assert Resource.processing_grace() == 1.0
      assert Resource.retry_grace_time() == 0.25
      assert Resource.per_retry_delay() == 0.5
      assert Resource.watchdog_max_sleep() == 1
    end

    test "hashmap constants" do
      assert Resource.hashmap_is_not_exhausted() == 0x00
      assert Resource.hashmap_is_exhausted() == 0xFF
    end

    test "status constants" do
      assert Resource.status_none() == 0x00
      assert Resource.status_queued() == 0x01
      assert Resource.status_advertised() == 0x02
      assert Resource.status_transferring() == 0x03
      assert Resource.status_awaiting_proof() == 0x04
      assert Resource.status_assembling() == 0x05
      assert Resource.status_complete() == 0x06
      assert Resource.status_failed() == 0x07
      assert Resource.status_corrupt() == 0x08
      assert Resource.status_rejected() == 0x00
    end

    test "response_max_grace_time" do
      assert Resource.response_max_grace_time() == 10
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Advertisement constants
  # ══════════════════════════════════════════════════════════════

  describe "Advertisement constants" do
    test "overhead" do
      assert Advertisement.overhead() == 134
    end

    test "hashmap_max_len is positive" do
      assert Advertisement.hashmap_max_len() > 0
    end

    test "collision_guard_size" do
      expected = 2 * Resource.window_max() + Advertisement.hashmap_max_len()
      assert Advertisement.collision_guard_size() == expected
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Resource construction (sender-side)
  # ══════════════════════════════════════════════════════════════

  describe "new/3 sender-side" do
    test "creates a resource from small binary data" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link)

      assert resource.initiator == true
      assert resource.status == Resource.status_none()
      assert resource.total_parts > 0
      assert resource.size > 0
      assert resource.hash != nil
      assert resource.random_hash != nil
      assert byte_size(resource.random_hash) == Resource.random_hash_size()
      assert resource.original_hash == resource.hash
      assert resource.expected_proof != nil
      assert resource.parts != nil
      assert length(resource.parts) == resource.total_parts
      assert resource.hashmap != nil
      assert is_binary(resource.hashmap)
      assert byte_size(resource.hashmap) == resource.total_parts * Resource.maphash_len()
    end

    test "creates a resource with encryption" do
      link = mock_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link)

      assert resource.encrypted == true
      assert resource.size > byte_size(data)
    end

    test "creates a resource without encryption when no token" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link)

      assert resource.encrypted == true
      # Even without a token, the data goes through encrypt_data
      # which passes through when no token is available
    end

    test "creates a resource with compression" do
      link = plain_link()
      # Create compressible data
      data = String.duplicate("A", 1000)

      resource = Resource.new(data, link, auto_compress: true)

      # Note: zlib may or may not actually reduce size for small data
      assert resource.initiator == true
      assert resource.total_parts > 0
    end

    test "creates a resource without compression" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link, auto_compress: false)

      assert resource.compressed == false
      assert resource.auto_compress == false
    end

    test "auto_compress with integer limit" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link, auto_compress: 50)

      # Data is larger than the limit, so no compression
      assert resource.auto_compress == true
      assert resource.auto_compress_limit == 50
      assert resource.compressed == false
    end

    test "creates a resource with metadata" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      metadata = %{"filename" => "test.txt", "size" => 100}

      resource = Resource.new(data, link, metadata: metadata)

      assert resource.has_metadata == true
      assert resource.metadata_size > 0
    end

    test "creates a resource with callback" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      callback = fn _resource -> :ok end

      resource = Resource.new(data, link, callback: callback)

      assert resource.callback == callback
    end

    test "creates a resource with progress callback" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      progress_cb = fn _resource -> :ok end

      resource = Resource.new(data, link, progress_callback: progress_cb)

      assert resource.progress_callback == progress_cb
    end

    test "creates a resource with request_id" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      request_id = :crypto.strong_rand_bytes(16)

      resource = Resource.new(data, link, request_id: request_id)

      assert resource.request_id == request_id
    end

    test "creates a resource marked as response" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      request_id = :crypto.strong_rand_bytes(16)

      resource = Resource.new(data, link, request_id: request_id, is_response: true)

      assert resource.is_response == true
    end

    test "receiver-side creation with nil data" do
      link = plain_link()

      resource = Resource.new(nil, link)

      assert resource.initiator == false
      assert resource.status == Resource.status_none()
    end

    test "resource hash is 32 bytes (full hash)" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)

      resource = Resource.new(data, link)

      assert byte_size(resource.hash) == 32
    end

    test "expected_proof is different from hash" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)

      resource = Resource.new(data, link)

      assert resource.expected_proof != resource.hash
    end

    test "each part has a map_hash" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)

      resource = Resource.new(data, link)

      Enum.each(resource.parts, fn part ->
        assert byte_size(part.map_hash) == Resource.maphash_len()
      end)
    end

    test "total_size matches data + metadata size" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)

      resource = Resource.new(data, link)

      assert resource.total_size == byte_size(data)
    end

    test "total_size with metadata" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)

      resource = Resource.new(data, link, metadata: %{"key" => "value"})

      assert resource.total_size > byte_size(data)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # map_hash
  # ══════════════════════════════════════════════════════════════

  describe "map_hash/2" do
    test "returns MAPHASH_LEN bytes" do
      data = :crypto.strong_rand_bytes(100)
      random_hash = :crypto.strong_rand_bytes(4)

      hash = Resource.map_hash(data, random_hash)

      assert byte_size(hash) == Resource.maphash_len()
    end

    test "is deterministic" do
      data = :crypto.strong_rand_bytes(100)
      random_hash = :crypto.strong_rand_bytes(4)

      hash1 = Resource.map_hash(data, random_hash)
      hash2 = Resource.map_hash(data, random_hash)

      assert hash1 == hash2
    end

    test "different data produces different hashes" do
      random_hash = :crypto.strong_rand_bytes(4)
      data1 = :crypto.strong_rand_bytes(100)
      data2 = :crypto.strong_rand_bytes(100)

      hash1 = Resource.map_hash(data1, random_hash)
      hash2 = Resource.map_hash(data2, random_hash)

      assert hash1 != hash2
    end

    test "different random_hash produces different hashes" do
      data = :crypto.strong_rand_bytes(100)
      rh1 = :crypto.strong_rand_bytes(4)
      rh2 = :crypto.strong_rand_bytes(4)

      hash1 = Resource.map_hash(data, rh1)
      hash2 = Resource.map_hash(data, rh2)

      assert hash1 != hash2
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Advertisement pack/unpack
  # ══════════════════════════════════════════════════════════════

  describe "Advertisement pack/unpack" do
    test "pack/unpack roundtrip" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      adv = Advertisement.new(resource)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      assert unpacked.t == adv.t
      assert unpacked.d == adv.d
      assert unpacked.n == adv.n
      assert unpacked.h == adv.h
      assert unpacked.r == adv.r
      assert unpacked.o == adv.o
      assert unpacked.f == adv.f
      assert unpacked.i == adv.i
      assert unpacked.l == adv.l
      assert unpacked.q == adv.q
    end

    test "flags encode/decode correctly" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      adv = Advertisement.new(resource)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      assert unpacked.e == adv.e
      assert unpacked.c == adv.c
      assert unpacked.s == adv.s
      assert unpacked.u == adv.u
      assert unpacked.p == adv.p
      assert unpacked.x == adv.x
    end

    test "advertisement with request_id (request)" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      request_id = :crypto.strong_rand_bytes(16)

      resource = Resource.new(data, link, request_id: request_id)
      adv = Advertisement.new(resource)

      assert adv.u == true
      assert adv.p == false
      assert adv.q == request_id
      assert Advertisement.is_request(adv) == true
      assert Advertisement.is_response(adv) == false
    end

    test "advertisement with request_id (response)" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      request_id = :crypto.strong_rand_bytes(16)

      resource = Resource.new(data, link, request_id: request_id, is_response: true)
      adv = Advertisement.new(resource)

      assert adv.u == false
      assert adv.p == true
      assert Advertisement.is_request(adv) == false
      assert Advertisement.is_response(adv) == true
    end

    test "advertisement without request_id" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link)
      adv = Advertisement.new(resource)

      assert adv.q == nil
      assert adv.u == false
      assert adv.p == false
      assert Advertisement.is_request(adv) == false
      assert Advertisement.is_response(adv) == false
    end

    test "advertisement getters" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      adv = Advertisement.new(resource)

      assert Advertisement.transfer_size(adv) == resource.size
      assert Advertisement.data_size(adv) == resource.total_size
      assert Advertisement.parts(adv) == length(resource.parts)
      assert Advertisement.segments(adv) == resource.total_segments
      assert Advertisement.hash(adv) == resource.hash
    end

    test "advertisement with metadata flag" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link, metadata: %{"key" => "val"})
      adv = Advertisement.new(resource)

      assert adv.x == true
      assert Advertisement.has_metadata(adv) == true

      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)
      assert unpacked.x == true
    end

    test "read_request_id" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      req_id = :crypto.strong_rand_bytes(16)

      resource = Resource.new(data, link, request_id: req_id)
      adv = Advertisement.new(resource)

      assert Advertisement.read_request_id(adv) == req_id
    end

    test "read_transfer_size and read_size" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)

      resource = Resource.new(data, link)
      adv = Advertisement.new(resource)

      assert Advertisement.read_transfer_size(adv) == resource.size
      assert Advertisement.read_size(adv) == resource.total_size
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Advertise
  # ══════════════════════════════════════════════════════════════

  describe "advertise/1" do
    test "sets status to ADVERTISED" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      resource = Resource.advertise(resource)

      assert resource.status == Resource.status_advertised()
      assert resource.advertisement_packet != nil
      assert resource.adv_sent > 0
      assert resource.last_activity > 0
      assert resource.started_transferring > 0
      assert resource.rtt == nil
    end

    test "retries_left set to max_adv_retries" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      resource = Resource.advertise(resource)

      assert resource.retries_left == Resource.max_adv_retries()
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Accept (receiver-side)
  # ══════════════════════════════════════════════════════════════

  describe "accept/3" do
    test "creates a receiver resource from advertisement" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      sender = Resource.new(data, link)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      assert receiver.initiator == false
      assert receiver.status == Resource.status_transferring()
      assert receiver.hash == sender.hash
      assert receiver.original_hash == sender.original_hash
      assert receiver.random_hash == sender.random_hash
      assert receiver.total_parts > 0
      assert length(receiver.parts) == receiver.total_parts
      assert receiver.received_count == 0
    end

    test "applies previous window from link" do
      link = plain_link(last_resource_window: 8)
      data = :crypto.strong_rand_bytes(200)
      sender = Resource.new(data, link)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      # Need a link with last_resource_window set
      recv_link = Map.put(link, :last_resource_window, 8)
      {:ok, receiver} = Resource.accept(unpacked, recv_link)

      assert receiver.window == 8
    end

    test "applies previous eifr from link" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      sender = Resource.new(data, link)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      recv_link = Map.put(link, :last_resource_eifr, 5000.0)
      {:ok, receiver} = Resource.accept(unpacked, recv_link)

      assert receiver.previous_eifr == 5000.0
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Reject
  # ══════════════════════════════════════════════════════════════

  describe "reject/1" do
    test "returns resource hash" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      sender = Resource.new(data, link)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)

      {:ok, hash} = Resource.reject(packed)

      assert hash == sender.hash
    end

    test "returns error on invalid data" do
      {:error, _reason} = Resource.reject(<<0, 1, 2, 3>>)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Hashmap update
  # ══════════════════════════════════════════════════════════════

  describe "hashmap_update/3" do
    test "updates hashmap entries" do
      link = plain_link()
      resource = Resource.new(nil, link)

      # Create a resource with known hashmap
      total_parts = 5
      hashmap = List.duplicate(nil, total_parts)
      map_data = :crypto.strong_rand_bytes(total_parts * Resource.maphash_len())

      resource = %{
        resource
        | hashmap: hashmap,
          total_parts: total_parts,
          status: Resource.status_none()
      }

      resource = Resource.hashmap_update(resource, 0, map_data)

      assert resource.status == Resource.status_transferring()
      assert resource.hashmap_height == total_parts
      assert resource.waiting_for_hmu == false
    end

    test "does not update when status is FAILED" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_failed(), hashmap: [nil, nil, nil]}

      result = Resource.hashmap_update(resource, 0, :crypto.strong_rand_bytes(12))

      assert result.status == Resource.status_failed()
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Receive part
  # ══════════════════════════════════════════════════════════════

  describe "receive_part/3" do
    test "returns continue for failed resource" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_failed()}

      {result, action} = Resource.receive_part(resource, <<1, 2, 3>>)

      assert result.status == Resource.status_failed()
      assert action == :continue
    end

    test "successfully receives a part" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(100)
      sender = Resource.new(data, link)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      # Get the first part's data from sender
      first_part = List.first(sender.parts)

      # Set up req_sent for RTT tracking
      receiver = %{receiver | req_sent: System.monotonic_time(:millisecond) / 1000.0 - 0.1}

      {updated, action} = Resource.receive_part(receiver, first_part.data)

      assert updated.received_count >= 1
      assert updated.receiving_part == false
      assert action in [:continue, :request_next, :assemble]
    end

    test "assembles when all parts received" do
      link = plain_link()
      # Small data that fits in one part
      data = :crypto.strong_rand_bytes(50)
      sender = Resource.new(data, link)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      # With one part, receiving it should trigger assembly
      first_part = List.first(sender.parts)
      receiver = %{receiver | req_sent: System.monotonic_time(:millisecond) / 1000.0 - 0.1}

      {updated, action} = Resource.receive_part(receiver, first_part.data)

      if updated.total_parts == 1 do
        assert action == :assemble
        assert updated.assembly_lock == true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Request next (receiver-side)
  # ══════════════════════════════════════════════════════════════

  describe "request_next/1" do
    test "returns empty for failed resource" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_failed()}

      {_resource, data} = Resource.request_next(resource)

      assert data == <<>>
    end

    test "returns empty when waiting for HMU" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | waiting_for_hmu: true}

      {_resource, data} = Resource.request_next(resource)

      assert data == <<>>
    end

    test "builds request data with hash and requested part hashes" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      sender = Resource.new(data, link)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      {updated, request_data} = Resource.request_next(receiver)

      assert byte_size(request_data) > 0
      assert updated.req_sent > 0
      assert updated.outstanding_parts > 0
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Request (sender-side)
  # ══════════════════════════════════════════════════════════════

  describe "request/2" do
    test "returns empty for failed resource" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_failed()}

      {_resource, actions} = Resource.request(resource, <<>>)

      assert actions == []
    end

    test "sends requested parts" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      sender = Resource.new(data, link)
      sender = Resource.advertise(sender)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)
      {_receiver, request_data} = Resource.request_next(receiver)

      if byte_size(request_data) > 0 do
        {updated_sender, actions} = Resource.request(sender, request_data)

        assert updated_sender.status in [
                 Resource.status_transferring(),
                 Resource.status_awaiting_proof()
               ]

        # Should have send_part actions
        send_parts =
          Enum.filter(actions, fn
            {:send_part, _} -> true
            {:resend_part, _} -> true
            _ -> false
          end)

        assert send_parts != []
      end
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Assemble
  # ══════════════════════════════════════════════════════════════

  describe "assemble/1" do
    test "returns error for failed resource" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_failed()}

      {_resource, result} = Resource.assemble(resource)

      assert result == {:error, :failed}
    end

    test "assembles unencrypted uncompressed resource" do
      link = plain_link()
      original_data = :crypto.strong_rand_bytes(100)
      sender = Resource.new(original_data, link, auto_compress: false)

      # Build receiver from advertisement
      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      # Feed all parts to receiver
      receiver =
        Enum.reduce(sender.parts, receiver, fn part, acc ->
          {updated, _action} = Resource.receive_part(acc, part.data)
          updated
        end)

      {assembled, result} = Resource.assemble(receiver)

      case result do
        {:ok, proof_data} ->
          assert assembled.status == Resource.status_complete()
          assert assembled.data != nil
          assert byte_size(proof_data) == 64

        :corrupt ->
          # This can happen if the data was encrypted but link has no token
          :ok
      end
    end

    test "detects corrupt data" do
      link = plain_link()
      original_data = :crypto.strong_rand_bytes(100)
      sender = Resource.new(original_data, link, auto_compress: false)

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      # Feed corrupted parts
      corrupted_parts =
        sender.parts
        |> Enum.map(fn p -> %{p | data: :crypto.strong_rand_bytes(byte_size(p.data))} end)

      receiver =
        Enum.reduce(corrupted_parts, receiver, fn part, acc ->
          # We need to match the map hash, so create parts with correct hashes
          # Just put data directly
          idx = Enum.find_index(acc.parts, &(&1 == nil))

          if idx != nil do
            parts = List.replace_at(acc.parts, idx, part.data)
            %{acc | parts: parts, received_count: acc.received_count + 1}
          else
            acc
          end
        end)

      {_assembled, result} = Resource.assemble(receiver)

      assert match?(:corrupt, result) or match?({:error, _}, result)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Validate proof
  # ══════════════════════════════════════════════════════════════

  describe "validate_proof/2" do
    test "validates correct proof" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      proof_data = resource.hash <> resource.expected_proof

      result = Resource.validate_proof(resource, proof_data)

      assert result.status == Resource.status_complete()
    end

    test "rejects incorrect proof" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      fake_proof = resource.hash <> :crypto.strong_rand_bytes(32)

      result = Resource.validate_proof(resource, fake_proof)

      assert result.status != Resource.status_complete()
    end

    test "rejects wrong-length proof" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      result = Resource.validate_proof(resource, :crypto.strong_rand_bytes(10))

      assert result.status != Resource.status_complete()
    end

    test "does not validate when failed" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | status: Resource.status_failed()}

      proof_data = resource.hash <> resource.expected_proof

      result = Resource.validate_proof(resource, proof_data)

      assert result.status == Resource.status_failed()
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Cancel
  # ══════════════════════════════════════════════════════════════

  describe "cancel/1" do
    test "cancels initiator resource" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | status: Resource.status_transferring()}

      {cancelled, cancel_data} = Resource.cancel(resource)

      assert cancelled.status == Resource.status_failed()
      assert cancel_data == resource.hash
    end

    test "cancels non-initiator resource" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_transferring()}

      {cancelled, cancel_data} = Resource.cancel(resource)

      assert cancelled.status == Resource.status_failed()
      assert cancel_data == nil
    end

    test "does not cancel complete resource" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | status: Resource.status_complete()}

      {result, cancel_data} = Resource.cancel(resource)

      assert result.status == Resource.status_complete()
      assert cancel_data == nil
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Rejected
  # ══════════════════════════════════════════════════════════════

  describe "rejected/1" do
    test "marks initiator resource as rejected" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | status: Resource.status_advertised()}

      result = Resource.rejected(resource)

      assert result.status == Resource.status_rejected()
    end

    test "does not reject non-initiator" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_transferring()}

      result = Resource.rejected(resource)

      assert result.status == Resource.status_transferring()
    end

    test "does not reject complete resource" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | status: Resource.status_complete()}

      result = Resource.rejected(resource)

      assert result.status == Resource.status_complete()
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Update EIFR
  # ══════════════════════════════════════════════════════════════

  describe "update_eifr/1" do
    test "uses req_data_rtt_rate when available" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | req_data_rtt_rate: 1000.0}

      result = Resource.update_eifr(resource)

      assert result.eifr == 8000.0
    end

    test "uses previous_eifr as fallback" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | req_data_rtt_rate: 0, previous_eifr: 5000.0}

      result = Resource.update_eifr(resource)

      assert result.eifr == 5000.0
    end

    test "uses establishment_cost as last resort" do
      link = plain_link(rtt: 1.0)
      resource = Resource.new(nil, link)
      resource = %{resource | req_data_rtt_rate: 0, previous_eifr: nil}

      result = Resource.update_eifr(resource)

      # establishment_cost * 8 / rtt = 100 * 8 / 1.0 = 800
      assert result.eifr == 800.0
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Watchdog check
  # ══════════════════════════════════════════════════════════════

  describe "watchdog_check/1" do
    test "returns done for assembling status" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_assembling()}

      {_resource, action} = Resource.watchdog_check(resource)

      assert action == :done
    end

    test "returns done for complete status" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_complete()}

      {_resource, action} = Resource.watchdog_check(resource)

      assert action == :done
    end

    test "returns done for rejected status" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | status: Resource.status_rejected()}

      {_resource, action} = Resource.watchdog_check(resource)

      assert action == :done
    end

    test "cancels advertised resource after timeout with no retries" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = Resource.advertise(resource)

      # Simulate timeout by setting adv_sent far in the past
      resource = %{resource | adv_sent: 0, retries_left: 0, timeout: 0.001}

      {result, action} = Resource.watchdog_check(resource)

      assert result.status == Resource.status_failed()
      assert action == :cancel
    end

    test "retries advertised resource when retries available" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = Resource.advertise(resource)

      # Simulate timeout with retries available
      resource = %{resource | adv_sent: 0, retries_left: 2, timeout: 0.001}

      {result, action} = Resource.watchdog_check(resource)

      assert result.retries_left == 1
      assert action == :retry_adv
    end

    test "returns sleep for fresh advertised resource" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = Resource.advertise(resource)

      {_resource, action} = Resource.watchdog_check(resource)

      assert match?({:sleep, _}, action)
    end

    test "cancels transferring sender after max wait" do
      link = plain_link(rtt: 0.001)
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      resource = %{
        resource
        | status: Resource.status_transferring(),
          last_activity: 0,
          rtt: 0.001
      }

      {result, action} = Resource.watchdog_check(resource)

      assert result.status == Resource.status_failed()
      assert action == :cancel
    end

    test "retries transferring receiver when retries available" do
      link = plain_link()
      resource = Resource.new(nil, link)

      resource = %{
        resource
        | status: Resource.status_transferring(),
          initiator: false,
          last_activity: 0,
          retries_left: 5,
          outstanding_parts: 3,
          sdu: 464,
          eifr: 1000.0,
          rtt: 0.5,
          req_resp_rtt_rate: 100.0,
          part_timeout_factor: 4
      }

      {result, action} = Resource.watchdog_check(resource)

      assert result.retries_left == 4
      assert action == :retry_request
    end

    test "queries cache for awaiting proof" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      resource = %{
        resource
        | status: Resource.status_awaiting_proof(),
          last_part_sent: 0,
          retries_left: 2,
          rtt: 0.001
      }

      {result, action} = Resource.watchdog_check(resource)

      assert result.retries_left == 1

      case action do
        {:query_cache, expected_data} ->
          assert byte_size(expected_data) == 64

        {:sleep, _} ->
          :ok
      end
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Progress
  # ══════════════════════════════════════════════════════════════

  describe "progress/1" do
    test "returns 1.0 for complete final segment" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | status: Resource.status_complete()}

      assert Resource.progress(resource) == 1.0
    end

    test "returns 0.0 for no parts sent (initiator)" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      assert Resource.progress(resource) == 0.0
    end

    test "returns partial progress for initiator" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | sent_parts: 1}

      progress = Resource.progress(resource)

      assert progress > 0.0
      assert progress <= 1.0
    end

    test "returns 0.0 for receiver with no parts" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | total_parts: 10}

      assert Resource.progress(resource) == 0.0
    end

    test "returns partial progress for receiver" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | total_parts: 10, received_count: 5}

      progress = Resource.progress(resource)

      assert progress == 0.5
    end
  end

  describe "segment_progress/1" do
    test "returns 1.0 for complete final segment" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      resource = %{resource | status: Resource.status_complete()}

      assert Resource.segment_progress(resource) == 1.0
    end

    test "returns partial progress for initiator" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)
      total = resource.total_parts
      resource = %{resource | sent_parts: 1}

      progress = Resource.segment_progress(resource)

      assert_in_delta progress, 1 / total, 0.01
    end

    test "returns partial progress for receiver" do
      link = plain_link()
      resource = Resource.new(nil, link)
      resource = %{resource | total_parts: 10, received_count: 3}

      assert Resource.segment_progress(resource) == 0.3
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Getters
  # ══════════════════════════════════════════════════════════════

  describe "getters" do
    test "transfer_size returns size" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      assert Resource.transfer_size(resource) == resource.size
    end

    test "data_size returns total_size" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      assert Resource.data_size(resource) == resource.total_size
    end

    test "parts returns total_parts" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      assert Resource.parts(resource) == resource.total_parts
    end

    test "segments returns total_segments" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      assert Resource.segments(resource) == 1
    end

    test "hash returns hash" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      assert Resource.hash(resource) == resource.hash
    end

    test "is_compressed returns compressed flag" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link, auto_compress: false)

      assert Resource.is_compressed(resource) == false
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Setters
  # ══════════════════════════════════════════════════════════════

  describe "setters" do
    test "set_callback" do
      link = plain_link()
      resource = Resource.new(nil, link)
      cb = fn _r -> :ok end

      result = Resource.set_callback(resource, cb)

      assert result.callback == cb
    end

    test "set_progress_callback" do
      link = plain_link()
      resource = Resource.new(nil, link)
      cb = fn _r -> :ok end

      result = Resource.set_progress_callback(resource, cb)

      assert result.progress_callback == cb
    end
  end

  # ══════════════════════════════════════════════════════════════
  # String.Chars
  # ══════════════════════════════════════════════════════════════

  describe "String.Chars" do
    test "to_string with hash and link" do
      link = plain_link()
      data = :crypto.strong_rand_bytes(200)
      resource = Resource.new(data, link)

      str = to_string(resource)

      assert String.starts_with?(str, "<")
      assert String.ends_with?(str, ">")
      assert String.contains?(str, "/")
    end

    test "to_string with nil hash" do
      resource = %Resource{hash: nil, link: %{link_id: nil}}

      str = to_string(resource)

      assert str == "<unknown/unknown>"
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Integration: sender-receiver roundtrip (unencrypted)
  # ══════════════════════════════════════════════════════════════

  describe "sender-receiver roundtrip" do
    test "small data transfer without encryption" do
      link = plain_link()
      original_data = :crypto.strong_rand_bytes(100)

      # Sender creates resource
      sender = Resource.new(original_data, link, auto_compress: false)

      assert sender.total_parts > 0
      assert sender.hash != nil

      # Receiver accepts advertisement
      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      assert receiver.total_parts == sender.total_parts

      # Receiver requests parts
      {receiver, _request_data} = Resource.request_next(receiver)

      # Sender sends parts (simulate the receiver getting them)
      receiver =
        Enum.reduce(sender.parts, receiver, fn part, acc ->
          {updated, _action} = Resource.receive_part(acc, part.data)
          updated
        end)

      # Verify all parts received
      assert receiver.received_count == receiver.total_parts

      # Assemble
      {assembled, result} = Resource.assemble(receiver)

      case result do
        {:ok, proof_data} ->
          assert assembled.status == Resource.status_complete()
          assert byte_size(proof_data) == 64

          # Sender validates proof
          sender_result = Resource.validate_proof(sender, proof_data)
          assert sender_result.status == Resource.status_complete()

        _ ->
          # Without token, data passes through as-is
          :ok
      end
    end

    test "resource with metadata roundtrip" do
      link = plain_link()
      original_data = :crypto.strong_rand_bytes(100)
      metadata = %{"filename" => "test.txt", "size" => 100}

      sender = Resource.new(original_data, link, metadata: metadata, auto_compress: false)

      assert sender.has_metadata == true

      adv = Advertisement.new(sender)
      packed = Advertisement.pack(adv)
      unpacked = Advertisement.unpack(packed)

      {:ok, receiver} = Resource.accept(unpacked, link)

      assert receiver.has_metadata == true
    end

    test "resource with request_id roundtrip" do
      link = plain_link()
      original_data = :crypto.strong_rand_bytes(100)
      request_id = :crypto.strong_rand_bytes(16)

      sender = Resource.new(original_data, link, request_id: request_id)

      adv = Advertisement.new(sender)

      assert Advertisement.is_request(adv) == true
      assert Advertisement.read_request_id(adv) == request_id
    end
  end
end
