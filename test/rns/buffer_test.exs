defmodule RNS.Buffer.StreamDataMessageTest do
  use ExUnit.Case, async: true

  alias RNS.Buffer.StreamDataMessage

  describe "constants" do
    test "MSGTYPE is system message type 0xFF00" do
      assert StreamDataMessage.msgtype() == 0xFF00
      assert StreamDataMessage.msgtype() == RNS.Channel.smt_stream_data()
    end

    test "STREAM_ID_MAX is 0x3FFF (16383)" do
      assert StreamDataMessage.stream_id_max() == 0x3FFF
      assert StreamDataMessage.stream_id_max() == 16383
    end

    test "OVERHEAD is 8 (2 header + 6 envelope)" do
      assert StreamDataMessage.overhead() == 8
    end

    test "MAX_DATA_LEN is Link.mdu - OVERHEAD" do
      assert StreamDataMessage.max_data_len() == RNS.Link.mdu() - 8
    end
  end

  describe "new/0" do
    test "creates default instance with nil stream_id" do
      msg = StreamDataMessage.new()
      assert msg.stream_id == nil
      assert msg.data == <<>>
      assert msg.eof == false
      assert msg.compressed == false
    end
  end

  describe "new/1" do
    test "creates instance with stream_id and data" do
      msg = StreamDataMessage.new(stream_id: 42, data: "hello")
      assert msg.stream_id == 42
      assert msg.data == "hello"
      assert msg.eof == false
      assert msg.compressed == false
    end

    test "creates instance with eof flag" do
      msg = StreamDataMessage.new(stream_id: 1, eof: true)
      assert msg.stream_id == 1
      assert msg.eof == true
    end

    test "rejects stream_id > STREAM_ID_MAX" do
      assert_raise ArgumentError, fn ->
        StreamDataMessage.new(stream_id: 0x4000)
      end
    end

    test "accepts stream_id at STREAM_ID_MAX boundary" do
      msg = StreamDataMessage.new(stream_id: 0x3FFF)
      assert msg.stream_id == 0x3FFF
    end
  end

  describe "pack/1" do
    test "packs stream_id and data into binary" do
      msg = StreamDataMessage.new(stream_id: 42, data: "hello")
      packed = StreamDataMessage.pack(msg)
      # Header: stream_id 42 = 0x002A, no eof, no compressed
      assert <<0x00, 0x2A, rest::binary>> = packed
      assert rest == "hello"
    end

    test "packs with eof flag set (bit 15)" do
      msg = StreamDataMessage.new(stream_id: 1, eof: true)
      packed = StreamDataMessage.pack(msg)
      # Header: 0x8001 (eof bit + stream_id 1)
      assert <<0x80, 0x01>> = packed
    end

    test "packs with compressed flag set (bit 14)" do
      msg = StreamDataMessage.new(stream_id: 5, compressed: true, data: "test")
      packed = StreamDataMessage.pack(msg)
      # Header: 0x4005 (compressed bit + stream_id 5)
      assert <<0x40, 0x05, rest::binary>> = packed
      assert rest == "test"
    end

    test "packs with both eof and compressed flags" do
      msg = StreamDataMessage.new(stream_id: 100, eof: true, compressed: true, data: "x")
      packed = StreamDataMessage.pack(msg)
      # Header: 0xC064 (eof + compressed + stream_id 100)
      <<header::unsigned-big-16, _rest::binary>> = packed
      assert header == 0xC064
    end

    test "raises when stream_id is nil" do
      msg = StreamDataMessage.new()

      assert_raise ArgumentError, fn ->
        StreamDataMessage.pack(msg)
      end
    end

    test "packs empty data (eof signal)" do
      msg = StreamDataMessage.new(stream_id: 0, eof: true)
      packed = StreamDataMessage.pack(msg)
      assert byte_size(packed) == 2
    end
  end

  describe "unpack/2" do
    test "unpacks stream_id and data" do
      raw = <<0x00, 0x2A>> <> "hello"
      msg = StreamDataMessage.unpack(StreamDataMessage.new(), raw)
      assert msg.stream_id == 42
      assert msg.data == "hello"
      assert msg.eof == false
      assert msg.compressed == false
    end

    test "unpacks eof flag" do
      raw = <<0x80, 0x01>>
      msg = StreamDataMessage.unpack(StreamDataMessage.new(), raw)
      assert msg.stream_id == 1
      assert msg.eof == true
      assert msg.data == <<>>
    end

    test "unpacks compressed flag and decompresses data" do
      original = "hello world this is some test data"
      compressed = :zlib.compress(original)
      raw = <<0x40, 0x05>> <> compressed
      msg = StreamDataMessage.unpack(StreamDataMessage.new(), raw)
      assert msg.stream_id == 5
      assert msg.compressed == true
      assert msg.data == original
    end

    test "unpacks both flags" do
      raw = <<0xC0, 0x64>>
      msg = StreamDataMessage.unpack(StreamDataMessage.new(), raw)
      assert msg.stream_id == 100
      assert msg.eof == true
      assert msg.compressed == true
    end
  end

  describe "pack/unpack roundtrip" do
    test "roundtrips data without compression" do
      original = StreamDataMessage.new(stream_id: 123, data: "test data")
      packed = StreamDataMessage.pack(original)
      unpacked = StreamDataMessage.unpack(StreamDataMessage.new(), packed)
      assert unpacked.stream_id == 123
      assert unpacked.data == "test data"
      assert unpacked.eof == false
    end

    test "roundtrips eof signal" do
      original = StreamDataMessage.new(stream_id: 0, eof: true)
      packed = StreamDataMessage.pack(original)
      unpacked = StreamDataMessage.unpack(StreamDataMessage.new(), packed)
      assert unpacked.stream_id == 0
      assert unpacked.eof == true
    end

    test "roundtrips max stream_id" do
      original = StreamDataMessage.new(stream_id: 0x3FFF, data: "max")
      packed = StreamDataMessage.pack(original)
      unpacked = StreamDataMessage.unpack(StreamDataMessage.new(), packed)
      assert unpacked.stream_id == 0x3FFF
      assert unpacked.data == "max"
    end
  end

  describe "MessageBase behaviour" do
    test "implements msgtype/0" do
      assert function_exported?(StreamDataMessage, :msgtype, 0)
    end

    test "implements new/0" do
      assert function_exported?(StreamDataMessage, :new, 0)
    end

    test "implements pack/1" do
      assert function_exported?(StreamDataMessage, :pack, 1)
    end

    test "implements unpack/2" do
      assert function_exported?(StreamDataMessage, :unpack, 2)
    end
  end
