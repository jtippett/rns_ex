defmodule RNS.Buffer.StreamDataMessage do
  @moduledoc """
  Message type for `Channel`. `StreamDataMessage` uses a system-reserved
  message type to transport binary stream data over a Channel.

  Matches `python/RNS/Buffer.py` StreamDataMessage class.
  """

  @behaviour RNS.Channel.MessageBase

  import Bitwise

  @smt_stream_data 0xFF00
  @stream_id_max 0x3FFF
  @overhead 2 + 6

  defstruct stream_id: nil, data: <<>>, eof: false, compressed: false

  @type t :: %__MODULE__{
          stream_id: non_neg_integer() | nil,
          data: binary(),
          eof: boolean(),
          compressed: boolean()
        }

  @doc "System message type identifier: 0xFF00"
  @impl true
  @spec msgtype() :: non_neg_integer()
  def msgtype, do: @smt_stream_data

  @doc "Maximum stream ID value (0x3FFF = 16383)"
  @spec stream_id_max() :: non_neg_integer()
  def stream_id_max, do: @stream_id_max

  @doc "Overhead in bytes (2 header + 6 channel envelope)"
  @spec overhead() :: non_neg_integer()
  def overhead, do: @overhead

  @doc "Maximum data length per message"
  @spec max_data_len() :: non_neg_integer()
  def max_data_len, do: RNS.Link.mdu() - @overhead

  @doc "Create a default StreamDataMessage with no arguments."
  @impl true
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Create a StreamDataMessage with options.

  ## Options

    * `:stream_id` - stream identifier (0 to 16383)
    * `:data` - binary data to send (default: `<<>>`)
    * `:eof` - end-of-file flag (default: `false`)
    * `:compressed` - compressed flag (default: `false`)

  Raises `ArgumentError` if `stream_id` exceeds `STREAM_ID_MAX`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    stream_id = Keyword.get(opts, :stream_id)
    data = Keyword.get(opts, :data, <<>>)
    eof = Keyword.get(opts, :eof, false)
    compressed = Keyword.get(opts, :compressed, false)

    if stream_id != nil and stream_id > @stream_id_max do
      raise ArgumentError, "stream_id must be 0-#{@stream_id_max}"
    end

    %__MODULE__{stream_id: stream_id, data: data, eof: eof, compressed: compressed}
  end

  @doc "Pack the message into its binary representation."
  @impl true
  @spec pack(t()) :: binary()
  def pack(%__MODULE__{stream_id: nil}) do
    raise ArgumentError, "stream_id is required"
  end

  def pack(%__MODULE__{} = msg) do
    header_val =
      (0x3FFF &&& msg.stream_id) |||
        if(msg.eof, do: 0x8000, else: 0x0000) |||
        if(msg.compressed, do: 0x4000, else: 0x0000)

    <<header_val::unsigned-big-16>> <> (msg.data || <<>>)
  end

  @doc "Populate a message from binary representation."
  @impl true
  @spec unpack(t(), binary()) :: t()
  def unpack(%__MODULE__{}, raw) do
    <<header::unsigned-big-16, data::binary>> = raw
    eof = (header &&& 0x8000) > 0
    compressed = (header &&& 0x4000) > 0
    stream_id = header &&& 0x3FFF

    data =
      if compressed and byte_size(data) > 0 do
        :zlib.uncompress(data)
      else
        data
      end

    %__MODULE__{stream_id: stream_id, data: data, eof: eof, compressed: compressed}
  end
end

