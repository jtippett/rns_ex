defmodule RNS.Integration.FileTransferTest do
  @moduledoc """
  Integration tests for resource (file) transfer over links.

  Tests the complete resource transfer pipeline:
    1. Sender creates Resource from data, segmented into parts
    2. Resource is advertised to receiver via advertisement packet
    3. Receiver accepts and receives parts
    4. Receiver assembles and verifies integrity via hash
    5. Receiver generates proof, sender validates
  """

  use ExUnit.Case, async: false

  alias RNS.Cryptography.Token
  alias RNS.Link
  alias RNS.Resource

  # ── Setup ─────────────────────────────────────────────────────────

  setup do
    # Clear ETS tables for clean state (Transport is supervised by the application)
    RNS.Test.SupervisedHelpers.clear_transport_tables()
    :ok
  end

  # ── Resource Creation ────────────────────────────────────────────

  describe "resource creation and segmentation" do
    test "creates resource from small data (single segment)" do
      {link, _} = make_link_pair()
      data = :crypto.strong_rand_bytes(128)

      resource = Resource.new(data, link)

      assert resource.initiator == true
      assert resource.total_parts >= 1
      assert resource.size > 0
      assert resource.hash != nil
      assert resource.truncated_hash != nil
      assert resource.expected_proof != nil
      assert resource.random_hash != nil
      assert byte_size(resource.random_hash) == Resource.random_hash_size()
    end

    test "creates resource with metadata" do
      {link, _} = make_link_pair()
      data = :crypto.strong_rand_bytes(256)
      metadata = %{"filename" => "test.bin", "size" => 256}

      resource = Resource.new(data, link, metadata: metadata)

      assert resource.has_metadata == true
      assert resource.metadata_size > 0
      assert resource.initiator == true
    end

    test "creates resource with compression enabled" do
      {link, _} = make_link_pair()
      # Highly compressible data
      data = String.duplicate("Hello World! ", 100)

      resource = Resource.new(data, link, auto_compress: true)

      assert resource.initiator == true
      # Compressed data should be smaller
      if resource.compressed do
        # Allow overhead
        assert resource.size < byte_size(data) + 100
      end
    end

    test "creates resource with compression disabled" do
      {link, _} = make_link_pair()
      data = :crypto.strong_rand_bytes(256)

      resource = Resource.new(data, link, auto_compress: false)

      assert resource.initiator == true
      assert resource.compressed == false
    end

    test "resource segmentation creates correct number of parts" do
      {link, _} = make_link_pair()
      data = :crypto.strong_rand_bytes(128)

      resource = Resource.new(data, link)

      assert length(resource.parts) == resource.total_parts
      assert resource.total_parts >= 1

      # All parts should have data and map_hash
      Enum.each(resource.parts, fn part ->
        assert is_binary(part.data)
        assert is_binary(part.map_hash)
        assert byte_size(part.map_hash) == Resource.maphash_len()
      end)
    end
  end

  # ── Advertisement ────────────────────────────────────────────────

  describe "resource advertisement" do
    test "resource can be advertised" do
      {link, _} = make_link_pair()
      data = :crypto.strong_rand_bytes(128)

      resource = Resource.new(data, link)
      advertised = Resource.advertise(resource)

      assert advertised.status == Resource.status_advertised()
      assert advertised.advertisement_packet != nil
    end

    test "advertisement can be packed and unpacked" do
      {link, _} = make_link_pair()
      data = :crypto.strong_rand_bytes(128)

      resource = Resource.new(data, link)
      adv = Resource.Advertisement.new(resource)
      packed = Resource.Advertisement.pack(adv)

      assert is_binary(packed)
      assert byte_size(packed) > 0

      unpacked = Resource.Advertisement.unpack(packed)

      # hash
      assert unpacked.h == adv.h
      # size
      assert unpacked.t == adv.t
      # data size
      assert unpacked.d == adv.d
      # random hash
      assert unpacked.r == adv.r
      # original hash
      assert unpacked.o == adv.o
      # segment index
      assert unpacked.i == adv.i
      # total segments
      assert unpacked.l == adv.l
    end
  end

  # ── End-to-End Transfer (Simulated) ──────────────────────────────

  describe "end-to-end resource transfer" do
    test "micro resource (128 bytes) — full transfer cycle" do
      {sender_link, receiver_link} = make_link_pair()

      # Original data
      original_data = :crypto.strong_rand_bytes(128)

      # === Sender: create and advertise ===
      sender_resource = Resource.new(original_data, sender_link)
      sender_resource = Resource.advertise(sender_resource)

      # === Receiver: accept from advertisement ===
      adv_data = sender_resource.advertisement_packet
      adv = Resource.Advertisement.unpack(adv_data)
      {:ok, receiver_resource} = Resource.accept(adv, receiver_link)

      assert receiver_resource.status == Resource.status_transferring()
      assert receiver_resource.total_parts == sender_resource.total_parts

      # === Transfer: simulate sending all parts ===
      receiver_resource =
        Enum.reduce(Enum.with_index(sender_resource.parts), receiver_resource, fn {part, i},
                                                                                  acc ->
          # Receiver stores the part data at the correct index
          updated_parts = List.replace_at(acc.parts, i, part.data)
          %{acc | parts: updated_parts, received_count: acc.received_count + 1}
        end)

      # === Receiver: assemble ===
      {assembled, result} = Resource.assemble(receiver_resource)

      assert assembled.status == Resource.status_complete()
      assert {:ok, proof_data} = result
      assert is_binary(proof_data)
      # Two 32-byte hashes
      assert byte_size(proof_data) == 64

      # Verify reassembled data matches original
      assert assembled.data == original_data

      # === Sender: validate proof ===
      completed = Resource.validate_proof(sender_resource, proof_data)
      assert completed.status == Resource.status_complete()
    end

    test "resource with metadata — transfer and metadata extraction" do
      {sender_link, receiver_link} = make_link_pair()

      original_data = "Hello from RNS resource transfer!"
      metadata = %{"type" => "text", "encoding" => "utf8"}

      # Sender creates with metadata
      sender_resource = Resource.new(original_data, sender_link, metadata: metadata)
      sender_resource = Resource.advertise(sender_resource)

      # Receiver accepts
      adv = Resource.Advertisement.unpack(sender_resource.advertisement_packet)
      {:ok, receiver_resource} = Resource.accept(adv, receiver_link)

      # Transfer parts
      receiver_resource =
        Enum.reduce(Enum.with_index(sender_resource.parts), receiver_resource, fn {part, i},
                                                                                  acc ->
          updated_parts = List.replace_at(acc.parts, i, part.data)
          %{acc | parts: updated_parts, received_count: acc.received_count + 1}
        end)

      # Assemble
      {assembled, {:ok, _proof_data}} = Resource.assemble(receiver_resource)

      assert assembled.status == Resource.status_complete()
      assert assembled.data == original_data
      assert assembled.metadata == metadata
    end

    test "resource with random binary data — integrity verified" do
      {sender_link, receiver_link} = make_link_pair()

      # Larger random data
      original_data = :crypto.strong_rand_bytes(1024)

      sender_resource = Resource.new(original_data, sender_link, auto_compress: false)
      sender_resource = Resource.advertise(sender_resource)

      adv = Resource.Advertisement.unpack(sender_resource.advertisement_packet)
      {:ok, receiver_resource} = Resource.accept(adv, receiver_link)

      # Transfer all parts
      receiver_resource =
        Enum.reduce(Enum.with_index(sender_resource.parts), receiver_resource, fn {part, i},
                                                                                  acc ->
          updated_parts = List.replace_at(acc.parts, i, part.data)
          %{acc | parts: updated_parts, received_count: acc.received_count + 1}
        end)

      {assembled, {:ok, proof_data}} = Resource.assemble(receiver_resource)

      assert assembled.status == Resource.status_complete()
      assert assembled.data == original_data

      # Proof validates
      completed = Resource.validate_proof(sender_resource, proof_data)
      assert completed.status == Resource.status_complete()
    end

    test "corrupt data fails integrity check" do
      {sender_link, receiver_link} = make_link_pair()

      original_data = :crypto.strong_rand_bytes(256)
      sender_resource = Resource.new(original_data, sender_link, auto_compress: false)
      sender_resource = Resource.advertise(sender_resource)

      adv = Resource.Advertisement.unpack(sender_resource.advertisement_packet)
      {:ok, receiver_resource} = Resource.accept(adv, receiver_link)

      # Transfer parts but corrupt the last byte of the first part
      receiver_resource =
        Enum.reduce(Enum.with_index(sender_resource.parts), receiver_resource, fn {part, i},
                                                                                  acc ->
          corrupted_data =
            if i == 0 do
              # Flip a bit in the data
              size = byte_size(part.data)
              <<head::binary-size(size - 1), last_byte>> = part.data
              <<head::binary, Bitwise.bxor(last_byte, 0xFF)>>
            else
              part.data
            end

          updated_parts = List.replace_at(acc.parts, i, corrupted_data)
          %{acc | parts: updated_parts, received_count: acc.received_count + 1}
        end)

      {assembled, result} = Resource.assemble(receiver_resource)

      # Should be corrupt — either hash mismatch or decryption failure (HMAC invalid)
      assert assembled.status == Resource.status_corrupt()
      assert result == :corrupt or match?({:error, _}, result)
    end

    test "invalid proof is not accepted by sender" do
      {sender_link, _} = make_link_pair()

      original_data = :crypto.strong_rand_bytes(128)
      sender_resource = Resource.new(original_data, sender_link)

      # Fake proof with wrong hash
      fake_proof = :crypto.strong_rand_bytes(64)
      result = Resource.validate_proof(sender_resource, fake_proof)

      # Status should not change to complete
      refute result.status == Resource.status_complete()
    end
  end

  # ── Resource Cancellation ────────────────────────────────────────

  describe "resource cancellation" do
    test "sender can cancel an in-progress transfer" do
      {link, _} = make_link_pair()
      data = :crypto.strong_rand_bytes(256)

      resource = Resource.new(data, link)
      resource = Resource.advertise(resource)

      {cancelled, cancel_data} = Resource.cancel(resource)

      assert cancelled.status == Resource.status_failed()
      assert cancel_data == resource.hash
    end

    test "receiver can cancel an in-progress transfer" do
      {sender_link, receiver_link} = make_link_pair()

      data = :crypto.strong_rand_bytes(256)
      sender_resource = Resource.new(data, sender_link)
      sender_resource = Resource.advertise(sender_resource)

      adv = Resource.Advertisement.unpack(sender_resource.advertisement_packet)
      {:ok, receiver_resource} = Resource.accept(adv, receiver_link)

      {cancelled, cancel_data} = Resource.cancel(receiver_resource)

      assert cancelled.status == Resource.status_failed()
      # Receiver cancel data is nil (only initiator sends cancel)
      assert cancel_data == nil
    end

    test "completed resource cannot be cancelled" do
      {sender_link, receiver_link} = make_link_pair()

      data = :crypto.strong_rand_bytes(128)
      sender_resource = Resource.new(data, sender_link)
      sender_resource = Resource.advertise(sender_resource)

      adv = Resource.Advertisement.unpack(sender_resource.advertisement_packet)
      {:ok, receiver_resource} = Resource.accept(adv, receiver_link)

      # Complete the transfer
      receiver_resource =
        Enum.reduce(Enum.with_index(sender_resource.parts), receiver_resource, fn {part, i},
                                                                                  acc ->
          updated_parts = List.replace_at(acc.parts, i, part.data)
          %{acc | parts: updated_parts, received_count: acc.received_count + 1}
        end)

      {assembled, {:ok, _proof}} = Resource.assemble(receiver_resource)
      assert assembled.status == Resource.status_complete()

      # Cancel should have no effect
      {still_complete, cancel_data} = Resource.cancel(assembled)
      assert still_complete.status == Resource.status_complete()
      assert cancel_data == nil
    end
  end

  # ── Resource Constants ───────────────────────────────────────────

  describe "resource constants" do
    test "window constants" do
      assert Resource.window() == 4
      assert Resource.window_min() == 2
      assert Resource.window_max_slow() == 10
      assert Resource.window_max_fast() == 75
      assert Resource.window_max() == 75
    end

    test "size constants" do
      assert Resource.maphash_len() == 4
      assert Resource.random_hash_size() == 4
      assert Resource.max_efficient_size() > 0
      assert Resource.metadata_max_size() > 0
    end

    test "timeout constants" do
      assert Resource.max_retries() == 16
      assert Resource.max_adv_retries() == 4
    end

    test "status constants form a progression" do
      assert Resource.status_none() < Resource.status_queued()
      assert Resource.status_queued() < Resource.status_advertised()
      assert Resource.status_advertised() < Resource.status_transferring()
      assert Resource.status_transferring() < Resource.status_awaiting_proof()
      assert Resource.status_awaiting_proof() < Resource.status_assembling()
      assert Resource.status_assembling() < Resource.status_complete()
      assert Resource.status_complete() < Resource.status_failed()
      assert Resource.status_failed() < Resource.status_corrupt()
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp make_link_pair do
    # Resource.new expects a plain map (not a struct) for the link parameter,
    # because it uses link[:mtu] bracket access which requires Access behaviour.
    # This matches the existing resource_test.exs pattern.

    # Generate a shared token (both sides use the same derived key)
    key = Token.generate_key()
    token = Token.new(key)
    link_id = :crypto.strong_rand_bytes(16)

    # Sender link (initiator)
    sender_link = %{
      link_id: link_id,
      mdu: Link.mdu(),
      mtu: 500,
      rtt: 0.5,
      traffic_timeout_factor: 6,
      establishment_cost: 100,
      expected_rate: nil,
      last_resource_window: nil,
      last_resource_eifr: nil,
      token: token,
      status: Link.active()
    }

    # Receiver link (same token — simulates derived key agreement)
    receiver_link = %{
      link_id: link_id,
      mdu: Link.mdu(),
      mtu: 500,
      rtt: 0.5,
      traffic_timeout_factor: 6,
      establishment_cost: 100,
      expected_rate: nil,
      last_resource_window: nil,
      last_resource_eifr: nil,
      token: token,
      status: Link.active()
    }

    {sender_link, receiver_link}
  end
end