end

defmodule RNS.Buffer.RawChannelReaderTest do
  use ExUnit.Case, async: true

  alias RNS.Buffer.{RawChannelReader, StreamDataMessage}
  alias RNS.Channel

  defp setup_reader(_context \\ %{}) do
    outlet = RNS.Channel.TestOutlet.new(mdu: 500, rtt: 0.1)
    channel = Channel.new(outlet)
    {reader, channel} = RawChannelReader.new(0, channel)
    %{reader: reader, channel: channel, outlet: outlet}
  end

  describe "new/2" do
    test "creates a reader and registers StreamDataMessage on channel" do
      %{reader: reader, channel: channel} = setup_reader()
      assert is_pid(reader)
      # StreamDataMessage should be registered as system message type
      assert Map.has_key?(channel.message_factories, StreamDataMessage.msgtype())
    end

    test "registers a message handler on the channel" do
      %{channel: channel} = setup_reader()
      assert length(channel.message_callbacks) == 1
    end
  end

  describe "read/2" do
    test "returns nil when buffer is empty and not eof" do
      %{reader: reader} = setup_reader()
      assert RawChannelReader.read(reader, 10) == nil
    end

    test "reads data from buffer after receiving message" do
      %{reader: reader, channel: channel} = setup_reader()
      # Simulate receiving a StreamDataMessage
      msg = StreamDataMessage.new(stream_id: 0, data: "hello")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)

      # Give callback time to execute
      Process.sleep(10)

      result = RawChannelReader.read(reader, 10)
      assert result == "hello"
    end

    test "reads partial data when size < buffer length" do
      %{reader: reader, channel: channel} = setup_reader()
      msg = StreamDataMessage.new(stream_id: 0, data: "hello world")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)
      Process.sleep(10)

      result = RawChannelReader.read(reader, 5)
      assert result == "hello"

      # Remaining data still available
      result2 = RawChannelReader.read(reader, 10)
      assert result2 == " world"
    end

    test "returns empty binary on eof when buffer is empty" do
      %{reader: reader, channel: channel} = setup_reader()
      # Send eof
      msg = StreamDataMessage.new(stream_id: 0, eof: true)
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)
      Process.sleep(10)

      result = RawChannelReader.read(reader, 10)
      assert result == <<>>
    end

    test "ignores messages for different stream_id" do
      %{reader: reader, channel: channel} = setup_reader()
      # Send to stream_id 99, reader is on stream_id 0
      msg = StreamDataMessage.new(stream_id: 99, data: "wrong stream")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)
      Process.sleep(10)

      assert RawChannelReader.read(reader, 20) == nil
    end
  end

  describe "add_ready_callback/2 and remove_ready_callback/2" do
    test "callback is invoked when data arrives" do
      %{reader: reader, channel: channel} = setup_reader()
      test_pid = self()
      callback = fn ready_bytes -> send(test_pid, {:ready, ready_bytes}) end
      RawChannelReader.add_ready_callback(reader, callback)

      msg = StreamDataMessage.new(stream_id: 0, data: "hello")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)

      assert_receive {:ready, 5}, 500
    end

    test "callback removed does not fire" do
      %{reader: reader, channel: channel} = setup_reader()
      test_pid = self()
      callback = fn ready_bytes -> send(test_pid, {:ready, ready_bytes}) end
      RawChannelReader.add_ready_callback(reader, callback)
      RawChannelReader.remove_ready_callback(reader, callback)

      msg = StreamDataMessage.new(stream_id: 0, data: "hello")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)

      refute_receive {:ready, _}, 100
    end
  end

  describe "close/1" do
    test "clears listeners" do
      %{reader: reader} = setup_reader()
      test_pid = self()
      callback = fn ready_bytes -> send(test_pid, {:ready, ready_bytes}) end
      RawChannelReader.add_ready_callback(reader, callback)
      RawChannelReader.close(reader)
      # After close, the agent should be stopped
      Process.sleep(10)
      refute Process.alive?(reader)
    end
  end

  describe "eof?/1" do
    test "returns false initially" do
      %{reader: reader} = setup_reader()
      assert RawChannelReader.eof?(reader) == false
    end

    test "returns true after eof message" do
      %{reader: reader, channel: channel} = setup_reader()
      msg = StreamDataMessage.new(stream_id: 0, eof: true)
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)
      Process.sleep(10)

      assert RawChannelReader.eof?(reader) == true
    end
  end