defmodule RNS.Buffer.RawChannelReader do
  @moduledoc """
  Receives binary stream data sent over a `Channel`.

  Uses an Agent to hold the internal buffer, allowing data to be
  accumulated from channel message callbacks and read by the consumer.

  Matches `python/RNS/Buffer.py` RawChannelReader class.
  """

  alias RNS.Buffer.StreamDataMessage
  alias RNS.Channel

  @doc """
  Create a raw channel reader.

  Registers the `StreamDataMessage` system message type on the channel
  and adds a message handler that accumulates incoming data.

  Returns `{reader_pid, updated_channel}`.
  """
  @spec new(non_neg_integer(), Channel.t()) :: {pid(), Channel.t()}
  def new(stream_id, %Channel{} = channel) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{buffer: <<>>, eof: false, listeners: []}
      end)

    handler = build_handler(stream_id, agent)
    channel = Channel.register_system_message_type(channel, StreamDataMessage)
    channel = Channel.add_message_handler(channel, handler)

    {agent, channel}
  end

  @doc """
  Read up to `size` bytes from the buffer.

  Returns:
    - `nil` if the buffer is empty and EOF has not been reached
    - `<<>>` (empty binary) if the buffer is empty and EOF has been reached
    - binary data (up to `size` bytes) if data is available
  """
  @spec read(pid(), non_neg_integer()) :: binary() | nil
  def read(agent, size) do
    Agent.get_and_update(agent, fn state ->
      result = binary_part(state.buffer, 0, min(size, byte_size(state.buffer)))

      remaining =
        binary_part(state.buffer, byte_size(result), byte_size(state.buffer) - byte_size(result))

      if byte_size(result) > 0 do
        {result, %{state | buffer: remaining}}
      else
        if state.eof do
          {<<>>, state}
        else
          {nil, state}
        end
      end
    end)
  end

  @doc """
  Add a callback to be invoked when new data is available.

  Callback signature: `(ready_bytes :: non_neg_integer()) -> any()`
  """
  @spec add_ready_callback(pid(), function()) :: :ok
  def add_ready_callback(agent, callback) do
    Agent.update(agent, fn state ->
      %{state | listeners: state.listeners ++ [callback]}
    end)
  end

  @doc """
  Remove a previously added ready callback.
  """
  @spec remove_ready_callback(pid(), function()) :: :ok
  def remove_ready_callback(agent, callback) do
    Agent.update(agent, fn state ->
      %{state | listeners: List.delete(state.listeners, callback)}
    end)
  end

  @doc """
  Check if the end-of-file has been received.
  """
  @spec is_eof(pid()) :: boolean()
  def is_eof(agent) do
    Agent.get(agent, fn state -> state.eof end)
  end

  @doc """
  Close the reader, stopping the underlying agent.
  """
  @spec close(pid()) :: :ok
  def close(agent) do
    Agent.stop(agent)
  end

  defp build_handler(stream_id, agent) do
    fn message ->
      if is_struct(message, StreamDataMessage) and message.stream_id == stream_id do
        Agent.update(agent, fn state ->
          buffer =
            if message.data != nil do
              state.buffer <> message.data
            else
              state.buffer
            end

          eof = if message.eof, do: true, else: state.eof
          new_state = %{state | buffer: buffer, eof: eof}

          # Notify listeners
          Enum.each(new_state.listeners, fn listener ->
            try do
              Task.start(fn -> listener.(byte_size(buffer)) end)
            rescue
              e ->
                RNS.Log.log(
                  "Error calling RawChannelReader(#{stream_id}) callback: #{inspect(e)}",
                  :error
                )
            end
          end)

          new_state
        end)

        true
      else
        false
      end
    end
  end
end

