##########################################################
# This RNS example demonstrates how to set up a link to  #
# a destination, and pass structured messages over it    #
# using a channel.                                       #
##########################################################

# Parse command-line arguments
{opts, args, _} =
  OptionParser.parse(System.argv(),
    strict: [server: :boolean, config: :string]
  )

app_name = "example_utilities"

##########################################################
#### Shared Objects ######################################
##########################################################

# Channel data must be structured in a module that implements
# the RNS.Channel.MessageBase behaviour. This ensures that the
# channel will be able to serialize and deserialize the object
# and multiplex it with other objects. Both ends of a link will
# need the same object definitions to be able to communicate
# over a channel.
#
# Note: The objects we wish to use over the channel must
# be registered with the channel, and each link has a
# different channel instance.

# Let's make a simple message module called StringMessage
# that will convey a string with a timestamp.

defmodule StringMessage do
  @behaviour RNS.Channel.MessageBase

  # The MSGTYPE needs to be assigned a 2 byte integer value.
  # This identifier allows the channel to look up your message's
  # constructor when a message arrives over the channel.
  #
  # MSGTYPE must be unique across all message types we
  # register with the channel. MSGTYPEs >= 0xf000 are
  # reserved for the system.
  @msgtype 0x0101

  defstruct [:data, :timestamp]

  @impl true
  def msgtype, do: @msgtype

  @impl true
  def new, do: %__MODULE__{data: nil, timestamp: DateTime.utc_now()}

  # The pack function encodes the message contents into
  # a byte stream.
  @impl true
  def pack(%__MODULE__{data: data, timestamp: timestamp}) do
    Msgpax.pack!([data, DateTime.to_iso8601(timestamp)]) |> IO.iodata_to_binary()
  end

  # And the unpack function decodes a byte stream into
  # the message contents.
  @impl true
  def unpack(%__MODULE__{} = msg, raw) do
    [data, timestamp_str] = Msgpax.unpack!(raw)
    {:ok, timestamp, _} = DateTime.from_iso8601(timestamp_str)
    %{msg | data: data, timestamp: timestamp}
  end
end

##########################################################
#### Server Part #########################################
##########################################################

defmodule Channel.Server do
  def run(configpath) do
    # We must first initialise Reticulum
    RNS.Reticulum.start_link(configdir: configpath)

    # Randomly create a new identity for our link example
    server_identity = RNS.Identity.new()

    # We create a destination that clients can connect to. We
    # want clients to create links to this destination, so we
    # need to create a "single" destination type.
    server_destination =
      RNS.Destination.new(
        server_identity,
        RNS.Destination.direction_in(),
        RNS.Destination.single(),
        "example_utilities",
        ["channelexample"]
      )

    # We configure a function that will get called every time
    # a new client creates a link to this destination.
    server_destination =
      RNS.Destination.set_link_established_callback(server_destination, fn link ->
        RNS.log("Client connected")

        link =
          RNS.Link.set_link_closed_callback(link, fn _link ->
            RNS.log("Client disconnected")
          end)

        # Register message types and add callback to channel
        {channel, link} = RNS.Link.channel(link)

        channel =
          channel
          |> RNS.Channel.register_message_type(StringMessage)
          |> RNS.Channel.add_message_handler(fn message ->
            # In a message handler, any deserializable message
            # that arrives over the link's channel will be passed
            # to all message handlers, unless a preceding handler
            # indicates it has handled the message.
            if is_struct(message, StringMessage) do
              RNS.log(
                "Received data on the link: " <>
                  message.data <>
                  " (message created at " <> DateTime.to_string(message.timestamp) <> ")"
              )

              # Send a reply back through the channel
              reply = %StringMessage{
                data: "I received \"" <> message.data <> "\" over the link",
                timestamp: DateTime.utc_now()
              }

              {_channel, _link} = RNS.Channel.send(channel, reply)

              # Returning true indicates the message was handled
              # and subsequent handlers will be skipped
              true
            else
              false
            end
          end)

        {channel, link}
      end)

    # Everything's ready!
    # Let's wait for client requests or user input
    server_loop(server_destination)
  end

  defp server_loop(destination) do
    RNS.log(
      "Channel example " <>
        RNS.prettyhexrep(destination.hash) <>
        " running, waiting for a connection."
    )

    RNS.log("Hit enter to manually send an announce (Ctrl-C to quit)")

    do_loop(destination)
  end

  defp do_loop(destination) do
    IO.gets("")
    {_receipt, destination} = RNS.Destination.announce(destination)
    RNS.log("Sent announce from " <> RNS.prettyhexrep(destination.hash))
    do_loop(destination)
  end
