defmodule RNS.Channel.ChannelException do
  @moduledoc """
  An exception thrown by Channel, with a type code.

  Matches `python/RNS/Channel.py` ChannelException class.
  """
  defexception [:type, :message]
end

defmodule RNS.Channel.MessageBase do
  @moduledoc """
  Base behaviour for any messages sent or received on a Channel.

  Implementing modules must define `msgtype/0`, `new/0`, `pack/1`, and `unpack/2`.
  MSGTYPE must be unique within all classes sent over a channel.
  MSGTYPE values >= 0xF000 are reserved for system use.

  Matches `python/RNS/Channel.py` MessageBase class.
  """

  @doc "Returns the unique message type identifier"
  @callback msgtype() :: non_neg_integer()

  @doc "Create a new default message instance (no arguments)"
  @callback new() :: struct()

  @doc "Pack the message into its binary representation"
  @callback pack(message :: struct()) :: binary()

  @doc "Populate a message from binary representation"
  @callback unpack(message :: struct(), raw :: binary()) :: struct()
end

defprotocol RNS.Channel.Outlet do
  @moduledoc """
  Abstract transport layer interface used by Channel.

  Matches `python/RNS/Channel.py` ChannelOutletBase class.
  """

  @doc "Send raw bytes over the outlet, returns a packet reference"
  @spec send_raw(t(), binary()) :: any()
  def send_raw(outlet, raw)

  @doc "Resend a previously sent packet"
  @spec resend(t(), any()) :: any()
  def resend(outlet, packet)

  @doc "Get the Maximum Data Unit"
  @spec mdu(t()) :: non_neg_integer()
  def mdu(outlet)

  @doc "Get the current round-trip time in seconds"
  @spec rtt(t()) :: float()
  def rtt(outlet)

  @doc "Check if the outlet is usable for sending"
  @spec is_usable(t()) :: boolean()
  def is_usable(outlet)

  @doc "Get the delivery state of a packet"
  @spec get_packet_state(t(), any()) :: non_neg_integer()
  def get_packet_state(outlet, packet)

  @doc "Handle outlet timeout (e.g., tear down link)"
  @spec timed_out(t()) :: any()
  def timed_out(outlet)

  @doc "Set a timeout callback on a packet"
  @spec set_packet_timeout_callback(t(), any(), function() | nil, float() | nil) :: any()
  def set_packet_timeout_callback(outlet, packet, callback, timeout)

  @doc "Set a delivery callback on a packet"
  @spec set_packet_delivered_callback(t(), any(), function() | nil) :: any()
  def set_packet_delivered_callback(outlet, packet, callback)

  @doc "Get a unique identifier for a packet"
  @spec get_packet_id(t(), any()) :: any()
  def get_packet_id(outlet, packet)
end

defmodule RNS.Channel.Envelope do
  @moduledoc """
  Internal wrapper used to transport messages over a channel and
  track state within the channel framework.

  Matches `python/RNS/Channel.py` Envelope class.
  """

  defstruct [
    :message,
    :raw,
    :packet,
    :sequence,
    :outlet,
    ts: 0.0,
    id: nil,
    tries: 0,
    unpacked: false,
    packed: false,
    tracked: false
  ]

  @type t :: %__MODULE__{
          message: struct() | nil,
          raw: binary() | nil,
          packet: any(),
          sequence: non_neg_integer() | nil,
          outlet: any(),
          ts: float(),
          id: reference() | nil,
          tries: non_neg_integer(),
          unpacked: boolean(),
          packed: boolean(),
          tracked: boolean()
        }

  @doc "Create a new envelope"
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      ts: System.system_time(:millisecond) / 1000.0,
      id: make_ref(),
      message: Keyword.get(opts, :message),
      raw: Keyword.get(opts, :raw),
      sequence: Keyword.get(opts, :sequence),
      outlet: Keyword.get(opts, :outlet)
    }
  end

  @doc "Pack the envelope's message into raw binary format (>HHH header + data)"
  @spec pack(t()) :: t()
  def pack(%__MODULE__{message: message} = envelope) do
    mod = message.__struct__
    msgtype = mod.msgtype()

    if msgtype == nil do
      raise RNS.Channel.ChannelException,
        type: 0,
        message: "#{inspect(mod)} lacks MSGTYPE"
    end

    data = mod.pack(message)

    raw =
      <<msgtype::unsigned-big-16, envelope.sequence::unsigned-big-16,
        byte_size(data)::unsigned-big-16>> <> data

    %{envelope | raw: raw, packed: true}
  end

  @doc "Unpack raw bytes into a message using the message factory map"
  @spec unpack(t(), %{non_neg_integer() => module()}) :: t()
  def unpack(%__MODULE__{raw: raw} = envelope, message_factories) do
    <<msgtype::unsigned-big-16, sequence::unsigned-big-16, _length::unsigned-big-16,
      data::binary>> = raw

    case Map.get(message_factories, msgtype) do
      nil ->
        raise RNS.Channel.ChannelException,
          type: 2,
          message:
            "Unable to find constructor for Channel MSGTYPE 0x#{Integer.to_string(msgtype, 16)}"

      mod ->
        message = mod.new()
        message = mod.unpack(message, data)
        %{envelope | sequence: sequence, message: message, unpacked: true}
    end
  end