defmodule RNS.Buffer.RawChannelWriter do
  @moduledoc """
  Writes binary stream data over a `Channel`.

  Handles chunking, optional compression, and EOF signaling.

  Matches `python/RNS/Buffer.py` RawChannelWriter class.
  """

  alias RNS.Buffer.StreamDataMessage
  alias RNS.Channel

  @max_chunk_len 1024 * 16
  @compression_tries 4

  defstruct [:stream_id, eof: false]

  @type t :: %__MODULE__{
          stream_id: non_neg_integer(),
          eof: boolean()
        }

  @doc "Maximum chunk length for a single write"
  @spec max_chunk_len() :: non_neg_integer()
  def max_chunk_len, do: @max_chunk_len

  @doc "Number of compression attempts"
  @spec compression_tries() :: non_neg_integer()
  def compression_tries, do: @compression_tries

  @doc """
  Create a raw channel writer.

  ## Parameters

    * `stream_id` - the remote stream ID to send to
    * `channel` - the channel to send on
  """
  @spec new(non_neg_integer(), Channel.t()) :: t()
  def new(stream_id, %Channel{} = _channel) do
    %__MODULE__{stream_id: stream_id}
  end

  @doc """
  Write binary data over the channel.

  Attempts compression if the data is large enough. Truncates
  data exceeding `MAX_CHUNK_LEN`.

  Returns `{bytes_written, updated_channel}`.
  """
  @spec write(t(), binary(), Channel.t()) :: {non_neg_integer(), Channel.t()}
  def write(%__MODULE__{} = writer, data, %Channel{} = channel) do
    try do
      max_data_len = StreamDataMessage.max_data_len()
      chunk_len = byte_size(data)

      {data, chunk_len} =
        if chunk_len > @max_chunk_len do
          {binary_part(data, 0, @max_chunk_len), @max_chunk_len}
        else
          {data, chunk_len}
        end

      {comp_success, compressed_chunk, chunk_segment_length} =
        try_compress(data, chunk_len, max_data_len)

      {chunk, processed_length} =
        if comp_success do
          {compressed_chunk, chunk_segment_length}
        else
          actual_len = min(byte_size(data), max_data_len)
          {binary_part(data, 0, actual_len), actual_len}
        end

      message =
        StreamDataMessage.new(
          stream_id: writer.stream_id,
          data: chunk,
          eof: writer.eof,
          compressed: comp_success
        )

      {:ok, channel, _envelope} = Channel.send(channel, message)
      {processed_length, channel}
    rescue
      e in Channel.ChannelException ->
        if e.type != Channel.me_link_not_ready() do
          reraise e, __STACKTRACE__
        end

        {0, channel}
    end
  end

  @doc """
  Close the writer by sending an EOF message.

  Returns `{updated_writer, updated_channel}`.
  """
  @spec close(t(), Channel.t()) :: {t(), Channel.t()}
  def close(%__MODULE__{} = writer, %Channel{} = channel) do
    writer = %{writer | eof: true}

    message =
      StreamDataMessage.new(
        stream_id: writer.stream_id,
        data: <<>>,
        eof: true
      )

    case Channel.send(channel, message) do
      {:ok, channel, _envelope} ->
        {writer, channel}

      _ ->
        {writer, channel}
    end
  end

  defp try_compress(data, chunk_len, max_data_len) do
    if chunk_len <= 32 do
      {false, nil, 0}
    else
      do_try_compress(data, chunk_len, max_data_len, 1, @compression_tries)
    end
  end

  defp do_try_compress(_data, _chunk_len, _max_data_len, comp_try, comp_tries)
       when comp_try >= comp_tries do
    {false, nil, 0}
  end

  defp do_try_compress(data, chunk_len, max_data_len, comp_try, comp_tries) do
    chunk_segment_length = div(chunk_len, comp_try)

    if chunk_segment_length <= 0 do
      {false, nil, 0}
    else
      segment = binary_part(data, 0, chunk_segment_length)
      compressed_chunk = :zlib.compress(segment)
      compressed_length = byte_size(compressed_chunk)

      if compressed_length < max_data_len and compressed_length < chunk_segment_length do
        {true, compressed_chunk, chunk_segment_length}
      else
        do_try_compress(data, chunk_len, max_data_len, comp_try + 1, comp_tries)
      end
    end
  end
end

defmodule RNS.Buffer do
  @moduledoc """
  Provides factory functions for creating buffered streams that send
  and receive binary data over a `Channel`.

  Matches `python/RNS/Buffer.py` Buffer class.
  """

  alias RNS.Buffer.{StreamDataMessage, RawChannelReader, RawChannelWriter}
  alias RNS.Channel

  @doc """
  Create a reader that receives binary data sent over a `Channel`,
  with an optional callback when new data is available.

  Callback signature: `(ready_bytes :: non_neg_integer()) -> any()`

  Returns `{reader_pid, updated_channel}`.
  """
  @spec create_reader(non_neg_integer(), Channel.t(), function() | nil) :: {pid(), Channel.t()}
  def create_reader(stream_id, %Channel{} = channel, ready_callback \\ nil) do
    {reader, channel} = RawChannelReader.new(stream_id, channel)

    if ready_callback do
      RawChannelReader.add_ready_callback(reader, ready_callback)
    end

    {reader, channel}
  end

  @doc """
  Create a writer that writes binary data over a `Channel`.

  Returns `{writer, updated_channel}`.
  """
  @spec create_writer(non_neg_integer(), Channel.t()) :: {RawChannelWriter.t(), Channel.t()}
  def create_writer(stream_id, %Channel{} = channel) do
    channel = Channel.register_system_message_type(channel, StreamDataMessage)
    writer = RawChannelWriter.new(stream_id, channel)
    {writer, channel}
  end

  @doc """
  Create a bidirectional reader/writer pair over a `Channel`,
  with an optional callback when new data is available on the reader.

  Callback signature: `(ready_bytes :: non_neg_integer()) -> any()`

  Returns `{reader_pid, writer, updated_channel}`.
  """
  @spec create_bidirectional_buffer(
          non_neg_integer(),
          non_neg_integer(),
          Channel.t(),
          function() | nil
        ) :: {pid(), RawChannelWriter.t(), Channel.t()}
  def create_bidirectional_buffer(
        receive_stream_id,
        send_stream_id,
        %Channel{} = channel,
        ready_callback \\ nil
      ) do
    {reader, channel} = RawChannelReader.new(receive_stream_id, channel)

    if ready_callback do
      RawChannelReader.add_ready_callback(reader, ready_callback)
    end

    writer = RawChannelWriter.new(send_stream_id, channel)

    {reader, writer, channel}
  end
end