end

##########################################################
#### Client Part #########################################
##########################################################

defmodule Channel.Client do
  def run(destination_hexhash, configpath) do
    # We need a binary representation of the destination
    # hash that was entered on the command line
    dest_len = div(RNS.Reticulum.truncated_hashlength(), 8) * 2

    if String.length(destination_hexhash) != dest_len do
      RNS.log(
        "Destination length is invalid, must be #{dest_len} hexadecimal characters (#{div(dest_len, 2)} bytes)."
      )

      System.halt(0)
    end

    destination_hash =
      case Base.decode16(destination_hexhash, case: :mixed) do
        {:ok, hash} ->
          hash

        :error ->
          RNS.log("Invalid destination entered. Check your input!")
          System.halt(0)
      end

    # We must first initialise Reticulum
    RNS.Reticulum.start_link(configdir: configpath)

    # Check if we know a path to the destination
    unless RNS.Transport.has_path(destination_hash) do
      RNS.log(
        "Destination is not yet known. Requesting path and waiting for announce to arrive..."
      )

      RNS.Transport.request_path(destination_hash)

      wait_for_path(destination_hash)
    end

    # Recall the server identity
    server_identity = RNS.Identity.recall(destination_hash)

    # Inform the user that we'll begin connecting
    RNS.log("Establishing link with server...")

    # When the server identity is known, we set
    # up a destination
    server_destination =
      RNS.Destination.new(
        server_identity,
        RNS.Destination.direction_out(),
        RNS.Destination.single(),
        "example_utilities",
        ["channelexample"]
      )

    # And create a link
    link = RNS.Link.new()

    # We'll set up functions to inform the user when
    # the link is established or closed
    link =
      link
      |> RNS.Link.set_link_established_callback(fn link ->
        # Register messages and add handler to channel
        {channel, _link} = RNS.Link.channel(link)

        channel
        |> RNS.Channel.register_message_type(StringMessage)
        |> RNS.Channel.add_message_handler(fn message ->
          if is_struct(message, StringMessage) do
            RNS.log(
              "Received data on the link: " <>
                message.data <>
                " (message created at " <> DateTime.to_string(message.timestamp) <> ")"
            )

            IO.write("> ")
            true
          else
            false
          end
        end)

        RNS.log("Link established with server, enter some text to send, or \"quit\" to quit")
      end)
      |> RNS.Link.set_link_closed_callback(fn link ->
        cond do
          link.teardown_reason == RNS.Link.timeout() ->
            RNS.log("The link timed out, exiting now")

          link.teardown_reason == RNS.Link.destination_closed() ->
            RNS.log("The link was closed by the server, exiting now")

          true ->
            RNS.log("Link closed, exiting now")
        end

        Process.sleep(1500)
        System.halt(0)
      end)

    # Everything is set up, so let's enter a loop
    # for the user to interact with the example
    client_loop(link, server_destination)
  end

  defp wait_for_path(destination_hash) do
    unless RNS.Transport.has_path(destination_hash) do
      Process.sleep(100)
      wait_for_path(destination_hash)
    end
  end

  defp client_loop(link, _destination) do
    IO.write("> ")
    text = IO.gets("") |> String.trim()

    cond do
      text in ["quit", "q", "exit"] ->
        RNS.Link.teardown(link)

      text != "" ->
        message = %StringMessage{data: text, timestamp: DateTime.utc_now()}
        packed_size = byte_size(StringMessage.pack(message))

        {channel, link} = RNS.Link.channel(link)

        if RNS.Channel.ready_to_send?(channel) do
          channel_mdu = RNS.Channel.mdu(channel)

          if packed_size <= channel_mdu do
            {_channel, _link} = RNS.Channel.send(channel, message)
          else
            RNS.log(
              "Cannot send this packet, the data size of " <>
                "#{packed_size} bytes exceeds the channel MDU of " <>
                "#{channel_mdu} bytes",
              :error
            )
          end
        else
          RNS.log(
            "Channel is not ready to send, please wait for pending messages to complete.",
            :error
          )
        end

        client_loop(link, _destination)

      true ->
        client_loop(link, _destination)
    end
  end
end

##########################################################
#### Program Startup #####################################
##########################################################

cond do
  opts[:server] ->
    Channel.Server.run(opts[:config])

  length(args) > 0 ->
    [destination_hexhash | _] = args
    Channel.Client.run(destination_hexhash, opts[:config])

  true ->
    IO.puts("")

    IO.puts(
      "Usage: mix run examples/channel.exs [-s | --server] [--config PATH] [DESTINATION_HASH]"
    )

    IO.puts("")
end
