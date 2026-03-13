defmodule RNS.Channel.TestMessage do
  @moduledoc false
  @behaviour RNS.Channel.MessageBase

  defstruct data: <<>>

  @impl true
  def msgtype, do: 0x0001

  @impl true
  def new, do: %__MODULE__{}

  @impl true
  def pack(%__MODULE__{data: data}), do: data || <<>>

  @impl true
  def unpack(%__MODULE__{} = _msg, raw), do: %__MODULE__{data: raw}
end

defmodule RNS.Channel.TestMessage2 do
  @moduledoc false
  @behaviour RNS.Channel.MessageBase

  defstruct value: 0

  @impl true
  def msgtype, do: 0x0002

  @impl true
  def new, do: %__MODULE__{}

  @impl true
  def pack(%__MODULE__{value: v}), do: <<v::unsigned-big-32>>

  @impl true
  def unpack(%__MODULE__{} = _msg, <<v::unsigned-big-32>>), do: %__MODULE__{value: v}
end

defmodule RNS.Channel.BadMessage do
  @moduledoc false
  # A message type that fails on new/0 — used for registration validation

  defstruct []

  def msgtype, do: 0x0003
  def new, do: raise("cannot construct")
  def pack(_), do: <<>>
  def unpack(_, _), do: %__MODULE__{}
end

defmodule RNS.Channel.SystemMessage do
  @moduledoc false
  @behaviour RNS.Channel.MessageBase

  defstruct data: <<>>

  @impl true
  def msgtype, do: 0xFF00

  @impl true
  def new, do: %__MODULE__{}

  @impl true
  def pack(%__MODULE__{data: data}), do: data || <<>>

  @impl true
  def unpack(%__MODULE__{} = _msg, raw), do: %__MODULE__{data: raw}
end