end

defmodule RNS.Channel do
  @moduledoc """
  Provides reliable delivery of messages over a link.

  `Channel` differs from `Request` and `Resource` in important ways:

  - **Continuous**: Messages can be sent or received as long as the `Link` is open.
  - **Bi-directional**: Messages can be sent in either direction on the `Link`.
  - **Size-constrained**: Messages must be encoded into a single packet.

  `Channel` provides reliable delivery (automatic retries) as well as a
  structure for exchanging several types of messages over a `Link`.

  `Channel` is not instantiated directly, but rather obtained from a `Link`
  with `Link.channel/1`.

  Matches `python/RNS/Channel.py`.
  """

  alias RNS.Channel.{Envelope, Outlet, ChannelException}

  use RNS.Constants.Channel

  defstruct [
    :outlet,
    :owner,
    tx_ring: [],
    rx_ring: [],
    message_callbacks: [],
    next_sequence: 0,
    next_rx_sequence: 0,
    message_factories: %{},
    max_tries: @max_tries,
    window: @window,
    window_max: @window_max_slow,
    window_min: @window_min,
    window_flexibility: @window_flexibility,
    fast_rate_rounds: 0,
    medium_rate_rounds: 0
  ]

  @type t :: %__MODULE__{
          outlet: any(),
          owner: pid() | nil,
          tx_ring: [Envelope.t()],
          rx_ring: [Envelope.t()],
          message_callbacks: [function()],
          next_sequence: non_neg_integer(),
          next_rx_sequence: non_neg_integer(),
          message_factories: %{non_neg_integer() => module()},
          max_tries: pos_integer(),
          window: pos_integer(),
          window_max: pos_integer(),
          window_min: pos_integer(),
          window_flexibility: pos_integer(),
          fast_rate_rounds: non_neg_integer(),
          medium_rate_rounds: non_neg_integer()
        }

  # ── Constant accessors ──────────────────────────────────────

  def smt_stream_data, do: @smt_stream_data
  def window_const, do: @window
  def window_min_const, do: @window_min
  def window_min_limit_slow, do: @window_min_limit_slow
  def window_min_limit_medium, do: @window_min_limit_medium
  def window_min_limit_fast, do: @window_min_limit_fast
  def window_max_slow, do: @window_max_slow
  def window_max_medium, do: @window_max_medium
  def window_max_fast, do: @window_max_fast
  def window_max_const, do: @window_max
  def window_flexibility_const, do: @window_flexibility
  def fast_rate_threshold, do: @fast_rate_threshold
  def rtt_fast, do: @rtt_fast
  def rtt_medium, do: @rtt_medium
  def rtt_slow, do: @rtt_slow
  def seq_max, do: @seq_max
  def seq_modulus, do: @seq_modulus
  def msgstate_new, do: @msgstate_new
  def msgstate_sent, do: @msgstate_sent
  def msgstate_delivered, do: @msgstate_delivered
  def msgstate_failed, do: @msgstate_failed
  def me_no_msg_type, do: @me_no_msg_type
  def me_invalid_msg_type, do: @me_invalid_msg_type
  def me_not_registered, do: @me_not_registered
  def me_link_not_ready, do: @me_link_not_ready
  def me_already_sent, do: @me_already_sent
  def me_too_big, do: @me_too_big
  def envelope_header_size, do: @envelope_header_size

  # ── Construction ─────────────────────────────────────────────

  @doc """
  Creates a new Channel with the given outlet.

  The outlet must implement the `RNS.Channel.Outlet` protocol.
  If the outlet's RTT exceeds `RTT_SLOW` (#{@rtt_slow}s), the window
  is set to 1 for very slow links.

  ## Options

    * `:owner` - PID of the owning process for callback routing (default: `self()`)
  """
  @spec new(any(), keyword()) :: t()
  def new(outlet, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    rtt = Outlet.rtt(outlet)
    base = %__MODULE__{outlet: outlet, owner: owner}

    if rtt > @rtt_slow do
      %{base | window: 1, window_max: 1, window_min: 1, window_flexibility: 1}
    else
      base
    end
  end

  # ── Message type registration ────────────────────────────────

  @doc """
  Register a message class for reception over a Channel.

  Message modules must implement the `RNS.Channel.MessageBase` behaviour.
  """
  @spec register_message_type(t(), module()) :: t()
  def register_message_type(%__MODULE__{} = channel, message_module) do
    do_register_message_type(channel, message_module, false)
  end

  @doc false
  @spec register_system_message_type(t(), module()) :: t()
  def register_system_message_type(%__MODULE__{} = channel, message_module) do
    do_register_message_type(channel, message_module, true)
  end

  defp do_register_message_type(%__MODULE__{} = channel, message_module, is_system_type) do
    msgtype = message_module.msgtype()

    if msgtype == nil do
      raise ChannelException,
        type: @me_invalid_msg_type,
        message: "#{inspect(message_module)} has invalid MSGTYPE class attribute."
    end

    if msgtype >= 0xF000 and not is_system_type do
      raise ChannelException,
        type: @me_invalid_msg_type,
        message: "#{inspect(message_module)} has system-reserved message type."
    end

    try do
      message_module.new()
    rescue
      e ->
        raise ChannelException,
          type: @me_invalid_msg_type,
          message:
            "#{inspect(message_module)} raised an exception when constructed with no arguments: #{inspect(e)}"
    end

    %{channel | message_factories: Map.put(channel.message_factories, msgtype, message_module)}
  end

  # ── Message handlers ─────────────────────────────────────────

  @doc """
  Add a handler for incoming messages.

  Handlers are processed in order. If any handler returns true,
  processing of the message stops; handlers after it will not be called.
  """
  @spec add_message_handler(t(), function()) :: t()
  def add_message_handler(%__MODULE__{} = channel, callback) do
    if callback in channel.message_callbacks do
      channel
    else
      %{channel | message_callbacks: channel.message_callbacks ++ [callback]}
    end
  end

  @doc """
  Remove a handler added with `add_message_handler/2`.
  """
  @spec remove_message_handler(t(), function()) :: t()
  def remove_message_handler(%__MODULE__{} = channel, callback) do
    %{channel | message_callbacks: List.delete(channel.message_callbacks, callback)}
  end

  # ── Shutdown ─────────────────────────────────────────────────

  @doc """
  Shutdown the channel, clearing callbacks and rings.
  """
  @spec shutdown(t()) :: t()
  def shutdown(%__MODULE__{} = channel) do
    channel = clear_rings(channel)
    %{channel | message_callbacks: []}
  end

  defp clear_rings(%__MODULE__{} = channel) do
    Enum.each(channel.tx_ring, fn envelope ->
      if envelope.packet != nil do
        Outlet.set_packet_timeout_callback(channel.outlet, envelope.packet, nil, nil)
        Outlet.set_packet_delivered_callback(channel.outlet, envelope.packet, nil)
      end
    end)

    %{channel | tx_ring: [], rx_ring: []}
  end

  # ── Readiness ────────────────────────────────────────────────

  @doc """
  Check if Channel is ready to send.
  """
  @spec is_ready_to_send(t()) :: boolean()
  def is_ready_to_send(%__MODULE__{} = channel) do
    outlet = channel.outlet

    if not Outlet.is_usable(outlet) do
      false
    else
      outstanding =
        Enum.count(channel.tx_ring, fn envelope ->
          envelope.outlet == outlet and
            (envelope.packet == nil or
               Outlet.get_packet_state(outlet, envelope.packet) != @msgstate_delivered)
        end)

      outstanding < channel.window
    end
  end

  # ── MDU ──────────────────────────────────────────────────────

  @doc """
  Maximum Data Unit: the number of bytes available for a message
  to consume in a single send. Adjusted from the outlet MDU to
  accommodate the envelope header (6 bytes).
  """
  @spec mdu(t()) :: non_neg_integer()
  def mdu(%__MODULE__{} = channel) do
    raw_mdu = Outlet.mdu(channel.outlet) - @envelope_header_size
    min(raw_mdu, 0xFFFF)
  end

  # ── Send ─────────────────────────────────────────────────────

  @doc """
  Send a message over the channel.

  Returns `{:ok, channel, envelope}` on success.
  Raises `RNS.Channel.ChannelException` if the channel is not ready
  or the message is too large.
  """
  @spec send(t(), struct()) :: {:ok, t(), Envelope.t()}
  def send(%__MODULE__{} = channel, message) do
    unless is_ready_to_send(channel) do
      raise ChannelException,
        type: @me_link_not_ready,
        message: "Link is not ready"
    end

    envelope =
      Envelope.new(
        outlet: channel.outlet,
        message: message,
        sequence: channel.next_sequence
      )

    channel = %{channel | next_sequence: rem(channel.next_sequence + 1, @seq_modulus)}
    envelope = Envelope.pack(envelope)

    outlet_mdu = Outlet.mdu(channel.outlet)

    if byte_size(envelope.raw) > outlet_mdu do
      raise ChannelException,
        type: @me_too_big,
        message: "Packed message too big for packet: #{byte_size(envelope.raw)} > #{outlet_mdu}"
    end

    packet = Outlet.send_raw(channel.outlet, envelope.raw)
    envelope = %{envelope | packet: packet, tries: envelope.tries + 1}

    # Set delivery callback
    owner = channel.owner

    Outlet.set_packet_delivered_callback(
      channel.outlet,
      packet,
      fn pkt -> Kernel.send(owner, {:channel_delivered, pkt}) end
    )

    # Set timeout callback
    timeout = packet_timeout_time(channel, envelope.tries)

    Outlet.set_packet_timeout_callback(
      channel.outlet,
      packet,
      fn pkt -> Kernel.send(owner, {:channel_timeout, pkt}) end,
      timeout
    )

    # Insert into tx_ring
    {channel, _is_new} = emplace_envelope(channel, envelope, :tx)
    channel = update_packet_timeouts(channel)

    {:ok, channel, envelope}
  end

  # ── Receive ──────────────────────────────────────────────────

  @doc """
  Process incoming raw data on the channel.

  Unpacks the data, validates the sequence, and delivers
  contiguous messages to registered handlers.
  """
  @spec receive_raw(t(), binary()) :: t()
  def receive_raw(%__MODULE__{} = channel, raw) do
    try do
      envelope = Envelope.new(outlet: channel.outlet, raw: raw)
      envelope = Envelope.unpack(envelope, channel.message_factories)

      if invalid_rx_sequence?(channel, envelope.sequence) do
        RNS.Log.log(
          "Invalid packet sequence (#{envelope.sequence}) received on channel",
          :extreme
        )

        channel
      else
        {channel, is_new} = emplace_envelope(channel, envelope, :rx)

        if not is_new do
          RNS.Log.log("Duplicate message received on channel", :extreme)
          channel
        else
          deliver_contiguous(channel)
        end
      end
    rescue
      e ->
        RNS.Log.log(
          "An error ocurred while receiving data on channel. The contained exception was: #{inspect(e)}",
          :error
        )

        channel
    end
  end

  defp invalid_rx_sequence?(%__MODULE__{} = channel, sequence) do
    if sequence < channel.next_rx_sequence do
      window_overflow = rem(channel.next_rx_sequence + @window_max, @seq_modulus)

      if window_overflow < channel.next_rx_sequence do
        # Wrap-around: reject only if sequence is beyond the overflow point
        sequence > window_overflow
      else
        true
      end
    else
      false
    end
  end

  defp deliver_contiguous(%__MODULE__{} = channel) do
    {contiguous, remaining_ring, new_next_rx} =
      collect_contiguous(channel.rx_ring, channel.next_rx_sequence, channel.message_factories)

    channel = %{channel | rx_ring: remaining_ring, next_rx_sequence: new_next_rx}

    Enum.each(contiguous, fn {_envelope, message} ->
      run_callbacks(channel, message)
    end)

    channel
  end

  defp collect_contiguous(rx_ring, next_seq, message_factories) do
    {contiguous, new_next} = scan_contiguous(rx_ring, next_seq, message_factories, [])
    contiguous_seqs = MapSet.new(Enum.map(contiguous, fn {env, _msg} -> env.sequence end))
    remaining = Enum.reject(rx_ring, fn e -> MapSet.member?(contiguous_seqs, e.sequence) end)
    {contiguous, remaining, new_next}
  end

  defp scan_contiguous(ring, next_seq, factories, acc) do
    case Enum.find(ring, fn e -> e.sequence == next_seq end) do
      nil ->
        {Enum.reverse(acc), next_seq}

      envelope ->
        message =
          if not envelope.unpacked do
            env = Envelope.unpack(envelope, factories)
            env.message
          else
            envelope.message
          end

        new_next = rem(next_seq + 1, @seq_modulus)
        acc = [{envelope, message} | acc]

        if new_next == 0 do
          scan_contiguous_after_wrap(ring, new_next, factories, acc)
        else
          scan_contiguous(ring, new_next, factories, acc)
        end
    end
  end

  defp scan_contiguous_after_wrap(ring, next_seq, factories, acc) do
    case Enum.find(ring, fn e -> e.sequence == next_seq end) do
      nil ->
        {Enum.reverse(acc), next_seq}

      envelope ->
        message =
          if not envelope.unpacked do
            env = Envelope.unpack(envelope, factories)
            env.message
          else
            envelope.message
          end

        new_next = rem(next_seq + 1, @seq_modulus)
        acc = [{envelope, message} | acc]
        scan_contiguous_after_wrap(ring, new_next, factories, acc)
    end
  end

  # ── Delivery confirmation ────────────────────────────────────

  @doc """
  Handle packet delivery confirmation.

  Removes the envelope from the TX ring and adjusts the window upward.
  """
  @spec packet_delivered(t(), any()) :: t()
  def packet_delivered(%__MODULE__{} = channel, packet) do
    outlet = channel.outlet
    packet_id = Outlet.get_packet_id(outlet, packet)

    case find_envelope_by_packet_id(channel.tx_ring, outlet, packet_id) do
      nil ->
        RNS.Log.log("Spurious message received on channel", :extreme)
        channel

      _envelope ->
        tx_ring =
          Enum.reject(channel.tx_ring, fn e ->
            e.packet != nil and Outlet.get_packet_id(outlet, e.packet) == packet_id
          end)

        channel = %{channel | tx_ring: tx_ring}

        channel =
          if channel.window < channel.window_max do
            %{channel | window: channel.window + 1}
          else
            channel
          end

        adjust_rate_window(channel)
    end
  end

  defp adjust_rate_window(%__MODULE__{} = channel) do
    rtt = Outlet.rtt(channel.outlet)

    if rtt == 0 do
      channel
    else
      if rtt > @rtt_fast do
        channel = %{channel | fast_rate_rounds: 0}

        if rtt > @rtt_medium do
          %{channel | medium_rate_rounds: 0}
        else
          channel = %{channel | medium_rate_rounds: channel.medium_rate_rounds + 1}

          if channel.window_max < @window_max_medium and
               channel.medium_rate_rounds == @fast_rate_threshold do
            %{channel | window_max: @window_max_medium, window_min: @window_min_limit_medium}
          else
            channel
          end
        end
      else
        channel = %{channel | fast_rate_rounds: channel.fast_rate_rounds + 1}

        if channel.window_max < @window_max_fast and
             channel.fast_rate_rounds == @fast_rate_threshold do
          %{channel | window_max: @window_max_fast, window_min: @window_min_limit_fast}
        else
          channel
        end
      end
    end
  end

  # ── Timeout handling ─────────────────────────────────────────

  @doc """
  Handle packet timeout.

  Returns `{:ok, channel}` if the packet was retried, or
  `{:shutdown, channel}` if max retries were exceeded.
  """
  @spec packet_timeout(t(), any()) :: {:ok, t()} | {:shutdown, t()}
  def packet_timeout(%__MODULE__{} = channel, packet) do
    if Outlet.get_packet_state(channel.outlet, packet) == @msgstate_delivered do
      {:ok, channel}
    else
      outlet = channel.outlet
      packet_id = Outlet.get_packet_id(outlet, packet)

      case find_envelope_by_packet_id(channel.tx_ring, outlet, packet_id) do
        nil ->
          RNS.Log.log("Spurious timeout on channel", :extreme)
          {:ok, channel}

        envelope ->
          if envelope.tries >= channel.max_tries do
            RNS.Log.log("Retry count exceeded on channel, tearing down Link.", :error)
            channel = shutdown(channel)
            Outlet.timed_out(channel.outlet)
            {:shutdown, channel}
          else
            envelope = %{envelope | tries: envelope.tries + 1}
            Outlet.resend(outlet, envelope.packet)

            owner = channel.owner

            Outlet.set_packet_delivered_callback(
              outlet,
              envelope.packet,
              fn pkt -> Kernel.send(owner, {:channel_delivered, pkt}) end
            )

            timeout = packet_timeout_time(channel, envelope.tries)

            Outlet.set_packet_timeout_callback(
              outlet,
              envelope.packet,
              fn pkt -> Kernel.send(owner, {:channel_timeout, pkt}) end,
              timeout
            )

            channel = replace_envelope_in_tx(channel, envelope)
            channel = update_packet_timeouts(channel)

            channel =
              if channel.window > channel.window_min do
                new_window = channel.window - 1

                new_window_max =
                  if channel.window_max > channel.window_min + channel.window_flexibility do
                    channel.window_max - 1
                  else
                    channel.window_max
                  end

                %{channel | window: new_window, window_max: new_window_max}
              else
                channel
              end

            {:ok, channel}
          end
      end
    end
  end

  # ── Packet timeout calculation ───────────────────────────────

  @doc false
  @spec packet_timeout_time(t(), non_neg_integer()) :: float()
  def packet_timeout_time(%__MODULE__{} = channel, tries) do
    rtt = Outlet.rtt(channel.outlet)
    :math.pow(1.5, tries - 1) * max(rtt * 2.5, 0.025) * (length(channel.tx_ring) + 1.5)
  end

  defp update_packet_timeouts(%__MODULE__{} = channel) do
    # In Python, this directly updates receipt timeouts. In Elixir with
    # immutable data, the actual receipt timeout updates are handled by
    # the outlet/Link integration layer. This function exists for
    # structural compatibility.
    channel
  end

  # ── Internal helpers ─────────────────────────────────────────

  defp emplace_envelope(%__MODULE__{} = channel, envelope, :tx) do
    {ring, is_new} = do_emplace(envelope, channel.tx_ring, channel.next_rx_sequence)
    {%{channel | tx_ring: ring}, is_new}
  end

  defp emplace_envelope(%__MODULE__{} = channel, envelope, :rx) do
    {ring, is_new} = do_emplace(envelope, channel.rx_ring, channel.next_rx_sequence)
    {%{channel | rx_ring: ring}, is_new}
  end

  defp do_emplace(envelope, ring, next_rx_sequence) do
    case find_insert_position(envelope, ring, next_rx_sequence) do
      :duplicate ->
        RNS.Log.log(
          "Envelope: Emplacement of duplicate envelope with sequence #{envelope.sequence}",
          :extreme
        )

        {ring, false}

      {:insert, index} ->
        envelope = %{envelope | tracked: true}
        {List.insert_at(ring, index, envelope), true}

      :append ->
        envelope = %{envelope | tracked: true}
        {ring ++ [envelope], true}
    end
  end

  defp find_insert_position(envelope, ring, next_rx_sequence) do
    do_find_insert(envelope, ring, next_rx_sequence, 0)
  end

  defp do_find_insert(_envelope, [], _next_rx, _i), do: :append

  defp do_find_insert(envelope, [existing | rest], next_rx, i) do
    cond do
      envelope.sequence == existing.sequence ->
        :duplicate

      envelope.sequence < existing.sequence and
          not (next_rx - envelope.sequence > div(@seq_max, 2)) ->
        {:insert, i}

      true ->
        do_find_insert(envelope, rest, next_rx, i + 1)
    end
  end

  defp find_envelope_by_packet_id(tx_ring, outlet, packet_id) do
    Enum.find(tx_ring, fn e ->
      e.packet != nil and Outlet.get_packet_id(outlet, e.packet) == packet_id
    end)
  end

  defp replace_envelope_in_tx(%__MODULE__{} = channel, updated_envelope) do
    outlet = channel.outlet
    packet_id = Outlet.get_packet_id(outlet, updated_envelope.packet)

    tx_ring =
      Enum.map(channel.tx_ring, fn e ->
        cond do
          e.packet != nil and Outlet.get_packet_id(outlet, e.packet) == packet_id ->
            updated_envelope

          e.sequence == updated_envelope.sequence ->
            updated_envelope

          true ->
            e
        end
      end)

    %{channel | tx_ring: tx_ring}
  end

  defp run_callbacks(%__MODULE__{} = channel, message) do
    cbs = channel.message_callbacks

    Enum.reduce_while(cbs, :ok, fn cb, _acc ->
      try do
        if cb.(message) do
          {:halt, :ok}
        else
          {:cont, :ok}
        end
      rescue
        e ->
          RNS.Log.log(
            "Channel experienced an error while running a message callback. The contained exception was: #{inspect(e)}",
            :error
          )

          {:cont, :ok}
      end
    end)
  end
end

defmodule RNS.Channel.LinkChannelOutlet do
  @moduledoc """
  An implementation of the Channel Outlet protocol for RNS.Link.

  Allows Channel to send packets over an RNS Link with Packets.
  This module will be fully functional when RNS.Link is implemented (Task 5.2).

  Matches `python/RNS/Channel.py` LinkChannelOutlet class.
  """

  defstruct [:link]

  @type t :: %__MODULE__{link: any()}

  @doc "Create a new LinkChannelOutlet wrapping a Link"
  @spec new(any()) :: t()
  def new(link) do
    %__MODULE__{link: link}
  end
end

defimpl RNS.Channel.Outlet, for: RNS.Channel.LinkChannelOutlet do
  use RNS.Constants.Packet
  use RNS.Constants.Channel
  use RNS.Constants.PacketReceipt

  def send_raw(%{link: link}, raw) do
    if link != nil do
      packet = RNS.Packet.new(link, raw, context: @context_channel)

      status = Map.get(link, :status)
      # Link.ACTIVE = 0x00 (will be defined in Task 5.2)
      if status == 0x00 do
        RNS.Packet.send(packet)
      end

      packet
    end
  end

  def resend(_outlet, packet) do
    if packet != nil do
      RNS.Packet.resend(packet)
    end

    packet
  end

  def mdu(%{link: link}) do
    Map.get(link, :mdu) || RNS.Packet.mdu()
  end

  def rtt(%{link: link}) do
    Map.get(link, :rtt) || 0.0
  end

  def is_usable(_outlet) do
    true
  end

  def get_packet_state(_outlet, packet) do
    cond do
      packet == nil ->
        @msgstate_failed

      Map.get(packet, :receipt) == nil ->
        @msgstate_failed

      true ->
        status = RNS.PacketReceipt.status(packet.receipt)

        cond do
          status == @sent -> @msgstate_sent
          status == @delivered -> @msgstate_delivered
          status == @failed -> @msgstate_failed
          true -> @msgstate_failed
        end
    end
  end

  def timed_out(%{link: link}) do
    teardown = Map.get(link, :teardown)

    if is_function(teardown, 0) do
      teardown.()
    end

    :ok
  end

  def set_packet_timeout_callback(_outlet, packet, callback, timeout) do
    if packet != nil and Map.get(packet, :receipt) != nil do
      receipt = packet.receipt

      receipt =
        if timeout != nil do
          RNS.PacketReceipt.set_timeout(receipt, timeout)
        else
          receipt
        end

      if callback != nil do
        inner = fn _receipt -> callback.(packet) end
        RNS.PacketReceipt.set_timeout_callback(receipt, inner)
      else
        RNS.PacketReceipt.set_timeout_callback(receipt, nil)
      end
    end

    :ok
  end

  def set_packet_delivered_callback(_outlet, packet, callback) do
    if packet != nil and Map.get(packet, :receipt) != nil do
      if callback != nil do
        inner = fn _receipt -> callback.(packet) end
        RNS.PacketReceipt.set_delivery_callback(packet.receipt, inner)
      else
        RNS.PacketReceipt.set_delivery_callback(packet.receipt, nil)
      end
    end

    :ok
  end

  def get_packet_id(_outlet, packet) do
    if packet != nil and is_map(packet) do
      cond do
        is_struct(packet, RNS.Packet) -> RNS.Packet.hash(packet)
        Map.has_key?(packet, :packet_hash) -> Map.get(packet, :packet_hash)
        true -> nil
      end
    else
      nil
    end
  end
end
