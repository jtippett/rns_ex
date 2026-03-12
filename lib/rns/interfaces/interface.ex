defmodule RNS.Interfaces.Interface do
  @moduledoc """
  Behaviour definition and shared logic for all RNS network interfaces.

  Defines the `RNS.Interfaces.Interface` behaviour that all interface
  implementations must adopt, and provides a `use` macro that injects
  shared constants, struct fields, and functions.

  Matches `python/RNS/Interfaces/Interface.py`.
  """

  # ── Interface mode constants ───────────────────────────────────────

  @mode_full 0x01
  @mode_point_to_point 0x02
  @mode_access_point 0x03
  @mode_roaming 0x04
  @mode_boundary 0x05
  @mode_gateway 0x06

  @discover_paths_for [@mode_access_point, @mode_gateway, @mode_roaming]

  # Announce frequency sample sizes
  @ia_freq_samples 6
  @oa_freq_samples 6

  # Maximum held announces
  @max_held_announces 256

  # Ingress control timing
  @ic_new_time 2 * 60 * 60
  @ic_burst_freq_new 3.5
  @ic_burst_freq 12
  @ic_burst_hold 1 * 60
  @ic_burst_penalty 5 * 60
  @ic_held_release_interval 30

  # Expose constants as functions
  def mode_full, do: @mode_full
  def mode_point_to_point, do: @mode_point_to_point
  def mode_access_point, do: @mode_access_point
  def mode_roaming, do: @mode_roaming
  def mode_boundary, do: @mode_boundary
  def mode_gateway, do: @mode_gateway
  def discover_paths_for, do: @discover_paths_for
  def ia_freq_samples, do: @ia_freq_samples
  def oa_freq_samples, do: @oa_freq_samples
  def max_held_announces, do: @max_held_announces
  def ic_new_time, do: @ic_new_time
  def ic_burst_freq_new, do: @ic_burst_freq_new
  def ic_burst_freq, do: @ic_burst_freq
  def ic_burst_hold, do: @ic_burst_hold
  def ic_burst_penalty, do: @ic_burst_penalty
  def ic_held_release_interval, do: @ic_held_release_interval

  # ── Behaviour callbacks ────────────────────────────────────────────

  @doc "Send data out of this interface."
  @callback process_outgoing(state :: map(), data :: binary()) :: {:ok, map()} | {:error, term()}

  @doc "Process incoming data from this interface."
  @callback process_incoming(state :: map(), data :: binary()) :: {:ok, map()} | {:error, term()}

  @doc "Detach and clean up this interface."
  @callback detach(state :: map()) :: :ok

  # ── Default struct fields ──────────────────────────────────────────

  @doc """
  Returns the default struct fields for an interface.

  These fields match the Python `Interface.__init__` defaults and should
  be merged into any concrete interface's defstruct.
  """
  @spec default_fields() :: keyword()
  def default_fields do
    [
      # Direction flags
      in: false,
      out: false,
      fwd: false,
      rpt: false,

      # Identity
      name: nil,
      mode: @mode_full,

      # Stats
      rxb: 0,
      txb: 0,
      created: nil,
      online: false,
      detached: false,
      bitrate: 62_500,
      hw_mtu: nil,

      # MTU config
      autoconfigure_mtu: false,
      fixed_mtu: false,

      # Discovery
      supports_discovery: false,
      discoverable: false,
      last_discovery_announce: 0,
      bootstrap_only: false,

      # Hierarchy
      parent_interface: nil,
      spawned_interfaces: nil,
      tunnel_id: nil,

      # Ingress control
      ingress_control: true,
      ic_max_held_announces: @max_held_announces,
      ic_burst_hold: @ic_burst_hold,
      ic_burst_active: false,
      ic_burst_activated: 0,
      ic_held_release: 0,
      ic_burst_freq_new: @ic_burst_freq_new,
      ic_burst_freq: @ic_burst_freq,
      ic_new_time: @ic_new_time,
      ic_burst_penalty: @ic_burst_penalty,
      ic_held_release_interval: @ic_held_release_interval,
      held_announces: %{},

      # Announce frequency tracking (bounded lists acting as deques)
      ia_freq_deque: [],
      oa_freq_deque: [],

      # Announce queue
      announce_queue: [],
      announce_cap: nil,
      announce_allowed_at: 0,
      announce_rate_target: nil,

      # IFAC (Interface Access Code)
      ifac_identity: nil,
      ifac_size: 0,
      ifac_key: nil,

      # Interface hash (cached)
      hash: nil
    ]
  end

  # ── Use macro ──────────────────────────────────────────────────────

  @doc """
  Injects shared interface logic into a concrete interface module.

  Usage:

      defmodule RNS.Interfaces.UDPInterface do
        use RNS.Interfaces.Interface

        defstruct RNS.Interfaces.Interface.default_fields() ++ [
          bind_ip: nil,
          bind_port: nil,
          # ...
        ]
      end

  This injects the `@behaviour RNS.Interfaces.Interface` declaration
  and makes all shared function helpers available.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour RNS.Interfaces.Interface
      import RNS.Interfaces.Interface, only: [default_fields: 0]
    end
  end

  # ── Shared functions ───────────────────────────────────────────────

  @doc """
  Computes the hash of an interface based on its string representation.

  Returns the full SHA-256 hash of the interface's string name.
  """
  @spec get_hash(map()) :: binary()
  def get_hash(%{name: name}) when is_binary(name) do
    RNS.Identity.full_hash(name)
  end

  def get_hash(%{name: nil}), do: RNS.Identity.full_hash("")
  def get_hash(iface), do: RNS.Identity.full_hash(to_string(iface))

  @doc """
  Returns the age of the interface in seconds since creation.
  """
  @spec age(map()) :: float()
  def age(%{created: created}) when is_number(created) do
    System.system_time(:second) - created
  end

  def age(_), do: 0.0

  @doc """
  Determines whether the interface should activate ingress limiting.

  Tracks burst detection using announce frequency. When a burst is
  detected, ingress limiting activates for `ic_burst_hold` seconds,
  followed by a `ic_burst_penalty` cooldown period.

  Returns `{should_limit, updated_interface}`.
  """
  @spec should_ingress_limit(map()) :: {boolean(), map()}
  def should_ingress_limit(%{ingress_control: false} = iface), do: {false, iface}

  def should_ingress_limit(%{ingress_control: true} = iface) do
    now = System.system_time(:second)

    freq_threshold =
      if age(iface) < iface.ic_new_time,
        do: iface.ic_burst_freq_new,
        else: iface.ic_burst_freq

    ia_freq = incoming_announce_frequency(iface)

    if iface.ic_burst_active do
      # Currently in burst mode — check if we can deactivate
      if ia_freq < freq_threshold and now > iface.ic_burst_activated + iface.ic_burst_hold do
        updated =
          iface
          |> Map.put(:ic_burst_active, false)
          |> Map.put(:ic_held_release, now + iface.ic_burst_penalty)

        {true, updated}
      else
        {true, iface}
      end
    else
      # Not in burst mode — check if we should activate
      if ia_freq > freq_threshold do
        updated =
          iface
          |> Map.put(:ic_burst_active, true)
          |> Map.put(:ic_burst_activated, now)

        {true, updated}
      else
        {false, iface}
      end
    end
  end

  @doc """
  Optimizes HW_MTU based on the interface's bitrate.

  Only applies when `autoconfigure_mtu` is true.
  """
  @spec optimise_mtu(map()) :: map()
  def optimise_mtu(%{autoconfigure_mtu: false} = iface), do: iface

  def optimise_mtu(%{autoconfigure_mtu: true, bitrate: bitrate} = iface) do
    hw_mtu =
      cond do
        bitrate >= 1_000_000_000 -> 524_288
        bitrate > 750_000_000 -> 262_144
        bitrate > 400_000_000 -> 131_072
        bitrate > 200_000_000 -> 65_536
        bitrate > 100_000_000 -> 32_768
        bitrate > 10_000_000 -> 16_384
        bitrate > 5_000_000 -> 8_192
        bitrate > 2_000_000 -> 4_096
        bitrate > 1_000_000 -> 2_048
        bitrate > 62_500 -> 1_024
        true -> nil
      end

    Map.put(iface, :hw_mtu, hw_mtu)
  end

  @doc """
  Holds an announce packet for later processing during ingress limiting.

  Updates existing entry for same destination, or adds new entry if
  under the max held announces limit.
  """
  @spec hold_announce(map(), map()) :: map()
  def hold_announce(iface, announce_packet) do
    dest_hash = announce_packet.destination_hash
    held = iface.held_announces

    new_held =
      cond do
        # Already tracking this destination — update
        Map.has_key?(held, dest_hash) ->
          Map.put(held, dest_hash, announce_packet)

        # Under limit — add
        map_size(held) < iface.ic_max_held_announces ->
          Map.put(held, dest_hash, announce_packet)

        # At limit — ignore
        true ->
          held
      end

    Map.put(iface, :held_announces, new_held)
  end

  @doc """
  Processes held announces, releasing one at a time when ingress
  limiting has subsided and the penalty period has elapsed.

  Selects the announce with the lowest hop count and releases it
  for processing via a spawned task.

  Returns `{released_packet_or_nil, updated_interface}`.
  """
  @spec process_held_announces(map()) :: {map() | nil, map()}
  def process_held_announces(iface) do
    try do
      {should_limit, iface} = should_ingress_limit(iface)
      now = System.system_time(:second)

      if not should_limit and map_size(iface.held_announces) > 0 and now > iface.ic_held_release do
        freq_threshold =
          if age(iface) < iface.ic_new_time,
            do: iface.ic_burst_freq_new,
            else: iface.ic_burst_freq

        ia_freq = incoming_announce_frequency(iface)

        if ia_freq < freq_threshold do
          # Select announce with lowest hop count
          {selected_hash, selected_packet} =
            iface.held_announces
            |> Enum.min_by(fn {_hash, packet} -> Map.get(packet, :hops, 128) end)

          # Update release timing and remove from held
          updated =
            iface
            |> Map.put(:ic_held_release, now + iface.ic_held_release_interval)
            |> Map.update!(:held_announces, &Map.delete(&1, selected_hash))

          {selected_packet, updated}
        else
          {nil, iface}
        end
      else
        {nil, iface}
      end
    rescue
      e ->
        require Logger

        Logger.error(
          "Error processing held announces for #{inspect(iface.name)}: #{Exception.message(e)}"
        )

        {nil, iface}
    end
  end

  @doc """
  Records that an announce was received on this interface.

  Appends current timestamp to the incoming announce frequency deque.
  If the interface has a parent, propagates the notification upward.
  """
  @spec received_announce(map()) :: map()
  def received_announce(iface) do
    now = System.system_time(:second)

    deque =
      (iface.ia_freq_deque ++ [now])
      |> Enum.take(-@ia_freq_samples)

    Map.put(iface, :ia_freq_deque, deque)
  end

  @doc """
  Records that an announce was sent on this interface.

  Appends current timestamp to the outgoing announce frequency deque.
  """
  @spec sent_announce(map()) :: map()
  def sent_announce(iface) do
    now = System.system_time(:second)

    deque =
      (iface.oa_freq_deque ++ [now])
      |> Enum.take(-@oa_freq_samples)

    Map.put(iface, :oa_freq_deque, deque)
  end

  @doc """
  Calculates the incoming announce frequency in announces per second.

  Uses the timestamps in the ia_freq_deque to compute the average
  rate, including time elapsed since the last recorded announce.
  Returns 0 if fewer than 2 samples exist.
  """
  @spec incoming_announce_frequency(map()) :: float()
  def incoming_announce_frequency(%{ia_freq_deque: deque}) when length(deque) <= 1, do: 0.0

  def incoming_announce_frequency(%{ia_freq_deque: deque}) do
    calculate_frequency(deque)
  end

  @doc """
  Calculates the outgoing announce frequency in announces per second.
  """
  @spec outgoing_announce_frequency(map()) :: float()
  def outgoing_announce_frequency(%{oa_freq_deque: deque}) when length(deque) <= 1, do: 0.0

  def outgoing_announce_frequency(%{oa_freq_deque: deque}) do
    calculate_frequency(deque)
  end

  defp calculate_frequency(deque) do
    dq_len = length(deque)
    now = System.system_time(:second)

    # Sum deltas between consecutive timestamps
    delta_sum =
      deque
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(0.0, fn [a, b], acc -> acc + (b - a) end)

    # Add time since last sample
    last = List.last(deque)
    delta_sum = delta_sum + (now - last)

    if delta_sum == 0 do
      0.0
    else
      1.0 / (delta_sum / dq_len)
    end
  end

  # Default announce cap (matching Python RNS.Reticulum.ANNOUNCE_CAP)
  @default_announce_cap 2
  # How long a queued announce lives before being discarded (seconds)
  @queued_announce_life 60 * 60

  @doc """
  Processes the announce queue for this interface.

  Removes stale entries (older than QUEUED_ANNOUNCE_LIFE), selects the
  entry with the lowest hop count (and earliest timestamp among ties),
  transmits it, and schedules the next queue processing based on the
  announce cap rate limit.

  Returns `{selected_entry_or_nil, wait_time_ms, updated_interface}`.
  """
  @spec process_announce_queue(map()) :: {map() | nil, non_neg_integer(), map()}
  def process_announce_queue(iface) do
    # Default announce cap if not set (matching Python: RNS.Reticulum.ANNOUNCE_CAP)
    announce_cap = iface.announce_cap || @default_announce_cap

    try do
      queue = iface.announce_queue || []
      now = System.system_time(:second)

      # Remove stale entries
      queue =
        Enum.reject(queue, fn entry ->
          now > entry.time + @queued_announce_life
        end)

      if queue == [] do
        {nil, 0, Map.put(iface, :announce_queue, [])}
      else
        # Find minimum hop count
        min_hops = queue |> Enum.map(& &1.hops) |> Enum.min()

        # Filter to entries with min hops, sort by time
        entries =
          queue
          |> Enum.filter(&(&1.hops == min_hops))
          |> Enum.sort_by(& &1.time)

        selected = hd(entries)

        # Calculate wait time based on bitrate and announce cap
        tx_time = byte_size(selected.raw) * 8 / iface.bitrate
        wait_time = tx_time / announce_cap
        announce_allowed_at = now + wait_time

        # Remove selected from queue
        remaining = List.delete(queue, selected)

        updated =
          iface
          |> Map.put(:announce_queue, remaining)
          |> Map.put(:announce_allowed_at, announce_allowed_at)

        wait_time_ms = trunc(wait_time * 1000)
        {selected, wait_time_ms, updated}
      end
    rescue
      e ->
        require Logger

        Logger.error(
          "Error processing announce queue on #{inspect(iface.name)}: #{Exception.message(e)}"
        )

        {nil, 0, Map.put(iface, :announce_queue, [])}
    end
  end

  def default_announce_cap, do: @default_announce_cap
  def queued_announce_life, do: @queued_announce_life

  # ── HDLC framing helpers ───────────────────────────────────────────

  defmodule HDLC do
    @moduledoc """
    HDLC (High-Level Data Link Control) framing helpers.

    Used by TCP, serial, and other stream-oriented interfaces for
    packet framing. Matches `HDLC` class in `python/RNS/Interfaces/TCPInterface.py`.
    """

    @flag 0x7E
    @esc 0x7D
    @esc_mask 0x20

    def flag, do: @flag
    def esc, do: @esc
    def esc_mask, do: @esc_mask

    @doc """
    Escapes HDLC special bytes in data.

    Replaces ESC bytes with ESC + (ESC XOR ESC_MASK)
    and FLAG bytes with ESC + (FLAG XOR ESC_MASK).
    """
    @spec escape(binary()) :: binary()
    def escape(data) do
      data
      |> :binary.bin_to_list()
      |> Enum.flat_map(fn
        byte when byte == @esc -> [@esc, Bitwise.bxor(@esc, @esc_mask)]
        byte when byte == @flag -> [@esc, Bitwise.bxor(@flag, @esc_mask)]
        byte -> [byte]
      end)
      |> :binary.list_to_bin()
    end

    @doc """
    Unescapes HDLC escape sequences in data.

    Reverses the escape encoding.
    """
    @spec unescape(binary()) :: binary()
    def unescape(data) do
      data
      |> :binary.bin_to_list()
      |> unescape_list([])
      |> Enum.reverse()
      |> :binary.list_to_bin()
    end

    defp unescape_list([], acc), do: acc

    defp unescape_list([@esc, escaped | rest], acc) do
      unescape_list(rest, [Bitwise.bxor(escaped, @esc_mask) | acc])
    end

    defp unescape_list([byte | rest], acc) do
      unescape_list(rest, [byte | acc])
    end

    @doc """
    Frames data with HDLC FLAG delimiters and escape encoding.

    Returns `<<FLAG>> <> escaped_data <> <<FLAG>>`.
    """
    @spec frame(binary()) :: binary()
    def frame(data) do
      <<@flag>> <> escape(data) <> <<@flag>>
    end

    @doc """
    Extracts complete frames from a buffer.

    Returns `{frames, remaining_buffer}` where `frames` is a list
    of unescaped frame payloads and `remaining_buffer` is any
    incomplete data left over.
    """
    @spec deframe(binary()) :: {[binary()], binary()}
    def deframe(buffer) do
      deframe_acc(buffer, [])
    end

    defp deframe_acc(buffer, frames) do
      case find_frame(buffer) do
        {:ok, frame_data, rest} ->
          deframe_acc(rest, [unescape(frame_data) | frames])

        :incomplete ->
          {Enum.reverse(frames), buffer}
      end
    end

    defp find_frame(buffer) do
      case :binary.match(buffer, <<@flag>>) do
        :nomatch ->
          :incomplete

        {start, 1} ->
          rest = binary_part(buffer, start + 1, byte_size(buffer) - start - 1)

          case :binary.match(rest, <<@flag>>) do
            :nomatch ->
              :incomplete

            {end_pos, 1} ->
              frame_data = binary_part(rest, 0, end_pos)
              remaining = binary_part(rest, end_pos + 1, byte_size(rest) - end_pos - 1)

              if byte_size(frame_data) > 0 do
                {:ok, frame_data, remaining}
              else
                # Empty frame (consecutive flags), skip and continue
                deframe_skip(remaining)
              end
          end
      end
    end

    defp deframe_skip(buffer) do
      case :binary.match(buffer, <<@flag>>) do
        :nomatch -> :incomplete
        {start, 1} -> find_frame(binary_part(buffer, start, byte_size(buffer) - start))
      end
    end
  end

  # ── KISS framing helpers ───────────────────────────────────────────

  defmodule KISS do
    @moduledoc """
    KISS (Keep It Simple, Stupid) framing helpers.

    Used by TCP interfaces in KISS mode and by serial/TNC interfaces.
    Matches `KISS` class in `python/RNS/Interfaces/TCPInterface.py`.
    """

    @fend 0xC0
    @fesc 0xDB
    @tfend 0xDC
    @tfesc 0xDD
    @cmd_data 0x00
    @cmd_unknown 0xFE

    def fend, do: @fend
    def fesc, do: @fesc
    def tfend, do: @tfend
    def tfesc, do: @tfesc
    def cmd_data, do: @cmd_data
    def cmd_unknown, do: @cmd_unknown

    @doc """
    Escapes KISS special bytes in data.

    Replaces FESC (0xDB) with FESC+TFESC and FEND (0xC0) with FESC+TFEND.
    """
    @spec escape(binary()) :: binary()
    def escape(data) do
      data
      |> :binary.bin_to_list()
      |> Enum.flat_map(fn
        byte when byte == @fesc -> [@fesc, @tfesc]
        byte when byte == @fend -> [@fesc, @tfend]
        byte -> [byte]
      end)
      |> :binary.list_to_bin()
    end

    @doc """
    Unescapes KISS escape sequences in data.
    """
    @spec unescape(binary()) :: binary()
    def unescape(data) do
      data
      |> :binary.bin_to_list()
      |> unescape_list([])
      |> Enum.reverse()
      |> :binary.list_to_bin()
    end

    defp unescape_list([], acc), do: acc

    defp unescape_list([@fesc, @tfend | rest], acc) do
      unescape_list(rest, [@fend | acc])
    end

    defp unescape_list([@fesc, @tfesc | rest], acc) do
      unescape_list(rest, [@fesc | acc])
    end

    defp unescape_list([byte | rest], acc) do
      unescape_list(rest, [byte | acc])
    end

    @doc """
    Frames data with KISS FEND delimiters and CMD_DATA command byte.

    Returns `<<FEND, CMD_DATA>> <> escaped_data <> <<FEND>>`.
    """
    @spec frame(binary()) :: binary()
    def frame(data) do
      <<@fend, @cmd_data>> <> escape(data) <> <<@fend>>
    end

    @doc """
    Extracts complete KISS frames from a buffer.

    Returns `{frames, remaining_buffer}` where `frames` is a list
    of `{command, data}` tuples.
    """
    @spec deframe(binary()) :: {[{byte(), binary()}], binary()}
    def deframe(buffer) do
      deframe_acc(buffer, [], false, @cmd_unknown, <<>>)
    end

    defp deframe_acc(<<>>, frames, _in_frame, _cmd, _current) do
      {Enum.reverse(frames), <<>>}
    end

    defp deframe_acc(<<@fend, rest::binary>>, frames, true, cmd, current) when byte_size(current) > 0 do
      # End of frame with data
      frame_data = unescape(current)
      deframe_acc(rest, [{cmd, frame_data} | frames], false, @cmd_unknown, <<>>)
    end

    defp deframe_acc(<<@fend, rest::binary>>, frames, _in_frame, _cmd, _current) do
      # Start of new frame (or empty frame end)
      deframe_acc(rest, frames, true, @cmd_unknown, <<>>)
    end

    defp deframe_acc(<<byte, rest::binary>>, frames, true, @cmd_unknown, <<>>) do
      # First byte after FEND is the command
      deframe_acc(rest, frames, true, byte, <<>>)
    end

    defp deframe_acc(<<byte, rest::binary>>, frames, true, cmd, current) do
      deframe_acc(rest, frames, true, cmd, current <> <<byte>>)
    end

    defp deframe_acc(<<_byte, rest::binary>>, frames, false, cmd, current) do
      # Data outside frame, ignore
      deframe_acc(rest, frames, false, cmd, current)
    end
  end

  # ── Announce queue entry ───────────────────────────────────────────

  defmodule AnnounceQueueEntry do
    @moduledoc """
    An entry in an interface's announce queue.
    """
    defstruct [:raw, :hops, :time]

    @type t :: %__MODULE__{
            raw: binary(),
            hops: non_neg_integer(),
            time: integer()
          }
  end
end
