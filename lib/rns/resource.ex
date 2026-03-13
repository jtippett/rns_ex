defmodule RNS.Resource do
  @moduledoc """
  Allows transferring arbitrary amounts of data over a Link.

  Automatically handles sequencing, compression, coordination and checksumming.
  Data can be bytes or a file handle. The resource is split into parts that
  fit within the link MTU, sent with adaptive windowing, and reassembled on
  the receiving end with integrity verification.

  Matches `python/RNS/Resource.py`.
  """

  import Bitwise

  alias RNS.Identity

  # ── Window constants ──────────────────────────────────────────

  @window 4
  @window_min 2
  @window_max_slow 10
  @window_max_very_slow 4
  @window_max_fast 75
  @window_max @window_max_fast
  @fast_rate_threshold @window_max_slow - @window - 2
  @very_slow_rate_threshold 2
  @window_flexibility 4

  # ── Rate constants ────────────────────────────────────────────

  # 50 Kbps in bytes/sec
  @rate_fast 50 * 1000 / 8
  # 2 Kbps in bytes/sec
  @rate_very_slow 2 * 1000 / 8

  # ── Size constants ────────────────────────────────────────────

  @maphash_len 4
  @sdu RNS.Packet.mdu()
  @random_hash_size 4
  @max_efficient_size 1 * 1024 * 1024 - 1
  @response_max_grace_time 10
  @metadata_max_size 16 * 1024 * 1024 - 1
  @auto_compress_max_size 64 * 1024 * 1024

  # ── Timeout constants ─────────────────────────────────────────

  @part_timeout_factor 4
  @part_timeout_factor_after_rtt 2
  @proof_timeout_factor 3
  @max_retries 16
  @max_adv_retries 4
  @sender_grace_time 10.0
  @processing_grace 1.0
  @retry_grace_time 0.25
  @per_retry_delay 0.5
  @watchdog_max_sleep 1

  # ── Hashmap constants ─────────────────────────────────────────

  @hashmap_is_not_exhausted 0x00
  @hashmap_is_exhausted 0xFF

  # ── Status constants ──────────────────────────────────────────

  @status_none 0x00
  @status_queued 0x01
  @status_advertised 0x02
  @status_transferring 0x03
  @status_awaiting_proof 0x04
  @status_assembling 0x05
  @status_complete 0x06
  @status_failed 0x07
  @status_corrupt 0x08
  @status_rejected 0x00

  # ── Struct ────────────────────────────────────────────────────

  defstruct [
    :link,
    :hash,
    :truncated_hash,
    :original_hash,
    :random_hash,
    :expected_proof,
    :data,
    :uncompressed_data,
    :compressed_data,
    :metadata,
    :hashmap,
    :hashmap_raw,
    :parts,
    :advertisement_packet,
    :callback,
    :progress_callback,
    :request_id,
    :input_file,
    :next_segment,
    :storagepath,
    :meta_storagepath,
    :rtt,
    :eifr,
    :previous_eifr,
    :req_resp,
    :started_transferring,
    :adv_sent,
    :last_part_sent,
    status: @status_none,
    flags: 0,
    size: 0,
    total_size: 0,
    uncompressed_size: 0,
    sdu: @sdu,
    total_parts: 0,
    sent_parts: 0,
    received_count: 0,
    outstanding_parts: 0,
    initiator: true,
    encrypted: false,
    compressed: false,
    split: false,
    has_metadata: false,
    metadata_size: 0,
    segment_index: 1,
    total_segments: 1,
    window: @window,
    window_max: @window_max_slow,
    window_min: @window_min,
    window_flexibility: @window_flexibility,
    max_retries: @max_retries,
    max_adv_retries: @max_adv_retries,
    retries_left: @max_retries,
    timeout_factor: 6,
    part_timeout_factor: @part_timeout_factor,
    sender_grace_time: @sender_grace_time,
    last_activity: 0,
    hashmap_height: 0,
    waiting_for_hmu: false,
    receiving_part: false,
    consecutive_completed_height: -1,
    assembly_lock: false,
    preparing_next_segment: false,
    hmu_retry_ok: false,
    watchdog_job_id: 0,
    rtt_rxd_bytes: 0,
    req_sent: 0,
    req_sent_bytes: 0,
    req_resp_rtt_rate: 0,
    rtt_rxd_bytes_at_part_req: 0,
    req_data_rtt_rate: 0,
    fast_rate_rounds: 0,
    very_slow_rate_rounds: 0,
    is_response: false,
    auto_compress: true,
    auto_compress_option: true,
    auto_compress_limit: @auto_compress_max_size,
    timeout: nil,
    req_hashlist: [],
    receiver_min_consecutive_height: 0
  ]

  @type t :: %__MODULE__{}

  # ── Constant accessors ────────────────────────────────────────

  @doc "Initial window size at beginning of transfer."
  @spec window() :: non_neg_integer()
  def window, do: @window

  @doc "Absolute minimum window size."
  @spec window_min() :: non_neg_integer()
  def window_min, do: @window_min

  @doc "Maximum window size for slow links."
  @spec window_max_slow() :: non_neg_integer()
  def window_max_slow, do: @window_max_slow

  @doc "Maximum window size for very slow links."
  @spec window_max_very_slow() :: non_neg_integer()
  def window_max_very_slow, do: @window_max_very_slow

  @doc "Maximum window size for fast links."
  @spec window_max_fast() :: non_neg_integer()
  def window_max_fast, do: @window_max_fast

  @doc "Global maximum window (equals WINDOW_MAX_FAST)."
  @spec window_max() :: non_neg_integer()
  def window_max, do: @window_max

  @doc "Fast rate threshold for window upgrade."
  @spec fast_rate_threshold() :: non_neg_integer()
  def fast_rate_threshold, do: @fast_rate_threshold

  @doc "Very slow rate threshold for window cap."
  @spec very_slow_rate_threshold() :: non_neg_integer()
  def very_slow_rate_threshold, do: @very_slow_rate_threshold

  @doc "Minimum flexibility between window_max and window_min."
  @spec window_flexibility() :: non_neg_integer()
  def window_flexibility, do: @window_flexibility

  @doc "Rate above which link is considered fast (bytes/sec)."
  @spec rate_fast() :: float()
  def rate_fast, do: @rate_fast

  @doc "Rate below which link is considered very slow (bytes/sec)."
  @spec rate_very_slow() :: float()
  def rate_very_slow, do: @rate_very_slow

  @doc "Number of bytes in a map hash."
  @spec maphash_len() :: non_neg_integer()
  def maphash_len, do: @maphash_len

  @doc "Segment Data Unit size."
  @spec sdu() :: non_neg_integer()
  def sdu, do: @sdu

  @doc "Random hash size in bytes."
  @spec random_hash_size() :: non_neg_integer()
  def random_hash_size, do: @random_hash_size

  @doc "Maximum efficient size for a single resource segment."
  @spec max_efficient_size() :: non_neg_integer()
  def max_efficient_size, do: @max_efficient_size

  @doc "Maximum response grace time."
  @spec response_max_grace_time() :: non_neg_integer()
  def response_max_grace_time, do: @response_max_grace_time

  @doc "Maximum metadata size."
  @spec metadata_max_size() :: non_neg_integer()
  def metadata_max_size, do: @metadata_max_size

  @doc "Maximum size for auto-compression."
  @spec auto_compress_max_size() :: non_neg_integer()
  def auto_compress_max_size, do: @auto_compress_max_size

  @doc "Part timeout factor."
  @spec part_timeout_factor() :: non_neg_integer()
  def part_timeout_factor, do: @part_timeout_factor

  @doc "Part timeout factor after RTT is known."
  @spec part_timeout_factor_after_rtt() :: non_neg_integer()
  def part_timeout_factor_after_rtt, do: @part_timeout_factor_after_rtt

  @doc "Proof timeout factor."
  @spec proof_timeout_factor() :: non_neg_integer()
  def proof_timeout_factor, do: @proof_timeout_factor

  @doc "Maximum retries for transfer."
  @spec max_retries() :: non_neg_integer()
  def max_retries, do: @max_retries

  @doc "Maximum retries for advertisement."
  @spec max_adv_retries() :: non_neg_integer()
  def max_adv_retries, do: @max_adv_retries

  @doc "Sender grace time in seconds."
  @spec sender_grace_time() :: float()
  def sender_grace_time, do: @sender_grace_time

  @doc "Processing grace time in seconds."
  @spec processing_grace() :: float()
  def processing_grace, do: @processing_grace

  @doc "Retry grace time in seconds."
  @spec retry_grace_time() :: float()
  def retry_grace_time, do: @retry_grace_time

  @doc "Per-retry delay in seconds."
  @spec per_retry_delay() :: float()
  def per_retry_delay, do: @per_retry_delay

  @doc "Maximum watchdog sleep time in seconds."
  @spec watchdog_max_sleep() :: non_neg_integer()
  def watchdog_max_sleep, do: @watchdog_max_sleep

  @doc "Hashmap not exhausted indicator."
  @spec hashmap_is_not_exhausted() :: non_neg_integer()
  def hashmap_is_not_exhausted, do: @hashmap_is_not_exhausted

  @doc "Hashmap exhausted indicator."
  @spec hashmap_is_exhausted() :: non_neg_integer()
  def hashmap_is_exhausted, do: @hashmap_is_exhausted

  # Status constants
  @doc "Status: none."
  @spec status_none() :: non_neg_integer()
  def status_none, do: @status_none

  @doc "Status: queued."
  @spec status_queued() :: non_neg_integer()
  def status_queued, do: @status_queued

  @doc "Status: advertised."
  @spec status_advertised() :: non_neg_integer()
  def status_advertised, do: @status_advertised

  @doc "Status: transferring."
  @spec status_transferring() :: non_neg_integer()
  def status_transferring, do: @status_transferring

  @doc "Status: awaiting proof."
  @spec status_awaiting_proof() :: non_neg_integer()
  def status_awaiting_proof, do: @status_awaiting_proof

  @doc "Status: assembling."
  @spec status_assembling() :: non_neg_integer()
  def status_assembling, do: @status_assembling

  @doc "Status: complete."
  @spec status_complete() :: non_neg_integer()
  def status_complete, do: @status_complete

  @doc "Status: failed."
  @spec status_failed() :: non_neg_integer()
  def status_failed, do: @status_failed

  @doc "Status: corrupt."
  @spec status_corrupt() :: non_neg_integer()
  def status_corrupt, do: @status_corrupt

  @doc "Status: rejected (same value as NONE)."
  @spec status_rejected() :: non_neg_integer()
  def status_rejected, do: @status_rejected

  # ── Constructor (sender-side) ─────────────────────────────────

  @doc """
  Creates a new Resource for transmission over a link.

  `data` can be a binary or nil (for receiver-side creation).
  `link` is the Link struct to transfer over.

  Options:
  - `:metadata` - arbitrary metadata (will be MessagePack-encoded)
  - `:advertise` - whether to auto-advertise (default true)
  - `:auto_compress` - whether to compress (default true, can also be integer limit)
  - `:callback` - called when transfer concludes
  - `:progress_callback` - called on progress updates
  - `:timeout` - custom timeout
  - `:segment_index` - segment index for split resources (default 1)
  - `:original_hash` - hash of first segment for split resources
  - `:request_id` - associated request ID
  - `:is_response` - whether this is a response resource
  - `:sent_metadata_size` - metadata size already sent in prior segments
  """
  @spec new(binary() | nil, map(), keyword()) :: t()
  def new(data, link, opts \\ []) do
    metadata = Keyword.get(opts, :metadata)
    auto_compress_opt = Keyword.get(opts, :auto_compress, true)
    callback = Keyword.get(opts, :callback)
    progress_callback = Keyword.get(opts, :progress_callback)
    timeout = Keyword.get(opts, :timeout)
    segment_index = Keyword.get(opts, :segment_index, 1)
    original_hash = Keyword.get(opts, :original_hash)
    request_id = Keyword.get(opts, :request_id)
    is_response = Keyword.get(opts, :is_response, false)
    sent_metadata_size = Keyword.get(opts, :sent_metadata_size, 0)

    # Process auto_compress option
    {auto_compress, auto_compress_limit} =
      case auto_compress_opt do
        true -> {true, @auto_compress_max_size}
        false -> {false, @auto_compress_max_size}
        limit when is_integer(limit) -> {true, limit}
      end

    # Process metadata
    {metadata_bytes, metadata_size, has_metadata} =
      case metadata do
        nil ->
          if sent_metadata_size > 0,
            do: {"", sent_metadata_size, true},
            else: {"", 0, false}

        meta ->
          packed = Msgpax.pack!(meta, iodata: false)
          packed_size = byte_size(packed)

          if packed_size > @metadata_max_size do
            raise "Resource metadata size exceeded"
          end

          size_bytes = <<packed_size::unsigned-big-24>>
          meta_bytes = size_bytes <> packed
          {meta_bytes, byte_size(meta_bytes), true}
      end

    # Determine SDU
    sdu =
      if link[:mtu] do
        link.mtu - RNS.Packet.header_maxsize() - 1
      else
        link[:mdu] || @sdu
      end

    # Determine timeout
    timeout =
      timeout ||
        (get_in(link, [Access.key(:stats), Access.key(:rtt)]) || 1.0) * Map.get(link, :traffic_timeout_factor, 6)

    base = %__MODULE__{
      link: link,
      sdu: sdu,
      max_retries: @max_retries,
      max_adv_retries: @max_adv_retries,
      retries_left: @max_retries,
      timeout_factor: Map.get(link, :traffic_timeout_factor, 6),
      part_timeout_factor: @part_timeout_factor,
      sender_grace_time: @sender_grace_time,
      hmu_retry_ok: false,
      watchdog_job_id: 0,
      progress_callback: progress_callback,
      rtt: nil,
      rtt_rxd_bytes: 0,
      req_sent: 0,
      req_resp_rtt_rate: 0,
      rtt_rxd_bytes_at_part_req: 0,
      req_data_rtt_rate: 0,
      eifr: nil,
      previous_eifr: nil,
      fast_rate_rounds: 0,
      very_slow_rate_rounds: 0,
      request_id: request_id,
      started_transferring: nil,
      is_response: is_response,
      auto_compress: auto_compress,
      auto_compress_option: auto_compress_opt,
      auto_compress_limit: auto_compress_limit,
      req_hashlist: [],
      receiver_min_consecutive_height: 0,
      timeout: timeout,
      metadata: metadata_bytes,
      metadata_size: metadata_size,
      has_metadata: has_metadata,
      assembly_lock: false,
      preparing_next_segment: false
    }

    if data != nil do
      build_sender(base, data, link, segment_index, original_hash, callback)
    else
      # Receiver-side — just return base with initiator: false
      %{base | initiator: false, status: @status_none, callback: callback}
    end
  end

  # ── Sender-side construction ──────────────────────────────────

  defp build_sender(resource, data, link, segment_index, original_hash, callback) do
    data_size = byte_size(data)
    total_size = data_size + resource.metadata_size

    # Determine segmentation
    {resource_data, total_segments, seg_idx, split, input_file} =
      if total_size <= @max_efficient_size do
        {data, 1, 1, false, nil}
      else
        total_segs = div(total_size - 1, @max_efficient_size) + 1
        first_read_size = @max_efficient_size - resource.metadata_size

        segment_data =
          if segment_index == 1 do
            read_len = min(first_read_size, data_size)
            <<seg::binary-size(read_len), _::binary>> = data
            seg
          else
            seek_position = first_read_size + (segment_index - 2) * @max_efficient_size
            read_size = min(@max_efficient_size, data_size - seek_position)
            <<_::binary-size(seek_position), seg::binary-size(read_size), _::binary>> = data
            seg
          end

        {segment_data, total_segs, segment_index, true, data}
      end

    # Prepend metadata if present
    full_data =
      if resource.has_metadata do
        resource.metadata <> resource_data
      else
        resource_data
      end

    # Compress if enabled and within limit
    {final_data, compressed} =
      if resource.auto_compress and data_size <= resource.auto_compress_limit do
        compressed_data = :zlib.compress(full_data)

        if byte_size(compressed_data) < byte_size(full_data) do
          {compressed_data, true}
        else
          {full_data, false}
        end
      else
        {full_data, false}
      end

    # Prepend random hash and encrypt
    <<random_prefix::binary-size(@random_hash_size), _::binary>> = Identity.random_hash()
    prefixed_data = random_prefix <> final_data

    # Encrypt using link
    encrypted_data = encrypt_data(link, prefixed_data)

    size = byte_size(encrypted_data)
    total_parts = ceil(size / resource.sdu)

    # Generate resource hash and hashmap
    <<resource_random_hash::binary-size(@random_hash_size), _::binary>> = Identity.random_hash()

    resource_hash = Identity.full_hash(full_data <> resource_random_hash)
    truncated_hash = Identity.truncated_hash(full_data <> resource_random_hash)
    expected_proof = Identity.full_hash(full_data <> resource_hash)

    actual_original_hash = original_hash || resource_hash

    # Build parts and hashmap (with collision detection)
    {parts, hashmap_binary} =
      build_hashmap(encrypted_data, resource.sdu, total_parts, resource_random_hash, link)

    %{
      resource
      | initiator: true,
        callback: callback,
        data: nil,
        encrypted: true,
        compressed: compressed,
        size: size,
        total_size: total_size,
        uncompressed_size: byte_size(full_data),
        total_parts: total_parts,
        sent_parts: 0,
        random_hash: resource_random_hash,
        hash: resource_hash,
        truncated_hash: truncated_hash,
        expected_proof: expected_proof,
        original_hash: actual_original_hash,
        parts: parts,
        hashmap: hashmap_binary,
        split: split,
        segment_index: seg_idx,
        total_segments: total_segments,
        input_file: input_file,
        status: @status_none
    }
  end

  defp encrypt_data(link, data) do
    if is_map(link) and is_function(Map.get(link, :encrypt_fn)) do
      link.encrypt_fn.(data)
    else
      case link do
        %{token: token} when not is_nil(token) ->
          RNS.Cryptography.Token.encrypt(token, data)

        _ ->
          data
      end
    end
  end

  defp decrypt_data(link, data) do
    if is_map(link) and is_function(Map.get(link, :decrypt_fn)) do
      link.decrypt_fn.(data)
    else
      case link do
        %{token: token} when not is_nil(token) ->
          RNS.Cryptography.Token.decrypt(token, data)

        _ ->
          data
      end
    end
  end

  defp build_hashmap(encrypted_data, sdu, total_parts, random_hash, link) do
    do_build_hashmap(encrypted_data, sdu, total_parts, random_hash, link, 0)
  end

  defp do_build_hashmap(encrypted_data, sdu, total_parts, random_hash, link, attempt)
       when attempt < 10 do
    result =
      Enum.reduce_while(0..(total_parts - 1), {[], <<>>, MapSet.new()}, fn i,
                                                                           {parts_acc,
                                                                            hashmap_acc,
                                                                            guard_set} ->
        start_pos = i * sdu
        end_pos = min((i + 1) * sdu, byte_size(encrypted_data))
        part_len = end_pos - start_pos
        <<_::binary-size(start_pos), part_data::binary-size(part_len), _::binary>> = encrypted_data

        map_hash = map_hash(part_data, random_hash)

        if MapSet.member?(guard_set, map_hash) do
          {:halt, :collision}
        else
          guard_set =
            if MapSet.size(guard_set) > RNS.Resource.Advertisement.collision_guard_size() do
              # Simple approximation: just keep adding (Python pops from front of list)
              MapSet.put(guard_set, map_hash)
            else
              MapSet.put(guard_set, map_hash)
            end

          part = %{
            data: part_data,
            map_hash: map_hash,
            raw: pack_resource_part(link, part_data),
            sent: false
          }

          {:cont, {parts_acc ++ [part], hashmap_acc <> map_hash, guard_set}}
        end
      end)

    case result do
      :collision ->
        do_build_hashmap(encrypted_data, sdu, total_parts, random_hash, link, attempt + 1)

      {parts, hashmap, _guard} ->
        {parts, hashmap}
    end
  end

  defp pack_resource_part(_link, data) do
    # In the real implementation, this would create a Packet and pack it.
    # For now, we just store the data as the raw representation.
    data
  end

  @doc "Compute a map hash for a part."
  @spec map_hash(binary(), binary()) :: binary()
  def map_hash(data, random_hash) do
    <<hash::binary-size(@maphash_len), _::binary>> = Identity.full_hash(data <> random_hash)
    hash
  end

  # ── Advertise ─────────────────────────────────────────────────

  @doc """
  Prepares the resource for advertisement. Returns the updated resource
  with advertisement packet data and ADVERTISED status.
  """
  @spec advertise(t()) :: t()
  def advertise(%__MODULE__{} = resource) do
    adv_data = RNS.Resource.Advertisement.pack(RNS.Resource.Advertisement.new(resource))
    now = now_float()

    %{
      resource
      | status: @status_advertised,
        advertisement_packet: adv_data,
        last_activity: now,
        started_transferring: now,
        adv_sent: now,
        rtt: nil,
        retries_left: resource.max_adv_retries
    }
  end

  # ── Accept (receiver-side) ────────────────────────────────────

  @doc """
  Accept a resource advertisement. Creates a receiver-side Resource from
  the advertisement data.

  Returns `{:ok, resource}` or `{:error, reason}`.
  """
  @spec accept(map(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def accept(adv, link, opts \\ []) do
    callback = Keyword.get(opts, :callback)
    progress_callback = Keyword.get(opts, :progress_callback)
    request_id = Keyword.get(opts, :request_id)

    try do
      resource = new(nil, link, request_id: request_id)

      now = now_float()

      sdu =
        if link[:mtu] do
          link.mtu - RNS.Packet.header_maxsize() - 1
        else
          link[:mdu] || @sdu
        end

      total_parts = ceil(adv.t / sdu)

      resource = %{
        resource
        | status: @status_transferring,
          flags: adv.f,
          size: adv.t,
          total_size: adv.d,
          uncompressed_size: adv.d,
          hash: adv.h,
          original_hash: adv.o,
          random_hash: adv.r,
          hashmap_raw: adv.m,
          encrypted: (adv.f &&& 0x01) != 0,
          compressed: (adv.f >>> 1 &&& 0x01) != 0,
          initiator: false,
          callback: callback,
          progress_callback: progress_callback,
          total_parts: total_parts,
          received_count: 0,
          outstanding_parts: 0,
          parts: List.duplicate(nil, total_parts),
          window: @window,
          window_max: @window_max_slow,
          window_min: @window_min,
          window_flexibility: @window_flexibility,
          last_activity: now,
          started_transferring: now,
          segment_index: adv.i,
          total_segments: adv.l,
          split: adv.l > 1,
          has_metadata: adv.x,
          hashmap: List.duplicate(nil, total_parts),
          hashmap_height: 0,
          waiting_for_hmu: false,
          receiving_part: false,
          consecutive_completed_height: -1,
          sdu: sdu
      }

      # Apply previous window/eifr from link if available
      resource =
        case Map.get(link, :last_resource_window) do
          nil -> resource
          prev_window -> %{resource | window: prev_window}
        end

      resource =
        case Map.get(link, :last_resource_eifr) do
          nil -> resource
          prev_eifr -> %{resource | previous_eifr: prev_eifr}
        end

      # Apply initial hashmap
      resource = hashmap_update(resource, 0, adv.m)

      {:ok, resource}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Reject a resource advertisement. Returns data suitable for sending
  as a RESOURCE_RCL packet.
  """
  @spec reject(binary()) :: {:ok, binary()} | {:error, term()}
  def reject(advertisement_plaintext) do
    try do
      adv = RNS.Resource.Advertisement.unpack(advertisement_plaintext)
      {:ok, adv.h}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ── Hashmap management ────────────────────────────────────────

  @doc "Process a hashmap update packet."
  @spec hashmap_update_packet(t(), binary()) :: t()
  def hashmap_update_packet(%__MODULE__{status: @status_failed} = resource, _plaintext),
    do: resource

  def hashmap_update_packet(%__MODULE__{} = resource, plaintext) do
    resource = %{resource | last_activity: now_float(), retries_left: resource.max_retries}

    hash_len = div(Identity.hashlength(), 8)
    <<_hash::binary-size(hash_len), update_data::binary>> = plaintext
    [segment, hashmap] = Msgpax.unpack!(update_data)
    hashmap_update(resource, segment, hashmap)
  end

  @doc "Update the hashmap with data from a segment."
  @spec hashmap_update(t(), non_neg_integer(), binary()) :: t()
  def hashmap_update(%__MODULE__{status: @status_failed} = resource, _segment, _hashmap),
    do: resource

  def hashmap_update(%__MODULE__{} = resource, segment, hashmap) do
    seg_len = RNS.Resource.Advertisement.hashmap_max_len()
    hashes = div(byte_size(hashmap), @maphash_len)

    {updated_hashmap, new_height} =
      Enum.reduce(0..(hashes - 1), {resource.hashmap, resource.hashmap_height}, fn i,
                                                                                   {hmap, height} ->
        idx = i + segment * seg_len
        offset = i * @maphash_len
        <<_::binary-size(offset), hash::binary-size(@maphash_len), _::binary>> = hashmap

        new_height =
          if Enum.at(hmap, idx) == nil do
            height + 1
          else
            height
          end

        {List.replace_at(hmap, idx, hash), new_height}
      end)

    %{
      resource
      | status: @status_transferring,
        hashmap: updated_hashmap,
        hashmap_height: new_height,
        waiting_for_hmu: false
    }
  end

  # ── Receive part (receiver-side) ──────────────────────────────

  @doc """
  Process a received part. Updates the resource state with the new data
  and manages window sizing and rate tracking.

  Returns the updated resource and an action atom:
  - `:continue` — more parts expected
  - `:assemble` — all parts received, ready to assemble
  - `:request_next` — window exhausted, request more parts
  """
  @spec receive_part(t(), binary(), keyword()) :: {t(), atom()}
  def receive_part(resource, part_data, opts \\ [])

  def receive_part(%__MODULE__{status: @status_failed} = resource, _part_data, _opts) do
    {resource, :continue}
  end

  def receive_part(%__MODULE__{} = resource, part_data, opts) do
    packet_raw_len = Keyword.get(opts, :packet_raw_len, byte_size(part_data))
    now = now_float()

    resource = %{
      resource
      | receiving_part: true,
        last_activity: now,
        retries_left: resource.max_retries
    }

    # RTT tracking on first response
    resource =
      if resource.req_resp == nil and resource.req_sent != 0 do
        rtt = now - resource.req_sent

        resource = %{
          resource
          | req_resp: now,
            part_timeout_factor: @part_timeout_factor_after_rtt
        }

        resource =
          cond do
            resource.rtt == nil ->
              %{resource | rtt: Map.get(resource.link, :rtt, 1.0) || 1.0}

            rtt < resource.rtt ->
              %{resource | rtt: max(resource.rtt - resource.rtt * 0.05, rtt)}

            rtt > resource.rtt ->
              %{resource | rtt: min(resource.rtt + resource.rtt * 0.05, rtt)}

            true ->
              resource
          end

        # Rate tracking
        if rtt > 0 do
          req_resp_cost = packet_raw_len + resource.req_sent_bytes
          req_resp_rtt_rate = req_resp_cost / rtt

          resource = %{resource | req_resp_rtt_rate: req_resp_rtt_rate}

          if req_resp_rtt_rate > @rate_fast and
               resource.fast_rate_rounds < @fast_rate_threshold do
            fast_rounds = resource.fast_rate_rounds + 1

            resource = %{resource | fast_rate_rounds: fast_rounds}

            if fast_rounds == @fast_rate_threshold do
              %{resource | window_max: @window_max_fast}
            else
              resource
            end
          else
            resource
          end
        else
          resource
        end
      else
        resource
      end

    if resource.status != @status_failed do
      resource = %{resource | status: @status_transferring}
      part_hash = map_hash(part_data, resource.random_hash)

      consecutive_index = max(resource.consecutive_completed_height, 0)

      # Search window for matching hash
      {resource, matched} =
        Enum.reduce_while(
          0..(resource.window - 1),
          {resource, false},
          fn offset, {res, _matched} ->
            i = consecutive_index + offset

            if i >= length(res.hashmap) do
              {:halt, {res, false}}
            else
              map_hash = Enum.at(res.hashmap, i)

              if map_hash == part_hash and Enum.at(res.parts, i) == nil do
                # Insert part
                parts = List.replace_at(res.parts, i, part_data)
                rtt_rxd_bytes = res.rtt_rxd_bytes + byte_size(part_data)
                received_count = res.received_count + 1
                outstanding_parts = max(res.outstanding_parts - 1, 0)

                # Update consecutive completed height
                cch =
                  if i == res.consecutive_completed_height + 1 do
                    advance_consecutive(parts, i)
                  else
                    res.consecutive_completed_height
                  end

                res = %{
                  res
                  | parts: parts,
                    rtt_rxd_bytes: rtt_rxd_bytes,
                    received_count: received_count,
                    outstanding_parts: outstanding_parts,
                    consecutive_completed_height: cch
                }

                {:halt, {res, true}}
              else
                {:cont, {res, false}}
              end
            end
          end
        )

      resource = %{resource | receiving_part: false}

      cond do
        resource.received_count == resource.total_parts and not resource.assembly_lock ->
          resource = %{resource | assembly_lock: true}
          {resource, :assemble}

        matched and resource.outstanding_parts == 0 ->
          # Window exhausted, adjust window
          resource =
            if resource.window < resource.window_max do
              new_window = resource.window + 1

              new_window_min =
                if new_window - resource.window_min > resource.window_flexibility - 1 do
                  resource.window_min + 1
                else
                  resource.window_min
                end

              %{resource | window: new_window, window_min: new_window_min}
            else
              resource
            end

          # Data rate tracking
          resource =
            if resource.req_sent != 0 do
              rtt = now - resource.req_sent
              req_transferred = resource.rtt_rxd_bytes - resource.rtt_rxd_bytes_at_part_req

              if rtt != 0 do
                req_data_rtt_rate = req_transferred / rtt
                resource = %{resource | req_data_rtt_rate: req_data_rtt_rate}
                resource = update_eifr(resource)
                resource = %{resource | rtt_rxd_bytes_at_part_req: resource.rtt_rxd_bytes}

                resource =
                  if req_data_rtt_rate > @rate_fast and
                       resource.fast_rate_rounds < @fast_rate_threshold do
                    fast_rounds = resource.fast_rate_rounds + 1
                    resource = %{resource | fast_rate_rounds: fast_rounds}

                    if fast_rounds == @fast_rate_threshold do
                      %{resource | window_max: @window_max_fast}
                    else
                      resource
                    end
                  else
                    resource
                  end

                if resource.fast_rate_rounds == 0 and req_data_rtt_rate < @rate_very_slow and
                     resource.very_slow_rate_rounds < @very_slow_rate_threshold do
                  slow_rounds = resource.very_slow_rate_rounds + 1
                  resource = %{resource | very_slow_rate_rounds: slow_rounds}

                  if slow_rounds == @very_slow_rate_threshold do
                    %{resource | window_max: @window_max_very_slow}
                  else
                    resource
                  end
                else
                  resource
                end
              else
                resource
              end
            else
              resource
            end

          {resource, :request_next}

        true ->
          {resource, :continue}
      end
    else
      resource = %{resource | receiving_part: false}
      {resource, :continue}
    end
  end

  defp advance_consecutive(parts, from) do
    cp = from + 1

    Enum.reduce_while(cp..(length(parts) - 1)//1, from, fn idx, _acc ->
      if Enum.at(parts, idx) != nil do
        {:cont, idx}
      else
        {:halt, idx - 1}
      end
    end)
  end

  # ── Request next (receiver-side) ──────────────────────────────

  @doc """
  Build a request for the next set of parts. Returns `{resource, request_data}`
  where `request_data` is the binary to send as a RESOURCE_REQ packet.
  """
  @spec request_next(t()) :: {t(), binary()}
  def request_next(%__MODULE__{status: @status_failed} = resource) do
    {resource, <<>>}
  end

  def request_next(%__MODULE__{waiting_for_hmu: true} = resource) do
    {resource, <<>>}
  end

  def request_next(%__MODULE__{} = resource) do
    pn = resource.consecutive_completed_height + 1
    search_start = pn
    search_size = resource.window

    {requested_hashes, outstanding, hashmap_exhausted} =
      Enum.reduce_while(0..(search_size - 1), {<<>>, 0, @hashmap_is_not_exhausted}, fn offset,
                                                                                       {hashes,
                                                                                        out,
                                                                                        exhausted} ->
        idx = search_start + offset

        if idx >= length(resource.parts) do
          {:halt, {hashes, out, exhausted}}
        else
          part = Enum.at(resource.parts, idx)

          if part == nil do
            part_hash = Enum.at(resource.hashmap, idx)

            if part_hash != nil do
              new_hashes = hashes <> part_hash
              new_out = out + 1

              if new_out >= resource.window do
                {:halt, {new_hashes, new_out, exhausted}}
              else
                {:cont, {new_hashes, new_out, exhausted}}
              end
            else
              {:halt, {hashes, out, @hashmap_is_exhausted}}
            end
          else
            {:cont, {hashes, out, exhausted}}
          end
        end
      end)

    hmu_part =
      if hashmap_exhausted == @hashmap_is_exhausted do
        last_map_hash = Enum.at(resource.hashmap, resource.hashmap_height - 1)
        <<@hashmap_is_exhausted>> <> (last_map_hash || <<>>)
      else
        <<@hashmap_is_not_exhausted>>
      end

    request_data = hmu_part <> resource.hash <> requested_hashes

    now = now_float()

    resource = %{
      resource
      | outstanding_parts: outstanding,
        last_activity: now,
        req_sent: now,
        req_sent_bytes: byte_size(request_data),
        req_resp: nil,
        waiting_for_hmu: hashmap_exhausted == @hashmap_is_exhausted
    }

    {resource, request_data}
  end

  # ── Request (sender-side — handle incoming part requests) ─────

  @doc """
  Process an incoming part request from the receiver.
  Returns `{resource, actions}` where actions is a list of
  `{:send_part, part_data}` and optionally `{:send_hmu, hmu_data}` tuples.
  """
  @spec request(t(), binary()) :: {t(), list()}
  def request(%__MODULE__{status: @status_failed} = resource, _request_data) do
    {resource, []}
  end

  def request(%__MODULE__{} = resource, request_data) do
    now = now_float()
    rtt = now - (resource.adv_sent || now)

    resource =
      if resource.rtt == nil do
        %{resource | rtt: rtt}
      else
        resource
      end

    resource =
      if resource.status != @status_transferring do
        %{resource | status: @status_transferring}
      else
        resource
      end

    resource = %{resource | retries_left: resource.max_retries, last_activity: now}

    wants_more_hashmap = :binary.at(request_data, 0) == @hashmap_is_exhausted

    pad =
      if wants_more_hashmap do
        1 + @maphash_len
      else
        1
      end

    hash_len = div(Identity.hashlength(), 8)

    skip = pad + hash_len
    <<_::binary-size(skip), requested_hashes_bin::binary>> = request_data

    # Parse requested hashes
    map_hashes =
      for <<hash::binary-size(@maphash_len) <- requested_hashes_bin>>, do: hash

    map_hash_set = MapSet.new(map_hashes)

    # Search scope
    search_start = resource.receiver_min_consecutive_height

    search_end =
      min(
        search_start + RNS.Resource.Advertisement.collision_guard_size(),
        length(resource.parts)
      )

    search_scope = Enum.slice(resource.parts, search_start..(search_end - 1)//1)

    requested_parts =
      Enum.filter(search_scope, fn part ->
        MapSet.member?(map_hash_set, part.map_hash)
      end)

    # Send requested parts
    {resource, send_actions} =
      Enum.reduce(requested_parts, {resource, []}, fn part, {res, actions} ->
        action =
          if part.sent do
            {:resend_part, part}
          else
            {:send_part, part}
          end

        res = %{
          res
          | sent_parts: res.sent_parts + 1,
            last_activity: now_float(),
            last_part_sent: now_float()
        }

        {res, actions ++ [action]}
      end)

    # Handle hashmap update request
    {resource, hmu_actions} =
      if wants_more_hashmap do
        <<_::8, last_map_hash::binary-size(@maphash_len), _::binary>> = request_data

        # Find the part index matching last_map_hash
        search_range = Enum.slice(resource.parts, search_start..(search_end - 1)//1)

        part_index =
          Enum.reduce_while(
            Enum.with_index(search_range, search_start),
            search_start,
            fn {part, idx}, _acc ->
              if part.map_hash == last_map_hash do
                {:halt, idx + 1}
              else
                {:cont, idx + 1}
              end
            end
          )

        resource = %{
          resource
          | receiver_min_consecutive_height: max(part_index - 1 - @window_max, 0)
        }

        hashmap_max_len = RNS.Resource.Advertisement.hashmap_max_len()

        if rem(part_index, hashmap_max_len) != 0 do
          # Sequencing error
          {%{resource | status: @status_failed}, [{:error, :sequencing_error}]}
        else
          segment = div(part_index, hashmap_max_len)
          hashmap_start = segment * hashmap_max_len
          hashmap_end = min((segment + 1) * hashmap_max_len, length(resource.parts))

          hashmap_data =
            Enum.reduce(hashmap_start..(hashmap_end - 1)//1, <<>>, fn i, acc ->
              offset = i * @maphash_len
              <<_::binary-size(offset), hash::binary-size(@maphash_len), _::binary>> = resource.hashmap
              acc <> hash
            end)

          hmu_payload = resource.hash <> Msgpax.pack!([segment, hashmap_data], iodata: false)
          {resource, [{:send_hmu, hmu_payload}]}
        end
      else
        {resource, []}
      end

    # Check if all parts sent
    resource =
      if resource.sent_parts == length(resource.parts) do
        %{resource | status: @status_awaiting_proof, retries_left: 3}
      else
        resource
      end

    {resource, send_actions ++ hmu_actions}
  end

  # ── Assemble (receiver-side) ──────────────────────────────────

  @doc """
  Assemble received parts into the complete resource data.
  Returns `{resource, result}` where result is `:ok`, `:corrupt`, or `{:error, reason}`.
  """
  @spec assemble(t()) :: {t(), atom() | {:error, term()}}
  def assemble(%__MODULE__{status: @status_failed} = resource) do
    {resource, {:error, :failed}}
  end

  def assemble(%__MODULE__{} = resource) do
    try do
      resource = %{resource | status: @status_assembling}
      stream = IO.iodata_to_binary(resource.parts)

      # Decrypt
      data =
        if resource.encrypted do
          decrypt_data(resource.link, stream)
        else
          stream
        end

      # Strip random hash prefix
      <<_random::binary-size(@random_hash_size), data::binary>> = data

      # Decompress
      data =
        if resource.compressed do
          :zlib.uncompress(data)
        else
          data
        end

      # Verify hash
      calculated_hash = Identity.full_hash(data <> resource.random_hash)

      if calculated_hash == resource.hash do
        # Extract metadata if present
        {metadata, payload} =
          if resource.has_metadata and resource.segment_index == 1 do
            <<metadata_size::unsigned-big-24, rest::binary>> = data
            <<packed_metadata::binary-size(metadata_size), payload::binary>> = rest
            metadata = Msgpax.unpack!(packed_metadata)
            {metadata, payload}
          else
            {nil, data}
          end

        # Build proof
        proof = Identity.full_hash(data <> resource.hash)
        proof_data = resource.hash <> proof

        resource = %{
          resource
          | status: @status_complete,
            data: payload,
            metadata: metadata
        }

        {resource, {:ok, proof_data}}
      else
        {%{resource | status: @status_corrupt}, :corrupt}
      end
    rescue
      e ->
        {%{resource | status: @status_corrupt}, {:error, Exception.message(e)}}
    end
  end

  # ── Validate proof (sender-side) ──────────────────────────────

  @doc """
  Validate a proof received from the receiver.
  Returns the updated resource.
  """
  @spec validate_proof(t(), binary()) :: t()
  def validate_proof(%__MODULE__{status: @status_failed} = resource, _proof_data), do: resource

  def validate_proof(%__MODULE__{} = resource, proof_data) do
    hash_len = div(Identity.hashlength(), 8)
    expected_len = hash_len * 2

    if byte_size(proof_data) == expected_len do
      <<_resource_hash::binary-size(hash_len), proof::binary-size(hash_len)>> = proof_data

      if proof == resource.expected_proof do
        %{resource | status: @status_complete}
      else
        resource
      end
    else
      resource
    end
  end

  # ── Cancel ────────────────────────────────────────────────────

  @doc """
  Cancel the resource transfer.
  Returns `{resource, cancel_data}` where cancel_data is the hash to send
  as a RESOURCE_ICL packet (for initiator) or nil.
  """
  @spec cancel(t()) :: {t(), binary() | nil}
  def cancel(%__MODULE__{} = resource) do
    if resource.status < @status_complete do
      resource = %{resource | status: @status_failed}

      cancel_data =
        if resource.initiator do
          resource.hash
        else
          nil
        end

      {resource, cancel_data}
    else
      {resource, nil}
    end
  end

  @doc "Mark a resource as rejected (sender-side)."
  @spec rejected(t()) :: t()
  def rejected(%__MODULE__{} = resource) do
    if resource.status < @status_complete and resource.initiator do
      %{resource | status: @status_rejected}
    else
      resource
    end
  end

  # ── Update EIFR ──────────────────────────────────────────────

  @doc "Update the expected inflight rate."
  @spec update_eifr(t()) :: t()
  def update_eifr(%__MODULE__{} = resource) do
    rtt = resource.rtt || Map.get(resource.link, :rtt, 1.0) || 1.0

    expected_inflight_rate =
      cond do
        resource.req_data_rtt_rate != 0 ->
          resource.req_data_rtt_rate * 8

        resource.previous_eifr != nil ->
          resource.previous_eifr

        true ->
          establishment_cost = Map.get(resource.link, :establishment_cost, 0)
          if rtt > 0, do: establishment_cost * 8 / rtt, else: 0
      end

    %{resource | eifr: expected_inflight_rate}
  end

  # ── Watchdog check ────────────────────────────────────────────

  @doc """
  Perform a watchdog check on the resource. Returns `{resource, action}` where
  action is one of:
  - `:ok` — no action needed
  - `:cancel` — resource should be cancelled
  - `:retry_adv` — should retry advertisement
  - `:retry_request` — should retry part request
  - `:query_cache` — should query network cache for proof
  - `{:sleep, seconds}` — suggested sleep time before next check
  """
  @spec watchdog_check(t()) :: {t(), atom() | {:sleep, float()}}
  def watchdog_check(%__MODULE__{status: status} = resource) when status >= @status_assembling do
    {resource, :done}
  end

  def watchdog_check(%__MODULE__{status: @status_advertised} = resource) do
    now = now_float()
    sleep_time = resource.adv_sent + resource.timeout + @processing_grace - now

    if sleep_time < 0 do
      if resource.retries_left <= 0 do
        {%{resource | status: @status_failed}, :cancel}
      else
        resource = %{resource | retries_left: resource.retries_left - 1}
        adv_data = RNS.Resource.Advertisement.pack(RNS.Resource.Advertisement.new(resource))
        now = now_float()
        resource = %{resource | advertisement_packet: adv_data, last_activity: now, adv_sent: now}
        {resource, :retry_adv}
      end
    else
      {resource, {:sleep, min(sleep_time, @watchdog_max_sleep * 1.0)}}
    end
  end

  def watchdog_check(%__MODULE__{status: @status_transferring, initiator: false} = resource) do
    now = now_float()
    retries_used = resource.max_retries - resource.retries_left
    extra_wait = retries_used * @per_retry_delay

    resource = update_eifr(resource)
    eifr = resource.eifr || 1.0

    expected_tof_remaining =
      if eifr > 0 do
        resource.outstanding_parts * resource.sdu * 8 / eifr
      else
        resource.timeout
      end

    sleep_time =
      if resource.req_resp_rtt_rate != 0 do
        resource.last_activity + resource.part_timeout_factor * expected_tof_remaining +
          @retry_grace_time + extra_wait - now
      else
        resource.last_activity +
          resource.part_timeout_factor * (3 * resource.sdu / max(eifr, 1.0)) +
          @retry_grace_time + extra_wait - now
      end

    if sleep_time < 0 do
      if resource.retries_left > 0 do
        resource = shrink_window(resource)

        resource = %{
          resource
          | retries_left: resource.retries_left - 1,
            waiting_for_hmu: false
        }

        {resource, :retry_request}
      else
        {%{resource | status: @status_failed}, :cancel}
      end
    else
      {resource, {:sleep, min(sleep_time, @watchdog_max_sleep * 1.0)}}
    end
  end

  def watchdog_check(%__MODULE__{status: @status_transferring, initiator: true} = resource) do
    now = now_float()
    rtt = resource.rtt || Map.get(resource.link, :rtt, 1.0) || 1.0

    max_extra_wait =
      Enum.reduce(0..(@max_retries - 1), 0, fn r, acc ->
        acc + (r + 1) * @per_retry_delay
      end)

    max_wait =
      rtt * resource.timeout_factor * resource.max_retries + resource.sender_grace_time +
        max_extra_wait

    sleep_time = resource.last_activity + max_wait - now

    if sleep_time < 0 do
      {%{resource | status: @status_failed}, :cancel}
    else
      {resource, {:sleep, min(sleep_time, @watchdog_max_sleep * 1.0)}}
    end
  end

  def watchdog_check(%__MODULE__{status: @status_awaiting_proof} = resource) do
    now = now_float()
    rtt = resource.rtt || Map.get(resource.link, :rtt, 1.0) || 1.0
    last_sent = resource.last_part_sent || resource.last_activity

    sleep_time = last_sent + rtt * @proof_timeout_factor + resource.sender_grace_time - now

    if sleep_time < 0 do
      if resource.retries_left <= 0 do
        {%{resource | status: @status_failed}, :cancel}
      else
        resource = %{resource | retries_left: resource.retries_left - 1, last_part_sent: now}
        expected_data = resource.hash <> resource.expected_proof
        {resource, {:query_cache, expected_data}}
      end
    else
      {resource, {:sleep, min(sleep_time, @watchdog_max_sleep * 1.0)}}
    end
  end

  def watchdog_check(%__MODULE__{status: @status_rejected} = resource) do
    {resource, :done}
  end

  def watchdog_check(%__MODULE__{} = resource) do
    {resource, :ok}
  end

  defp shrink_window(%__MODULE__{} = resource) do
    if resource.window > resource.window_min do
      new_window = resource.window - 1

      new_window_max =
        if resource.window_max > resource.window_min do
          wm = resource.window_max - 1

          if wm - new_window > resource.window_flexibility - 1 do
            wm - 1
          else
            wm
          end
        else
          resource.window_max
        end

      %{resource | window: new_window, window_max: new_window_max}
    else
      resource
    end
  end

  # ── Progress ──────────────────────────────────────────────────

  @doc "Returns the current progress as a float between 0.0 and 1.0."
  @spec progress(t()) :: float()
  def progress(%__MODULE__{status: @status_complete, segment_index: si, total_segments: ts})
      when si == ts,
      do: 1.0

  def progress(%__MODULE__{initiator: true, split: false} = r) do
    if r.total_parts > 0, do: min(1.0, r.sent_parts / r.total_parts), else: 0.0
  end

  def progress(%__MODULE__{initiator: true, split: true} = r) do
    max_parts_per_segment = ceil(@max_efficient_size / r.sdu)
    processed_segments = r.segment_index - 1
    previously_processed = processed_segments * max_parts_per_segment

    factor =
      if r.total_parts < max_parts_per_segment do
        max_parts_per_segment / r.total_parts
      else
        1
      end

    processed = previously_processed + r.sent_parts * factor
    total = r.total_segments * max_parts_per_segment
    if total > 0, do: min(1.0, processed / total), else: 0.0
  end

  def progress(%__MODULE__{initiator: false, split: false} = r) do
    if r.total_parts > 0, do: min(1.0, r.received_count / r.total_parts), else: 0.0
  end

  def progress(%__MODULE__{initiator: false, split: true} = r) do
    max_parts_per_segment = ceil(@max_efficient_size / r.sdu)
    processed_segments = r.segment_index - 1
    previously_processed = processed_segments * max_parts_per_segment

    factor =
      if r.total_parts < max_parts_per_segment do
        max_parts_per_segment / r.total_parts
      else
        1
      end

    processed = previously_processed + r.received_count * factor
    total = r.total_segments * max_parts_per_segment
    if total > 0, do: min(1.0, processed / total), else: 0.0
  end

  @doc "Returns the segment progress as a float between 0.0 and 1.0."
  @spec segment_progress(t()) :: float()
  def segment_progress(%__MODULE__{
        status: @status_complete,
        segment_index: si,
        total_segments: ts
      })
      when si == ts,
      do: 1.0

  def segment_progress(%__MODULE__{initiator: true} = r) do
    if r.total_parts > 0, do: min(1.0, r.sent_parts / r.total_parts), else: 0.0
  end

  def segment_progress(%__MODULE__{initiator: false} = r) do
    if r.total_parts > 0, do: min(1.0, r.received_count / r.total_parts), else: 0.0
  end

  # ── Accessors ─────────────────────────────────────────────────

  @doc "Returns the transfer size in bytes."
  @spec transfer_size(t()) :: non_neg_integer()
  def transfer_size(%__MODULE__{size: size}), do: size

  @doc "Returns the total data size in bytes."
  @spec data_size(t()) :: non_neg_integer()
  def data_size(%__MODULE__{total_size: total_size}), do: total_size

  @doc "Returns the number of parts."
  @spec parts(t()) :: non_neg_integer()
  def parts(%__MODULE__{total_parts: total_parts}), do: total_parts

  @doc "Returns the number of segments."
  @spec segments(t()) :: non_neg_integer()
  def segments(%__MODULE__{total_segments: total_segments}), do: total_segments

  @doc "Returns the resource hash."
  @spec hash(t()) :: binary() | nil
  def hash(%__MODULE__{hash: hash}), do: hash

  @doc "Returns whether the resource is compressed."
  @spec is_compressed(t()) :: boolean()
  def is_compressed(%__MODULE__{compressed: compressed}), do: compressed

  # ── Setters ───────────────────────────────────────────────────

  @doc "Set the completion callback."
  @spec set_callback(t(), function()) :: t()
  def set_callback(%__MODULE__{} = resource, callback) do
    %{resource | callback: callback}
  end

  @doc "Set the progress callback."
  @spec set_progress_callback(t(), function()) :: t()
  def set_progress_callback(%__MODULE__{} = resource, callback) do
    %{resource | progress_callback: callback}
  end

  # ── String representation ─────────────────────────────────────

  defimpl String.Chars do
    def to_string(%RNS.Resource{hash: hash, link: link}) do
      hash_hex =
        if hash, do: Base.encode16(hash, case: :lower), else: "unknown"

      link_id_hex =
        case link do
          %{link_id: lid} when not is_nil(lid) -> Base.encode16(lid, case: :lower)
          _ -> "unknown"
        end

      "<#{hash_hex}/#{link_id_hex}>"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────

  @doc false
  def now_float do
    System.system_time(:millisecond) / 1000.0
  end
end

# ── ResourceAdvertisement ───────────────────────────────────────

defmodule RNS.Resource.Advertisement do
  @moduledoc """
  Represents a resource advertisement, used to negotiate resource transfers.

  Contains transfer metadata: size, hash, hashmap, flags, segmentation info.
  Matches `python/RNS/Resource.py` ResourceAdvertisement class.
  """

  import Bitwise

  @overhead 134
  @hashmap_max_len floor((RNS.Link.mdu() - @overhead) / RNS.Resource.maphash_len())
  @collision_guard_size 2 * RNS.Resource.window_max() + @hashmap_max_len

  defstruct [
    :t,
    :d,
    :n,
    :h,
    :r,
    :o,
    :m,
    :f,
    :i,
    :l,
    :q,
    :link,
    e: false,
    c: false,
    s: false,
    u: false,
    p: false,
    x: false
  ]

  @type t :: %__MODULE__{}

  @doc "Advertisement overhead in bytes."
  @spec overhead() :: non_neg_integer()
  def overhead, do: @overhead

  @doc "Maximum number of hashmap entries per advertisement."
  @spec hashmap_max_len() :: non_neg_integer()
  def hashmap_max_len, do: @hashmap_max_len

  @doc "Size of the collision guard list."
  @spec collision_guard_size() :: non_neg_integer()
  def collision_guard_size, do: @collision_guard_size

  @doc "Create an advertisement from a resource."
  @spec new(RNS.Resource.t()) :: t()
  def new(%RNS.Resource{} = resource) do
    {u, p} =
      if resource.request_id != nil do
        if not resource.is_response, do: {true, false}, else: {false, true}
      else
        {false, false}
      end

    flags =
      bool_to_int(resource.has_metadata) <<< 5 |||
        bool_to_int(p) <<< 4 |||
        bool_to_int(u) <<< 3 |||
        bool_to_int(resource.split) <<< 2 |||
        bool_to_int(resource.compressed) <<< 1 |||
        bool_to_int(resource.encrypted)

    %__MODULE__{
      t: resource.size,
      d: resource.total_size,
      n: length(resource.parts),
      h: resource.hash,
      r: resource.random_hash,
      o: resource.original_hash,
      m: resource.hashmap,
      c: resource.compressed,
      e: resource.encrypted,
      s: resource.split,
      x: resource.has_metadata,
      i: resource.segment_index,
      l: resource.total_segments,
      q: resource.request_id,
      u: u,
      p: p,
      f: flags
    }
  end

  @doc "Pack an advertisement into binary (MessagePack)."
  @spec pack(t(), non_neg_integer()) :: binary()
  def pack(%__MODULE__{} = adv, segment \\ 0) do
    maphash_len = RNS.Resource.maphash_len()
    hashmap_start = segment * @hashmap_max_len
    hashmap_end = min((segment + 1) * @hashmap_max_len, adv.n)

    hashmap =
      if is_binary(adv.m) do
        # Binary hashmap (sender-side)
        Enum.reduce(hashmap_start..(hashmap_end - 1)//1, <<>>, fn i, acc ->
          offset = i * maphash_len
          <<_::binary-size(offset), hash::binary-size(maphash_len), _::binary>> = adv.m
          acc <> hash
        end)
      else
        # Already segmented or empty
        adv.m || <<>>
      end

    data = %{
      "t" => adv.t,
      "d" => adv.d,
      "n" => adv.n,
      "h" => adv.h,
      "r" => adv.r,
      "o" => adv.o,
      "i" => adv.i,
      "l" => adv.l,
      "q" => adv.q,
      "f" => adv.f,
      "m" => hashmap
    }

    Msgpax.pack!(data, iodata: false)
  end

  @doc "Unpack a binary advertisement (MessagePack) into an Advertisement struct."
  @spec unpack(binary()) :: t()
  def unpack(data) do
    dict = Msgpax.unpack!(data)

    f = dict["f"]

    %__MODULE__{
      t: dict["t"],
      d: dict["d"],
      n: dict["n"],
      h: dict["h"],
      r: dict["r"],
      o: dict["o"],
      m: dict["m"],
      f: f,
      i: dict["i"],
      l: dict["l"],
      q: dict["q"],
      e: (f &&& 0x01) == 0x01,
      c: (f >>> 1 &&& 0x01) == 0x01,
      s: (f >>> 2 &&& 0x01) == 0x01,
      u: (f >>> 3 &&& 0x01) == 0x01,
      p: (f >>> 4 &&& 0x01) == 0x01,
      x: (f >>> 5 &&& 0x01) == 0x01
    }
  end

  @doc "Check if an advertisement represents a request."
  @spec is_request(t()) :: boolean()
  def is_request(%__MODULE__{q: q, u: u}) when q != nil and u == true, do: true
  def is_request(_), do: false

  @doc "Check if an advertisement represents a response."
  @spec is_response(t()) :: boolean()
  def is_response(%__MODULE__{q: q, p: p}) when q != nil and p == true, do: true
  def is_response(_), do: false

  @doc "Read the request ID from an advertisement."
  @spec read_request_id(t()) :: binary() | nil
  def read_request_id(%__MODULE__{q: q}), do: q

  @doc "Read the transfer size from an advertisement."
  @spec read_transfer_size(t()) :: non_neg_integer()
  def read_transfer_size(%__MODULE__{t: t}), do: t

  @doc "Read the data size from an advertisement."
  @spec read_size(t()) :: non_neg_integer()
  def read_size(%__MODULE__{d: d}), do: d

  @doc "Get the transfer size."
  @spec transfer_size(t()) :: non_neg_integer()
  def transfer_size(%__MODULE__{t: t}), do: t

  @doc "Get the data size."
  @spec data_size(t()) :: non_neg_integer()
  def data_size(%__MODULE__{d: d}), do: d

  @doc "Get the number of parts."
  @spec parts(t()) :: non_neg_integer()
  def parts(%__MODULE__{n: n}), do: n

  @doc "Get the number of segments."
  @spec segments(t()) :: non_neg_integer()
  def segments(%__MODULE__{l: l}), do: l

  @doc "Get the resource hash."
  @spec hash(t()) :: binary()
  def hash(%__MODULE__{h: h}), do: h

  @doc "Check if compressed."
  @spec is_compressed(t()) :: boolean()
  def is_compressed(%__MODULE__{c: c}), do: c

  @doc "Check if has metadata."
  @spec has_metadata(t()) :: boolean()
  def has_metadata(%__MODULE__{x: x}), do: x

  @doc "Get the link."
  @spec get_link(t()) :: term()
  def get_link(%__MODULE__{link: link}), do: link

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0
  defp bool_to_int(val) when is_integer(val), do: if(val != 0, do: 1, else: 0)
end
