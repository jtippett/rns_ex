defmodule RNS.Transport.AnnounceHandler do
  @moduledoc """
  Handles announce processing for the RNS Transport system.

  Processes inbound announces, manages announce retransmission queues,
  rate limiting, deduplication via random blobs, and path table update
  decisions.

  Ported from announce-related logic in `python/RNS/Transport.py`.
  """

  alias RNS.Transport
  alias RNS.Identity

  @announce_table :rns_announce_table
  @announce_rate_table :rns_announce_rate_table

  # ── AnnounceEntry struct ──────────────────────────────────────────

  defmodule AnnounceEntry do
    @moduledoc """
    A single entry in the announce table, tracking an announce waiting
    for retransmission.

    Corresponds to the Python announce table 9-element list:
      [timestamp, retransmit_timeout, retries, received_from, hops,
       packet, local_rebroadcasts, block_rebroadcasts, attached_interface]
    """
    @type t :: %__MODULE__{
            timestamp: number() | nil,
            retransmit_timeout: number() | nil,
            retries: non_neg_integer() | nil,
            received_from: binary() | nil,
            hops: non_neg_integer() | nil,
            packet: map() | nil,
            local_rebroadcasts: non_neg_integer() | nil,
            block_rebroadcasts: boolean() | nil,
            attached_interface: map() | nil
          }

    defstruct [
      :timestamp,
      :retransmit_timeout,
      :retries,
      :received_from,
      :hops,
      :packet,
      :local_rebroadcasts,
      :block_rebroadcasts,
      :attached_interface
    ]
  end

  # ── Announce Table Operations ─────────────────────────────────────

  @doc "Inserts or updates an announce entry in the announce table."
  @spec put_announce_entry(binary(), AnnounceEntry.t()) :: true
  def put_announce_entry(destination_hash, %AnnounceEntry{} = entry) do
    :ets.insert(@announce_table, {destination_hash, entry})
  end

  @doc "Deletes an announce entry from the announce table."
  @spec delete_announce_entry(binary()) :: true
  def delete_announce_entry(destination_hash) do
    :ets.delete(@announce_table, destination_hash)
  end

  # ── Timebase / Random Blob Helpers ────────────────────────────────

  @doc """
  Extracts the emission timestamp from a 10-byte random blob.
  Bytes 5-10 (0-indexed) contain the timestamp as a big-endian 40-bit integer.
  """
  @spec timebase_from_random_blob(binary()) :: non_neg_integer()
  def timebase_from_random_blob(random_blob) when byte_size(random_blob) >= 10 do
    <<_prefix::binary-size(5), timestamp::unsigned-big-integer-size(40)>> = random_blob
    timestamp
  end

  @doc """
  Returns the maximum emission timestamp from a list of random blobs.
  Returns 0 for an empty list.
  """
  @spec timebase_from_random_blobs([binary()]) :: non_neg_integer()
  def timebase_from_random_blobs([]), do: 0

  def timebase_from_random_blobs(random_blobs) do
    Enum.reduce(random_blobs, 0, fn blob, acc ->
      max(acc, timebase_from_random_blob(blob))
    end)
  end

  @doc """
  Extracts the 10-byte random blob from announce packet data.

  Layout: public_key (64 bytes) + name_hash (10 bytes) + random_blob (10 bytes) + ...
  """
  @spec extract_random_blob(map()) :: binary()
  def extract_random_blob(packet) do
    key_offset = div(Identity.keysize(), 8)
    name_offset = div(Identity.name_hash_length(), 8)
    skip = key_offset + name_offset

    <<_::binary-size(skip), random_blob::binary-size(10), _::binary>> = packet.data
    random_blob
  end

  @doc """
  Extracts the emission timestamp from an announce packet.
  """
  @spec announce_emitted(map()) :: non_neg_integer()
  def announce_emitted(packet) do
    packet
    |> extract_random_blob()
    |> timebase_from_random_blob()
  end

  # ── Rate Limiting ─────────────────────────────────────────────────

  @doc """
  Checks whether an announce should be rate-blocked based on the
  receiving interface's rate limiting settings.

  Returns `{rate_blocked, rate_entry}`.
  """
  @spec check_announce_rate(binary(), map()) :: {boolean(), map() | nil}
  def check_announce_rate(destination_hash, interface) do
    if interface[:announce_rate_target] == nil do
      {false, nil}
    else
      now = System.system_time(:second)

      case :ets.lookup(@announce_rate_table, destination_hash) do
        [] ->
          rate_entry = %{
            last: now,
            rate_violations: 0,
            blocked_until: 0,
            timestamps: [now]
          }

          :ets.insert(@announce_rate_table, {destination_hash, rate_entry})
          {false, rate_entry}

        [{^destination_hash, rate_entry}] ->
          timestamps =
            [now | rate_entry.timestamps]
            |> Enum.take(Transport.max_rate_timestamps())

          current_rate = now - rate_entry.last

          {rate_blocked, updated_entry} =
            if now > rate_entry.blocked_until do
              {violations, new_last} =
                if current_rate < interface.announce_rate_target do
                  {rate_entry.rate_violations + 1, rate_entry.last}
                else
                  {max(0, rate_entry.rate_violations - 1), now}
                end

              if violations > interface.announce_rate_grace do
                rate_target = interface.announce_rate_target
                rate_penalty = interface.announce_rate_penalty
                blocked_until = rate_entry.last + rate_target + rate_penalty

                updated = %{
                  rate_entry
                  | rate_violations: violations,
                    blocked_until: blocked_until,
                    timestamps: timestamps
                }

                {true, updated}
              else
                updated = %{
                  rate_entry
                  | rate_violations: violations,
                    last: new_last,
                    timestamps: timestamps
                }

                {false, updated}
              end
            else
              {true, %{rate_entry | timestamps: timestamps}}
            end

          :ets.insert(@announce_rate_table, {destination_hash, updated_entry})
          {rate_blocked, updated_entry}
      end
    end
  end

  # ── should_add Decision Logic ─────────────────────────────────────

  @doc """
  Determines whether an announce should be added to the path table.

  Checks hop count limits, local destination conflicts, path freshness,
  random blob deduplication, and path responsiveness.
  """
  @spec should_add_path?(binary(), map(), binary()) :: boolean()
  def should_add_path?(destination_hash, packet, random_blob) do
    is_local = Transport.destination_registered?(destination_hash)
    within_hop_limit = packet.hops < Transport.pathfinder_m() + 1

    if is_local or not within_hop_limit do
      false
    else
      announce_emitted = timebase_from_random_blob(random_blob)

      case Transport.get_path_entry(destination_hash) do
        nil ->
          # Unknown destination — always add
          true

        path_entry ->
          existing_blobs = path_entry.random_blobs || []

          if packet.hops <= path_entry.hops do
            # Equal or better hop count
            path_timebase = timebase_from_random_blobs(existing_blobs)

            random_blob not in existing_blobs and announce_emitted > path_timebase
          else
            # Worse hop count — only add under specific conditions
            now = System.system_time(:second)
            path_expires = path_entry.expires

            path_announce_emitted =
              Enum.reduce(existing_blobs, 0, fn blob, acc ->
                max(acc, timebase_from_random_blob(blob))
              end)

            cond do
              # Path expired
              now >= path_expires ->
                random_blob not in existing_blobs

              # More recent emission
              announce_emitted > path_announce_emitted ->
                random_blob not in existing_blobs

              # Same emission but path is unresponsive
              announce_emitted == path_announce_emitted ->
                Transport.path_is_unresponsive(destination_hash)

              true ->
                false
            end
          end
      end
    end
  end

  # ── Process Announce Queue ────────────────────────────────────────

  @doc """
  Processes the announce retransmission queue.

  Checks each announce entry and:
  - Removes completed entries (retry or local rebroadcast limits reached)
  - Retransmits announces whose timeout has been reached
  - Returns `{outgoing_packets, completed_hashes}`
  """
  @spec process_announce_queue() :: {[map()], [binary()]}
  def process_announce_queue do
    now = System.system_time(:second)

    entries = :ets.tab2list(@announce_table)

    {outgoing, completed} =
      Enum.reduce(entries, {[], []}, fn {destination_hash, entry}, {out_acc, comp_acc} ->
        cond do
          # Local rebroadcast limit reached (retries > 0)
          entry.retries > 0 and entry.local_rebroadcasts >= Transport.local_rebroadcasts_max() ->
            {out_acc, [destination_hash | comp_acc]}

          # Retry limit reached
          entry.retries > Transport.pathfinder_r() ->
            {out_acc, [destination_hash | comp_acc]}

          # Retransmit timeout reached — increment retries and queue retransmission
          now > entry.retransmit_timeout ->
            new_timeout = now + Transport.pathfinder_g() + trunc(Transport.pathfinder_rw())
            updated_entry = %{entry | retransmit_timeout: new_timeout, retries: entry.retries + 1}

            :ets.insert(@announce_table, {destination_hash, updated_entry})

            outgoing_packet = build_retransmit_packet(destination_hash, entry)
            {[outgoing_packet | out_acc], comp_acc}

          # Not yet time
          true ->
            {out_acc, comp_acc}
        end
      end)

    # Remove completed entries
    Enum.each(completed, fn hash ->
      :ets.delete(@announce_table, hash)
    end)

    {outgoing, completed}
  end

  # ── Rebroadcast Tracking ──────────────────────────────────────────

  @doc """
  Handles tracking of announce rebroadcasts from other nodes.

  When we hear an announce being rebroadcasted by another node, we
  track it to determine when we can stop our own retransmissions.

  - If packet.hops-1 == entry.hops: a peer at our hop count rebroadcasted
  - If packet.hops-1 == entry.hops+1: a next-hop node picked up the announce
  """
  @spec handle_rebroadcast_tracking(binary(), non_neg_integer(), AnnounceEntry.t()) :: :ok
  def handle_rebroadcast_tracking(destination_hash, packet_hops, entry) do
    # Peer at our hop count rebroadcasted
    if packet_hops - 1 == entry.hops do
      new_local_rebroadcasts = entry.local_rebroadcasts + 1
      updated = %{entry | local_rebroadcasts: new_local_rebroadcasts}
      :ets.insert(@announce_table, {destination_hash, updated})

      if entry.retries > 0 and new_local_rebroadcasts >= Transport.local_rebroadcasts_max() do
        :ets.delete(@announce_table, destination_hash)
      end
    end

    # Next hop has picked up the announce
    if packet_hops - 1 == entry.hops + 1 and entry.retries > 0 do
      now = System.system_time(:second)

      if now < entry.retransmit_timeout do
        :ets.delete(@announce_table, destination_hash)
      end
    end

    :ok
  end

  # ── Path Expiry Calculation ───────────────────────────────────────

  @doc """
  Calculates the path expiry time based on the receiving interface's mode.
  """
  @spec calculate_path_expiry(map()) :: non_neg_integer()
  def calculate_path_expiry(interface) do
    now = System.system_time(:second)

    case Map.get(interface, :mode) do
      :mode_access_point -> now + Transport.ap_path_time()
      :mode_roaming -> now + Transport.roaming_path_time()
      _ -> now + Transport.pathfinder_e()
    end
  end

  # ── Random Blob Management ───────────────────────────────────────

  @doc """
  Adds a random blob to a list, deduplicating and truncating to MAX_RANDOM_BLOBS.
  """
  @spec update_random_blobs([binary()], binary()) :: [binary()]
  def update_random_blobs(existing_blobs, new_blob) do
    if new_blob in existing_blobs do
      existing_blobs
    else
      updated = existing_blobs ++ [new_blob]
      Enum.take(updated, -Transport.max_random_blobs())
    end
  end

  # ── Private Helpers ───────────────────────────────────────────────

  defp build_retransmit_packet(destination_hash, entry) do
    announce_context =
      if entry.block_rebroadcasts do
        # PATH_RESPONSE
        0x0B
      else
        # NONE
        0x00
      end

    %{
      destination_hash: destination_hash,
      data: entry.packet.data,
      # ANNOUNCE
      packet_type: 0x01,
      context: announce_context,
      context_flag: Map.get(entry.packet, :context_flag, 0x00),
      # HEADER_2
      header_type: 0x01,
      # TRANSPORT
      transport_type: 0x01,
      hops: entry.hops,
      attached_interface: entry.attached_interface
    }
  end
end