end

defmodule RNS.Buffer.RawChannelWriterTest do
  use ExUnit.Case, async: true

  alias RNS.Buffer.{RawChannelWriter, StreamDataMessage}
  alias RNS.Channel

  defp setup_writer(_context \\ %{}) do
    outlet = RNS.Channel.TestOutlet.new(mdu: 500, rtt: 0.1)
    channel = Channel.new(outlet)
    channel = Channel.register_system_message_type(channel, StreamDataMessage)
    writer = RawChannelWriter.new(0, channel)
    %{writer: writer, channel: channel, outlet: outlet}
  end

  describe "new/2" do
    test "creates a writer with stream_id" do
      %{writer: writer} = setup_writer()
      assert writer.stream_id == 0
      assert writer.eof == false
    end
  end

  describe "write/2" do
    test "sends data as StreamDataMessage" do
      %{writer: writer, channel: channel, outlet: outlet} = setup_writer()
      {bytes_written, _channel} = RawChannelWriter.write(writer, "hello", channel)
      assert bytes_written > 0
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      assert length(packets) == 1
    end

    test "returns number of bytes processed" do
      %{writer: writer, channel: channel} = setup_writer()
      {bytes_written, _channel} = RawChannelWriter.write(writer, "hello world", channel)
      assert bytes_written == 11
    end

    test "truncates data exceeding MAX_CHUNK_LEN" do
      %{writer: writer, channel: channel} = setup_writer()
      large_data = :crypto.strong_rand_bytes(RawChannelWriter.max_chunk_len() + 100)
      {bytes_written, _channel} = RawChannelWriter.write(writer, large_data, channel)
      assert bytes_written <= RawChannelWriter.max_chunk_len()
    end

    test "returns 0 when channel is not ready" do
      outlet = RNS.Channel.TestOutlet.new(mdu: 500, rtt: 0.1, usable: false)
      channel = Channel.new(outlet)
      channel = Channel.register_system_message_type(channel, StreamDataMessage)
      writer = RawChannelWriter.new(0, channel)

      {bytes_written, _channel} = RawChannelWriter.write(writer, "hello", channel)
      assert bytes_written == 0
    end
  end

  describe "close/2" do
    test "sends eof message" do
      %{writer: writer, channel: channel, outlet: outlet} = setup_writer()
      {_writer, _channel} = RawChannelWriter.close(writer, channel)
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      assert length(packets) == 1
    end
  end

  describe "constants" do
    test "MAX_CHUNK_LEN is 16384" do
      assert RawChannelWriter.max_chunk_len() == 16 * 1024
    end

    test "COMPRESSION_TRIES is 4" do
      assert RawChannelWriter.compression_tries() == 4
    end
  end