defmodule RNS.ChannelTest do
  use ExUnit.Case, async: true

  alias RNS.Channel
  alias RNS.Channel.{Envelope, Outlet, TestOutlet, TestMessage, TestMessage2, ChannelException}

  # ── Helper ──────────────────────────────────────────────────

  defp make_channel(opts \\ []) do
    outlet = TestOutlet.new(opts)
    channel = Channel.new(outlet, owner: self())
    channel = Channel.register_message_type(channel, TestMessage)
    {channel, outlet}
  end

  # ── Constants ───────────────────────────────────────────────

  describe "constants" do
    test "system message type" do
      assert Channel.smt_stream_data() == 0xFF00
    end

    test "window constants" do
      assert Channel.window_const() == 2
      assert Channel.window_min_const() == 2
      assert Channel.window_min_limit_slow() == 2
      assert Channel.window_min_limit_medium() == 5
      assert Channel.window_min_limit_fast() == 16
      assert Channel.window_max_slow() == 5
      assert Channel.window_max_medium() == 12
      assert Channel.window_max_fast() == 48
      assert Channel.window_max_const() == 48
      assert Channel.window_flexibility_const() == 4
    end

    test "rate constants" do
      assert Channel.fast_rate_threshold() == 10
      assert Channel.rtt_fast() == 0.18
      assert Channel.rtt_medium() == 0.75
      assert Channel.rtt_slow() == 1.45
    end

    test "sequence constants" do
      assert Channel.seq_max() == 0xFFFF
      assert Channel.seq_modulus() == 0x10000
    end

    test "message state constants" do
      assert Channel.msgstate_new() == 0
      assert Channel.msgstate_sent() == 1
      assert Channel.msgstate_delivered() == 2
      assert Channel.msgstate_failed() == 3
    end

    test "channel exception type codes" do
      assert Channel.me_no_msg_type() == 0
      assert Channel.me_invalid_msg_type() == 1
      assert Channel.me_not_registered() == 2
      assert Channel.me_link_not_ready() == 3
      assert Channel.me_already_sent() == 4
      assert Channel.me_too_big() == 5
    end

    test "envelope header size" do
      assert Channel.envelope_header_size() == 6
    end
  end

  # ── Construction ────────────────────────────────────────────

  describe "new/2" do
    test "creates channel with default window for normal RTT" do
      outlet = TestOutlet.new(rtt: 0.1)
      channel = Channel.new(outlet, owner: self())

      assert channel.outlet == outlet
      assert channel.owner == self()
      assert channel.window == 2
      assert channel.window_max == 5
      assert channel.window_min == 2
      assert channel.window_flexibility == 4
      assert channel.tx_ring == []
      assert channel.rx_ring == []
      assert channel.next_sequence == 0
      assert channel.next_rx_sequence == 0
      assert channel.message_factories == %{}
      assert channel.message_callbacks == []
      assert channel.fast_rate_rounds == 0
      assert channel.medium_rate_rounds == 0
    end

    test "creates channel with window=1 for very slow RTT" do
      outlet = TestOutlet.new(rtt: 2.0)
      channel = Channel.new(outlet, owner: self())

      assert channel.window == 1
      assert channel.window_max == 1
      assert channel.window_min == 1
      assert channel.window_flexibility == 1
    end

    test "creates channel with normal window at RTT_SLOW boundary" do
      outlet = TestOutlet.new(rtt: 1.45)
      channel = Channel.new(outlet, owner: self())

      # Exactly at RTT_SLOW, not above it
      assert channel.window == 2
      assert channel.window_max == 5
    end

    test "defaults owner to self()" do
      outlet = TestOutlet.new()
      channel = Channel.new(outlet)

      assert channel.owner == self()
    end
  end

  # ── Message type registration ───────────────────────────────

  describe "register_message_type/2" do
    test "registers a valid message type" do
      outlet = TestOutlet.new()
      channel = Channel.new(outlet, owner: self())

      channel = Channel.register_message_type(channel, TestMessage)
      assert Map.has_key?(channel.message_factories, 0x0001)
      assert channel.message_factories[0x0001] == TestMessage
    end

    test "registers multiple message types" do
      outlet = TestOutlet.new()
      channel = Channel.new(outlet, owner: self())

      channel = Channel.register_message_type(channel, TestMessage)
      channel = Channel.register_message_type(channel, TestMessage2)

      assert map_size(channel.message_factories) == 2
      assert channel.message_factories[0x0001] == TestMessage
      assert channel.message_factories[0x0002] == TestMessage2
    end

    test "rejects message type with system-reserved MSGTYPE" do
      outlet = TestOutlet.new()
      channel = Channel.new(outlet, owner: self())

      assert_raise ChannelException, ~r/system-reserved/, fn ->
        Channel.register_message_type(channel, RNS.Channel.SystemMessage)
      end
    end

    test "allows system message type via register_system_message_type" do
      outlet = TestOutlet.new()
      channel = Channel.new(outlet, owner: self())

      channel = Channel.register_system_message_type(channel, RNS.Channel.SystemMessage)
      assert Map.has_key?(channel.message_factories, 0xFF00)
    end

    test "rejects message type that fails construction" do
      outlet = TestOutlet.new()
      channel = Channel.new(outlet, owner: self())

      assert_raise ChannelException, ~r/raised an exception/, fn ->
        Channel.register_message_type(channel, RNS.Channel.BadMessage)
      end
    end
  end

  # ── Message handlers ────────────────────────────────────────

  describe "add_message_handler/2 and remove_message_handler/2" do
    test "adds a message handler" do
      {channel, _outlet} = make_channel()
      handler = fn _msg -> false end

      channel = Channel.add_message_handler(channel, handler)
      assert length(channel.message_callbacks) == 1
    end

    test "does not add duplicate handler" do
      {channel, _outlet} = make_channel()
      handler = fn _msg -> false end

      channel = Channel.add_message_handler(channel, handler)
      channel = Channel.add_message_handler(channel, handler)
      assert length(channel.message_callbacks) == 1
    end

    test "removes a message handler" do
      {channel, _outlet} = make_channel()
      handler = fn _msg -> false end

      channel = Channel.add_message_handler(channel, handler)
      channel = Channel.remove_message_handler(channel, handler)
      assert channel.message_callbacks == []
    end

    test "removing non-existent handler is a no-op" do
      {channel, _outlet} = make_channel()
      handler = fn _msg -> false end

      channel = Channel.remove_message_handler(channel, handler)
      assert channel.message_callbacks == []
    end
  end

  # ── MDU ─────────────────────────────────────────────────────

  describe "mdu/1" do
    test "returns outlet MDU minus envelope header size" do
      outlet = TestOutlet.new(mdu: 500)
      channel = Channel.new(outlet, owner: self())

      assert Channel.mdu(channel) == 500 - 6
    end

    test "caps at 0xFFFF" do
      outlet = TestOutlet.new(mdu: 0x10010)
      channel = Channel.new(outlet, owner: self())

      assert Channel.mdu(channel) == 0xFFFF
    end
  end

  # ── Readiness ───────────────────────────────────────────────

  describe "is_ready_to_send/1" do
    test "returns true when no outstanding packets" do
      {channel, _outlet} = make_channel()
      assert Channel.is_ready_to_send(channel) == true
    end

    test "returns false when outlet is not usable" do
      outlet = TestOutlet.new(usable: false)
      channel = Channel.new(outlet, owner: self())
      assert Channel.is_ready_to_send(channel) == false
    end

    test "returns false when window is full" do
      {channel, _outlet} = make_channel()

      # Send enough messages to fill the window (window=2)
      msg = %TestMessage{data: "hello"}
      {:ok, channel, _env1} = Channel.send(channel, msg)
      {:ok, channel, _env2} = Channel.send(channel, msg)

      assert Channel.is_ready_to_send(channel) == false
    end

    test "returns true after delivery frees window" do
      {channel, outlet} = make_channel()

      msg = %TestMessage{data: "hello"}
      {:ok, channel, env1} = Channel.send(channel, msg)
      {:ok, channel, _env2} = Channel.send(channel, msg)

      # Window full
      assert Channel.is_ready_to_send(channel) == false

      # Deliver first packet
      TestOutlet.deliver_packet(outlet, env1.packet.id)
      channel = Channel.packet_delivered(channel, env1.packet)

      assert Channel.is_ready_to_send(channel) == true
    end
  end

  # ── Envelope ────────────────────────────────────────────────

  describe "Envelope" do
    test "new/1 creates envelope with timestamp and id" do
      env = Envelope.new(sequence: 42, message: %TestMessage{data: "test"})

      assert env.sequence == 42
      assert env.message == %TestMessage{data: "test"}
      assert env.ts > 0
      assert env.id != nil
      assert env.tries == 0
      assert env.packed == false
      assert env.unpacked == false
      assert env.tracked == false
    end

    test "pack/1 serializes message with >HHH header" do
      msg = %TestMessage{data: "hello"}
      env = Envelope.new(sequence: 5, message: msg)
      env = Envelope.pack(env)

      # Header: msgtype(2) + sequence(2) + length(2) = 6 bytes
      assert byte_size(env.raw) == 6 + 5
      assert env.packed == true

      <<msgtype::unsigned-big-16, seq::unsigned-big-16, len::unsigned-big-16, data::binary>> =
        env.raw

      assert msgtype == 0x0001
      assert seq == 5
      assert len == 5
      assert data == "hello"
    end

    test "pack/1 handles empty data" do
      msg = %TestMessage{data: <<>>}
      env = Envelope.new(sequence: 0, message: msg)
      env = Envelope.pack(env)

      assert byte_size(env.raw) == 6

      <<_msgtype::unsigned-big-16, _seq::unsigned-big-16, len::unsigned-big-16, data::binary>> =
        env.raw

      assert len == 0
      assert data == <<>>
    end

    test "unpack/2 deserializes message" do
      # Build raw data for a TestMessage with sequence 10
      data = "world"
      raw = <<0x0001::unsigned-big-16, 10::unsigned-big-16, 5::unsigned-big-16>> <> data

      factories = %{0x0001 => TestMessage}
      env = Envelope.new(raw: raw)
      env = Envelope.unpack(env, factories)

      assert env.sequence == 10
      assert env.message == %TestMessage{data: "world"}
      assert env.unpacked == true
    end

    test "unpack/2 raises for unregistered message type" do
      raw = <<0x9999::unsigned-big-16, 0::unsigned-big-16, 0::unsigned-big-16>>
      env = Envelope.new(raw: raw)

      assert_raise ChannelException, ~r/Unable to find constructor/, fn ->
        Envelope.unpack(env, %{})
      end
    end

    test "pack then unpack roundtrip" do
      msg = %TestMessage{data: "roundtrip test"}
      env = Envelope.new(sequence: 42, message: msg)
      env = Envelope.pack(env)

      factories = %{0x0001 => TestMessage}
      env2 = Envelope.new(raw: env.raw)
      env2 = Envelope.unpack(env2, factories)

      assert env2.sequence == 42
      assert env2.message.data == "roundtrip test"
    end

    test "pack/unpack with TestMessage2 (integer encoding)" do
      msg = %TestMessage2{value: 12345}
      env = Envelope.new(sequence: 7, message: msg)
      env = Envelope.pack(env)

      factories = %{0x0002 => TestMessage2}
      env2 = Envelope.new(raw: env.raw)
      env2 = Envelope.unpack(env2, factories)

      assert env2.sequence == 7
      assert env2.message.value == 12345
    end
  end

  # ── Send ────────────────────────────────────────────────────

  describe "send/2" do
    test "sends a message and returns updated channel" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "hello"}

      {:ok, channel, envelope} = Channel.send(channel, msg)

      assert channel.next_sequence == 1
      assert length(channel.tx_ring) == 1
      assert envelope.packet != nil
      assert envelope.tries == 1
      assert envelope.packed == true

      # Verify packet was sent through outlet
      packets = TestOutlet.get_packets(outlet)
      assert length(packets) == 1
    end

    test "increments sequence for multiple sends" do
      {channel, _outlet} = make_channel()
      msg = %TestMessage{data: "test"}

      {:ok, channel, env1} = Channel.send(channel, msg)
      {:ok, channel, env2} = Channel.send(channel, msg)

      assert env1.sequence == 0
      assert env2.sequence == 1
      assert channel.next_sequence == 2
    end

    test "raises when channel is not ready" do
      {channel, _outlet} = make_channel()
      msg = %TestMessage{data: "test"}

      # Fill window
      {:ok, channel, _} = Channel.send(channel, msg)
      {:ok, channel, _} = Channel.send(channel, msg)

      assert_raise ChannelException, ~r/Link is not ready/, fn ->
        Channel.send(channel, msg)
      end
    end

    test "raises when packed message exceeds outlet MDU" do
      outlet = TestOutlet.new(mdu: 10)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)

      # Message with 10 bytes of data + 6 byte header = 16 > 10
      msg = %TestMessage{data: :binary.copy(<<0>>, 10)}

      assert_raise ChannelException, ~r/too big/, fn ->
        Channel.send(channel, msg)
      end
    end

    test "sequence wraps around at SEQ_MAX" do
      {channel, _outlet} = make_channel()
      channel = %{channel | next_sequence: 0xFFFF, window: 100, window_max: 100}

      msg = %TestMessage{data: "wrap"}
      {:ok, channel, env} = Channel.send(channel, msg)

      assert env.sequence == 0xFFFF
      assert channel.next_sequence == 0
    end
  end

  # ── Receive ─────────────────────────────────────────────────

  describe "receive_raw/2" do
    test "receives and delivers a single message" do
      {channel, _outlet} = make_channel()
      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:messages, []})

      handler = fn msg ->
        [{:messages, msgs}] = :ets.lookup(received, :messages)
        :ets.insert(received, {:messages, msgs ++ [msg]})
        true
      end

      channel = Channel.add_message_handler(channel, handler)

      # Build raw message with sequence 0
      data = "received"

      raw =
        <<0x0001::unsigned-big-16, 0::unsigned-big-16, byte_size(data)::unsigned-big-16>> <> data

      channel = Channel.receive_raw(channel, raw)

      assert channel.next_rx_sequence == 1
      [{:messages, msgs}] = :ets.lookup(received, :messages)
      assert length(msgs) == 1
      assert hd(msgs).data == "received"

      :ets.delete(received)
    end

    test "delivers messages in sequence order" do
      {channel, _outlet} = make_channel()
      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:messages, []})

      handler = fn msg ->
        [{:messages, msgs}] = :ets.lookup(received, :messages)
        :ets.insert(received, {:messages, msgs ++ [msg]})
        true
      end

      channel = Channel.add_message_handler(channel, handler)

      # Send sequence 1 first (out of order)
      data1 = "msg1"

      raw1 =
        <<0x0001::unsigned-big-16, 1::unsigned-big-16, byte_size(data1)::unsigned-big-16>> <>
          data1

      channel = Channel.receive_raw(channel, raw1)

      # Sequence 1 arrived but sequence 0 hasn't — nothing should be delivered yet
      [{:messages, msgs}] = :ets.lookup(received, :messages)
      assert length(msgs) == 0

      # Now send sequence 0
      data0 = "msg0"

      raw0 =
        <<0x0001::unsigned-big-16, 0::unsigned-big-16, byte_size(data0)::unsigned-big-16>> <>
          data0

      channel = Channel.receive_raw(channel, raw0)

      # Both should now be delivered in order
      [{:messages, msgs}] = :ets.lookup(received, :messages)
      assert length(msgs) == 2
      assert Enum.at(msgs, 0).data == "msg0"
      assert Enum.at(msgs, 1).data == "msg1"
      assert channel.next_rx_sequence == 2

      :ets.delete(received)
    end

    test "rejects duplicate messages" do
      {channel, _outlet} = make_channel()
      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:count, 0})

      handler = fn _msg ->
        [{:count, n}] = :ets.lookup(received, :count)
        :ets.insert(received, {:count, n + 1})
        true
      end

      channel = Channel.add_message_handler(channel, handler)

      data = "dup"

      raw =
        <<0x0001::unsigned-big-16, 0::unsigned-big-16, byte_size(data)::unsigned-big-16>> <> data

      channel = Channel.receive_raw(channel, raw)
      _channel = Channel.receive_raw(channel, raw)

      [{:count, count}] = :ets.lookup(received, :count)
      assert count == 1

      :ets.delete(received)
    end

    test "rejects invalid sequence (too old)" do
      {channel, _outlet} = make_channel()

      # Advance next_rx_sequence past 0
      channel = %{channel | next_rx_sequence: 10}

      data = "old"

      raw =
        <<0x0001::unsigned-big-16, 5::unsigned-big-16, byte_size(data)::unsigned-big-16>> <> data

      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:count, 0})

      handler = fn _msg ->
        [{:count, n}] = :ets.lookup(received, :count)
        :ets.insert(received, {:count, n + 1})
        true
      end

      channel = Channel.add_message_handler(channel, handler)
      _channel = Channel.receive_raw(channel, raw)

      [{:count, count}] = :ets.lookup(received, :count)
      assert count == 0

      :ets.delete(received)
    end

    test "handles handler returning false (continues to next handler)" do
      {channel, _outlet} = make_channel()
      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:handlers_called, []})

      handler1 = fn _msg ->
        [{:handlers_called, h}] = :ets.lookup(received, :handlers_called)
        :ets.insert(received, {:handlers_called, h ++ [:handler1]})
        false
      end

      handler2 = fn _msg ->
        [{:handlers_called, h}] = :ets.lookup(received, :handlers_called)
        :ets.insert(received, {:handlers_called, h ++ [:handler2]})
        true
      end

      channel = Channel.add_message_handler(channel, handler1)
      channel = Channel.add_message_handler(channel, handler2)

      data = "test"

      raw =
        <<0x0001::unsigned-big-16, 0::unsigned-big-16, byte_size(data)::unsigned-big-16>> <> data

      _channel = Channel.receive_raw(channel, raw)

      [{:handlers_called, handlers}] = :ets.lookup(received, :handlers_called)
      assert handlers == [:handler1, :handler2]

      :ets.delete(received)
    end

    test "handler returning true stops processing" do
      {channel, _outlet} = make_channel()
      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:handlers_called, []})

      handler1 = fn _msg ->
        [{:handlers_called, h}] = :ets.lookup(received, :handlers_called)
        :ets.insert(received, {:handlers_called, h ++ [:handler1]})
        true
      end

      handler2 = fn _msg ->
        [{:handlers_called, h}] = :ets.lookup(received, :handlers_called)
        :ets.insert(received, {:handlers_called, h ++ [:handler2]})
        true
      end

      channel = Channel.add_message_handler(channel, handler1)
      channel = Channel.add_message_handler(channel, handler2)

      data = "test"

      raw =
        <<0x0001::unsigned-big-16, 0::unsigned-big-16, byte_size(data)::unsigned-big-16>> <> data

      _channel = Channel.receive_raw(channel, raw)

      [{:handlers_called, handlers}] = :ets.lookup(received, :handlers_called)
      assert handlers == [:handler1]

      :ets.delete(received)
    end

    test "handles malformed data gracefully" do
      {channel, _outlet} = make_channel()

      # Too short to be a valid envelope
      channel2 = Channel.receive_raw(channel, <<1, 2>>)

      # Should not crash, channel state unchanged
      assert channel2.next_rx_sequence == channel.next_rx_sequence
    end

    test "handles unregistered message type gracefully" do
      outlet = TestOutlet.new()
      channel = Channel.new(outlet, owner: self())
      # Don't register any message types

      data = "test"

      raw =
        <<0x0001::unsigned-big-16, 0::unsigned-big-16, byte_size(data)::unsigned-big-16>> <> data

      channel2 = Channel.receive_raw(channel, raw)
      assert channel2.next_rx_sequence == 0
    end

    test "contiguous delivery across multiple receives" do
      {channel, _outlet} = make_channel()
      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:messages, []})

      handler = fn msg ->
        [{:messages, msgs}] = :ets.lookup(received, :messages)
        :ets.insert(received, {:messages, msgs ++ [msg]})
        true
      end

      channel = Channel.add_message_handler(channel, handler)

      # Send sequences 0, 1, 2 in order using reduce to thread channel state
      _channel =
        Enum.reduce(0..2, channel, fn seq, ch ->
          data = "msg#{seq}"

          raw =
            <<0x0001::unsigned-big-16, seq::unsigned-big-16, byte_size(data)::unsigned-big-16>> <>
              data

          Channel.receive_raw(ch, raw)
        end)

      [{:messages, msgs}] = :ets.lookup(received, :messages)
      assert length(msgs) == 3
      assert Enum.at(msgs, 0).data == "msg0"
      assert Enum.at(msgs, 1).data == "msg1"
      assert Enum.at(msgs, 2).data == "msg2"

      :ets.delete(received)
    end
  end

  # ── Delivery confirmation ───────────────────────────────────

  describe "packet_delivered/2" do
    test "removes envelope from tx_ring" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "hello"}

      {:ok, channel, env} = Channel.send(channel, msg)
      assert length(channel.tx_ring) == 1

      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)

      assert channel.tx_ring == []
    end

    test "increases window on delivery" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "hello"}

      {:ok, channel, env} = Channel.send(channel, msg)
      initial_window = channel.window

      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)

      assert channel.window == initial_window + 1
    end

    test "does not increase window beyond window_max" do
      {channel, outlet} = make_channel()
      channel = %{channel | window: 5, window_max: 5}

      msg = %TestMessage{data: "hello"}
      {:ok, channel, env} = Channel.send(channel, msg)

      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)

      assert channel.window == 5
    end

    test "handles spurious delivery (unknown packet)" do
      {channel, _outlet} = make_channel()

      # Deliver a packet that was never sent
      fake_packet = %{id: 9999}
      channel2 = Channel.packet_delivered(channel, fake_packet)

      assert channel2 == channel
    end

    test "resets fast_rate_rounds when RTT > RTT_FAST" do
      outlet = TestOutlet.new(rtt: 0.5)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)
      channel = %{channel | fast_rate_rounds: 5}

      msg = %TestMessage{data: "test"}
      {:ok, channel, env} = Channel.send(channel, msg)

      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)

      assert channel.fast_rate_rounds == 0
    end

    test "increments fast_rate_rounds when RTT <= RTT_FAST" do
      outlet = TestOutlet.new(rtt: 0.1)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)

      msg = %TestMessage{data: "test"}
      {:ok, channel, env} = Channel.send(channel, msg)

      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)

      assert channel.fast_rate_rounds == 1
    end

    test "increments medium_rate_rounds when RTT_FAST < RTT <= RTT_MEDIUM" do
      outlet = TestOutlet.new(rtt: 0.5)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)

      msg = %TestMessage{data: "test"}
      {:ok, channel, env} = Channel.send(channel, msg)

      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)

      assert channel.medium_rate_rounds == 1
    end

    test "resets medium_rate_rounds when RTT > RTT_MEDIUM" do
      outlet = TestOutlet.new(rtt: 1.0)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)
      channel = %{channel | medium_rate_rounds: 5}

      msg = %TestMessage{data: "test"}
      {:ok, channel, env} = Channel.send(channel, msg)

      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)

      assert channel.medium_rate_rounds == 0
    end
  end

  # ── Window upgrades ─────────────────────────────────────────

  describe "window rate upgrades" do
    test "upgrades to WINDOW_MAX_FAST after sustained fast rate" do
      outlet = TestOutlet.new(rtt: 0.1)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)
      # window_max must start below WINDOW_MAX_FAST for upgrade to trigger
      channel = %{channel | window: 100, window_max: Channel.window_max_slow()}

      msg = %TestMessage{data: "x"}

      # Simulate FAST_RATE_THRESHOLD deliveries at fast RTT
      channel =
        Enum.reduce(1..10, channel, fn _i, ch ->
          {:ok, ch, env} = Channel.send(ch, msg)
          TestOutlet.deliver_packet(outlet, env.packet.id)
          Channel.packet_delivered(ch, env.packet)
        end)

      assert channel.fast_rate_rounds == 10
      assert channel.window_max == Channel.window_max_fast()
      assert channel.window_min == Channel.window_min_limit_fast()
    end

    test "upgrades to WINDOW_MAX_MEDIUM after sustained medium rate" do
      outlet = TestOutlet.new(rtt: 0.5)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)
      # window_max must start below WINDOW_MAX_MEDIUM for upgrade to trigger
      channel = %{channel | window: 100, window_max: Channel.window_max_slow()}

      msg = %TestMessage{data: "x"}

      channel =
        Enum.reduce(1..10, channel, fn _i, ch ->
          {:ok, ch, env} = Channel.send(ch, msg)
          TestOutlet.deliver_packet(outlet, env.packet.id)
          Channel.packet_delivered(ch, env.packet)
        end)

      assert channel.medium_rate_rounds == 10
      assert channel.window_max == Channel.window_max_medium()
      assert channel.window_min == Channel.window_min_limit_medium()
    end

    test "no upgrade when RTT > RTT_MEDIUM" do
      outlet = TestOutlet.new(rtt: 1.0)
      channel = Channel.new(outlet, owner: self())
      channel = Channel.register_message_type(channel, TestMessage)
      channel = %{channel | window: 100, window_max: Channel.window_max_slow()}

      msg = %TestMessage{data: "x"}

      channel =
        Enum.reduce(1..10, channel, fn _i, ch ->
          {:ok, ch, env} = Channel.send(ch, msg)
          TestOutlet.deliver_packet(outlet, env.packet.id)
          Channel.packet_delivered(ch, env.packet)
        end)

      # No upgrades — both counters reset to 0 each time
      assert channel.fast_rate_rounds == 0
      assert channel.medium_rate_rounds == 0
    end
  end

  # ── Timeout handling ────────────────────────────────────────

  describe "packet_timeout/2" do
    test "retries on first timeout" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "test"}

      {:ok, channel, env} = Channel.send(channel, msg)
      assert env.tries == 1

      {:ok, channel} = Channel.packet_timeout(channel, env.packet)

      # Envelope should still be in tx_ring with incremented tries
      assert length(channel.tx_ring) == 1
      updated_env = hd(channel.tx_ring)
      assert updated_env.tries == 2

      # Resend should have been called
      assert TestOutlet.get_resend_count(outlet, env.packet.id) == 1
    end

    test "decreases window on timeout" do
      {channel, _outlet} = make_channel()
      channel = %{channel | window: 4, window_max: 10}
      msg = %TestMessage{data: "test"}

      {:ok, channel, env} = Channel.send(channel, msg)
      {:ok, channel} = Channel.packet_timeout(channel, env.packet)

      assert channel.window == 3
    end

    test "does not decrease window below window_min" do
      {channel, _outlet} = make_channel()
      channel = %{channel | window: 2, window_min: 2}
      msg = %TestMessage{data: "test"}

      {:ok, channel, env} = Channel.send(channel, msg)
      {:ok, channel} = Channel.packet_timeout(channel, env.packet)

      assert channel.window == 2
    end

    test "decreases window_max on timeout when above flexibility threshold" do
      {channel, _outlet} = make_channel()
      channel = %{channel | window: 4, window_max: 10, window_min: 2, window_flexibility: 4}
      msg = %TestMessage{data: "test"}

      {:ok, channel, env} = Channel.send(channel, msg)
      {:ok, channel} = Channel.packet_timeout(channel, env.packet)

      # window_max was 10, window_min + flexibility = 6, so 10 > 6 means window_max decreases
      assert channel.window_max == 9
    end

    test "does not decrease window_max when at flexibility limit" do
      {channel, _outlet} = make_channel()
      channel = %{channel | window: 4, window_max: 6, window_min: 2, window_flexibility: 4}
      msg = %TestMessage{data: "test"}

      {:ok, channel, env} = Channel.send(channel, msg)
      {:ok, channel} = Channel.packet_timeout(channel, env.packet)

      # window_max (6) == window_min + flexibility (6), so no decrease
      assert channel.window_max == 6
    end

    test "shuts down after max tries exceeded" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "test"}

      {:ok, channel, env} = Channel.send(channel, msg)

      # Set tries to max_tries (5)
      channel =
        %{channel | tx_ring: Enum.map(channel.tx_ring, fn e -> %{e | tries: 5} end)}

      {:shutdown, channel} = Channel.packet_timeout(channel, env.packet)

      assert channel.tx_ring == []
      assert channel.rx_ring == []
      assert channel.message_callbacks == []
      assert TestOutlet.was_timed_out?(outlet) == true
    end

    test "ignores timeout for already delivered packet" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "test"}

      {:ok, channel, env} = Channel.send(channel, msg)

      TestOutlet.deliver_packet(outlet, env.packet.id)
      {:ok, channel2} = Channel.packet_timeout(channel, env.packet)

      # Channel unchanged (still has envelope, no retry)
      assert channel2 == channel
    end

    test "handles spurious timeout (unknown packet)" do
      {channel, _outlet} = make_channel()

      fake_packet = %{id: 9999}
      {:ok, channel2} = Channel.packet_timeout(channel, fake_packet)

      assert channel2 == channel
    end
  end

  # ── Shutdown ────────────────────────────────────────────────

  describe "shutdown/1" do
    test "clears rings and callbacks" do
      {channel, _outlet} = make_channel()
      msg = %TestMessage{data: "test"}

      handler = fn _msg -> true end
      channel = Channel.add_message_handler(channel, handler)
      {:ok, channel, _env} = Channel.send(channel, msg)

      assert length(channel.tx_ring) == 1
      assert length(channel.message_callbacks) == 1

      channel = Channel.shutdown(channel)

      assert channel.tx_ring == []
      assert channel.rx_ring == []
      assert channel.message_callbacks == []
    end
  end

  # ── Packet timeout calculation ──────────────────────────────

  describe "get_packet_timeout_time/2" do
    test "increases with tries" do
      {channel, _outlet} = make_channel()

      t1 = Channel.get_packet_timeout_time(channel, 1)
      t2 = Channel.get_packet_timeout_time(channel, 2)
      t3 = Channel.get_packet_timeout_time(channel, 3)

      assert t2 > t1
      assert t3 > t2
    end

    test "increases with tx_ring length" do
      {channel, _outlet} = make_channel()

      t_empty = Channel.get_packet_timeout_time(channel, 1)

      msg = %TestMessage{data: "x"}
      {:ok, channel, _} = Channel.send(channel, msg)

      t_one = Channel.get_packet_timeout_time(channel, 1)

      assert t_one > t_empty
    end

    test "uses RTT for calculation" do
      outlet_fast = TestOutlet.new(rtt: 0.01)
      channel_fast = Channel.new(outlet_fast, owner: self())

      outlet_slow = TestOutlet.new(rtt: 1.0)
      channel_slow = Channel.new(outlet_slow, owner: self())

      t_fast = Channel.get_packet_timeout_time(channel_fast, 1)
      t_slow = Channel.get_packet_timeout_time(channel_slow, 1)

      assert t_slow > t_fast
    end
  end

  # ── LinkChannelOutlet ───────────────────────────────────────

  describe "LinkChannelOutlet" do
    test "creates with link" do
      outlet = RNS.Channel.LinkChannelOutlet.new(%{mdu: 500, rtt: 0.1})
      assert outlet.link == %{mdu: 500, rtt: 0.1}
    end

    test "mdu returns link mdu or default" do
      outlet = RNS.Channel.LinkChannelOutlet.new(%{mdu: 300})
      assert Outlet.mdu(outlet) == 300

      outlet_no_mdu = RNS.Channel.LinkChannelOutlet.new(%{})
      assert Outlet.mdu(outlet_no_mdu) == RNS.Packet.mdu()
    end

    test "rtt returns link rtt or default" do
      outlet = RNS.Channel.LinkChannelOutlet.new(%{rtt: 0.5})
      assert Outlet.rtt(outlet) == 0.5

      outlet_no_rtt = RNS.Channel.LinkChannelOutlet.new(%{})
      assert Outlet.rtt(outlet_no_rtt) == 0.0
    end

    test "is_usable returns true" do
      outlet = RNS.Channel.LinkChannelOutlet.new(%{})
      assert Outlet.is_usable(outlet) == true
    end

    test "get_packet_id returns nil for nil packet" do
      outlet = RNS.Channel.LinkChannelOutlet.new(%{})
      assert Outlet.get_packet_id(outlet, nil) == nil
    end

    test "get_packet_state returns failed for nil packet" do
      outlet = RNS.Channel.LinkChannelOutlet.new(%{})
      assert Outlet.get_packet_state(outlet, nil) == Channel.msgstate_failed()
    end
  end

  # ── Integration-style tests ─────────────────────────────────

  describe "send and receive roundtrip" do
    test "message sent on one channel can be received on another" do
      {sender, _sender_outlet} = make_channel()
      {receiver, _receiver_outlet} = make_channel()

      received = :ets.new(:received, [:set, :public])
      :ets.insert(received, {:messages, []})

      handler = fn msg ->
        [{:messages, msgs}] = :ets.lookup(received, :messages)
        :ets.insert(received, {:messages, msgs ++ [msg]})
        true
      end

      receiver = Channel.add_message_handler(receiver, handler)

      # Send a message
      msg = %TestMessage{data: "cross-channel test"}
      {:ok, _sender, env} = Channel.send(sender, msg)

      # The raw bytes sent through the outlet are what the receiver gets
      _receiver = Channel.receive_raw(receiver, env.raw)

      [{:messages, msgs}] = :ets.lookup(received, :messages)
      assert length(msgs) == 1
      assert hd(msgs).data == "cross-channel test"

      :ets.delete(received)
    end

    test "full send-deliver cycle with window management" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "windowing"}

      # Initial window is 2
      assert channel.window == 2

      # Send 2 messages (fills window)
      {:ok, channel, env1} = Channel.send(channel, msg)
      {:ok, channel, env2} = Channel.send(channel, msg)
      assert Channel.is_ready_to_send(channel) == false

      # Deliver first — window opens and increases
      TestOutlet.deliver_packet(outlet, env1.packet.id)
      channel = Channel.packet_delivered(channel, env1.packet)
      assert channel.window == 3
      assert Channel.is_ready_to_send(channel) == true

      # Deliver second
      TestOutlet.deliver_packet(outlet, env2.packet.id)
      channel = Channel.packet_delivered(channel, env2.packet)
      assert channel.window == 4
    end

    test "send-timeout-retry-deliver cycle" do
      {channel, outlet} = make_channel()
      msg = %TestMessage{data: "retry"}

      {:ok, channel, env} = Channel.send(channel, msg)
      assert hd(channel.tx_ring).tries == 1

      # Timeout triggers retry
      {:ok, channel} = Channel.packet_timeout(channel, env.packet)
      assert hd(channel.tx_ring).tries == 2
      assert TestOutlet.get_resend_count(outlet, env.packet.id) == 1

      # Deliver after retry
      TestOutlet.deliver_packet(outlet, env.packet.id)
      channel = Channel.packet_delivered(channel, env.packet)
      assert channel.tx_ring == []
    end
  end
end
