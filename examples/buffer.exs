##########################################################
# This RNS example demonstrates how to set up a link to  #
# a destination, and pass binary data over it using a    #
# channel buffer.                                        #
##########################################################

# Parse command-line arguments
{opts, args, _} =
  OptionParser.parse(System.argv(),
    strict: [server: :boolean, config: :string]
  )

app_name = "example_utilities"

##########################################################
#### Server Part #########################################
##########################################################

defmodule Buffer.Server do
  def run(configpath) do
    # We must first initialise Reticulum
    RNS.Reticulum.start_link(configdir: configpath)

    # Randomly create a new identity for our example
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
        ["bufferexample"]
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

        # Create buffer objects.
        #   The stream_id parameter to these functions is
        #   a bit like a file descriptor, except that it
        #   is unique to the *receiver*.
        #
        #   In this example, both the reader and the writer
        #   use stream_id = 0, but there are actually two
        #   separate unidirectional streams flowing in
        #   opposite directions.
        {channel, link} = RNS.Link.channel(link)

        {reader, writer, channel} =
          RNS.Buffer.create_bidirectional_buffer(0, 0, channel, fn ready_bytes ->
            # Callback from buffer when buffer has data available
            data = RNS.Buffer.RawChannelReader.read(reader, ready_bytes)

            if data do
              text = data

              RNS.log("Received data over the buffer: " <> text)

              reply = "I received \"" <> text <> "\" over the buffer"
              RNS.Buffer.RawChannelWriter.write(writer, reply, channel)
            end
          end)

        {reader, writer, channel, link}
      end)

    # Everything's ready!
    # Let's wait for client requests or user input
    server_loop(server_destination)
  end

  defp server_loop(destination) do
    RNS.log(
      "Link buffer example " <>
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

defmodule Buffer.Client do
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
        ["bufferexample"]
      )

    # And create a link
    link = RNS.Link.new()

    # We'll set up functions to inform the user when
    # the link is established or closed
    link =
      link
      |> RNS.Link.set_link_established_callback(fn link ->
        # Create buffer, see server client_connected callback
        # for more detail about setting up the buffer.
        {channel, _link} = RNS.Link.channel(link)

        {_reader, _writer, _channel} =
          RNS.Buffer.create_bidirectional_buffer(0, 0, channel, fn ready_bytes ->
            # When the buffer has new data, read it and write it to the terminal
            data = RNS.Buffer.RawChannelReader.read(_reader, ready_bytes)

            if data do
              RNS.log("Received data over the link buffer: " <> data)
              IO.write("> ")
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
        # In a full implementation, the writer and channel
        # would be stored in process state. Here we show
        # the API pattern:
        {channel, link} = RNS.Link.channel(link)
        {writer, channel} = RNS.Buffer.create_writer(0, channel)
        RNS.Buffer.RawChannelWriter.write(writer, text, channel)

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
    Buffer.Server.run(opts[:config])

  length(args) > 0 ->
    [destination_hexhash | _] = args
    Buffer.Client.run(destination_hexhash, opts[:config])

  true ->
    IO.puts("")

    IO.puts(
      "Usage: mix run examples/buffer.exs [-s | --server] [--config PATH] [DESTINATION_HASH]"
    )

    IO.puts("")
end