end

defmodule RNS.BufferTest do
  use ExUnit.Case, async: true

  alias RNS.Buffer
  alias RNS.Buffer.{StreamDataMessage, RawChannelReader, RawChannelWriter}
  alias RNS.Channel

  defp setup_channel(_context \\ %{}) do
    outlet = RNS.Channel.TestOutlet.new(mdu: 500, rtt: 0.1)
    channel = Channel.new(outlet)
    %{channel: channel, outlet: outlet}
  end

  describe "create_reader/3" do
    test "creates a reader for the given stream_id" do
      %{channel: channel} = setup_channel()
      {reader, channel} = Buffer.create_reader(0, channel)
      assert is_pid(reader)
      # StreamDataMessage is registered
      assert Map.has_key?(channel.message_factories, StreamDataMessage.msgtype())
    end

    test "creates a reader with ready callback" do
      %{channel: channel} = setup_channel()
      test_pid = self()
      callback = fn bytes -> send(test_pid, {:ready, bytes}) end
      {reader, channel} = Buffer.create_reader(0, channel, callback)
      assert is_pid(reader)

      # Deliver data and verify callback fires
      msg = StreamDataMessage.new(stream_id: 0, data: "test")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)
      assert_receive {:ready, 4}, 500
    end
  end

  describe "create_writer/2" do
    test "creates a writer for the given stream_id" do
      %{channel: channel} = setup_channel()
      {writer, channel} = Buffer.create_writer(0, channel)
      assert writer.stream_id == 0
      assert Map.has_key?(channel.message_factories, StreamDataMessage.msgtype())
    end
  end

  describe "create_bidirectional_buffer/4" do
    test "creates both reader and writer" do
      %{channel: channel} = setup_channel()
      {reader, writer, channel} = Buffer.create_bidirectional_buffer(0, 1, channel)
      assert is_pid(reader)
      assert writer.stream_id == 1
      assert Map.has_key?(channel.message_factories, StreamDataMessage.msgtype())
    end

    test "creates bidirectional buffer with ready callback" do
      %{channel: channel} = setup_channel()
      test_pid = self()
      callback = fn bytes -> send(test_pid, {:ready, bytes}) end
      {reader, _writer, channel} = Buffer.create_bidirectional_buffer(0, 1, channel, callback)
      assert is_pid(reader)

      msg = StreamDataMessage.new(stream_id: 0, data: "bidir")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      _channel = Channel.receive_raw(channel, envelope_raw)
      assert_receive {:ready, 5}, 500
    end
  end

  describe "read/write roundtrip integration" do
    test "data written to writer can be read from reader" do
      %{channel: channel, outlet: outlet} = setup_channel()

      # Create reader on stream 0 and writer targeting stream 0
      {reader, channel} = Buffer.create_reader(0, channel)
      {writer, channel} = Buffer.create_writer(0, channel)

      # Write data
      {bytes_written, channel} = RawChannelWriter.write(writer, "hello buffer", channel)
      assert bytes_written == 12

      # Get the sent packet and simulate receiving it on the channel
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      assert length(packets) == 1
      [packet] = packets

      # Deliver the packet to mark it delivered
      RNS.Channel.TestOutlet.deliver_packet(outlet, packet.id)
      channel = Channel.packet_delivered(channel, packet)

      # The raw data from the packet is what was sent over the channel
      _channel = Channel.receive_raw(channel, packet.raw)
      Process.sleep(10)

      result = RawChannelReader.read(reader, 20)
      assert result == "hello buffer"
    end

    test "multiple writes accumulate in reader buffer" do
      %{channel: channel, outlet: outlet} = setup_channel()
      {reader, channel} = Buffer.create_reader(0, channel)
      {writer, channel} = Buffer.create_writer(0, channel)

      # Write chunk 1
      {_, channel} = RawChannelWriter.write(writer, "chunk1", channel)
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      packet1 = List.last(packets)
      RNS.Channel.TestOutlet.deliver_packet(outlet, packet1.id)
      channel = Channel.packet_delivered(channel, packet1)
      channel = Channel.receive_raw(channel, packet1.raw)

      # Write chunk 2
      {_, channel} = RawChannelWriter.write(writer, "chunk2", channel)
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      packet2 = List.last(packets)
      RNS.Channel.TestOutlet.deliver_packet(outlet, packet2.id)
      channel = Channel.packet_delivered(channel, packet2)
      _channel = Channel.receive_raw(channel, packet2.raw)
      Process.sleep(10)

      result = RawChannelReader.read(reader, 100)
      assert result == "chunk1chunk2"
    end

    test "eof signal terminates stream" do
      %{channel: channel, outlet: outlet} = setup_channel()
      {reader, channel} = Buffer.create_reader(0, channel)
      {writer, channel} = Buffer.create_writer(0, channel)

      # Write data
      {_, channel} = RawChannelWriter.write(writer, "final", channel)
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      packet1 = List.last(packets)
      RNS.Channel.TestOutlet.deliver_packet(outlet, packet1.id)
      channel = Channel.packet_delivered(channel, packet1)
      channel = Channel.receive_raw(channel, packet1.raw)

      # Send eof
      {_writer, channel} = RawChannelWriter.close(writer, channel)
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      packet2 = List.last(packets)
      RNS.Channel.TestOutlet.deliver_packet(outlet, packet2.id)
      channel = Channel.packet_delivered(channel, packet2)
      _channel = Channel.receive_raw(channel, packet2.raw)
      Process.sleep(10)

      # Read all data
      result = RawChannelReader.read(reader, 100)
      assert result == "final"
      assert RawChannelReader.eof?(reader) == true

      # Subsequent read returns empty
      result2 = RawChannelReader.read(reader, 100)
      assert result2 == <<>>
    end

    test "bidirectional buffer sends and receives on different streams" do
      %{channel: channel, outlet: outlet} = setup_channel()
      {reader, writer, channel} = Buffer.create_bidirectional_buffer(0, 1, channel)

      # Write to stream 1
      {bytes, channel} = RawChannelWriter.write(writer, "to stream 1", channel)
      assert bytes == 11
      packets = RNS.Channel.TestOutlet.get_packets(outlet)
      packet = List.last(packets)

      # Simulate receiving on stream 0 (not stream 1, so reader should receive it)
      msg = StreamDataMessage.new(stream_id: 0, data: "from stream 0")
      packed_msg = StreamDataMessage.pack(msg)

      envelope_raw =
        <<StreamDataMessage.msgtype()::unsigned-big-16, 0::unsigned-big-16,
          byte_size(packed_msg)::unsigned-big-16>> <> packed_msg

      # Deliver the write packet first so channel is ready
      RNS.Channel.TestOutlet.deliver_packet(outlet, packet.id)
      channel = Channel.packet_delivered(channel, packet)

      _channel = Channel.receive_raw(channel, envelope_raw)
      Process.sleep(10)

      result = RawChannelReader.read(reader, 50)
      assert result == "from stream 0"
    end
  end
end
