##########################################################
# This RNS example demonstrates how to set up a link to  #
# a destination, and pass data back and forth over it.   #
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

defmodule Link.Server do
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
        ["linkexample"]
      )

    # We configure a function that will get called every time
    # a new client creates a link to this destination.
    server_destination =
      RNS.Destination.set_link_established_callback(server_destination, fn link ->
        RNS.log("Client connected")

        link =
          link
          |> RNS.Link.set_link_closed_callback(fn _link ->
            RNS.log("Client disconnected")
          end)
          |> RNS.Link.set_packet_callback(fn message, _packet ->
            text = message

            RNS.log("Received data on the link: " <> text)

            reply_text = "I received \"" <> text <> "\" over the link"
            RNS.Packet.new(link, reply_text) |> RNS.Packet.send()
          end)

        link
      end)

    # Everything's ready!
    # Let's wait for client requests or user input
    server_loop(server_destination)
  end

  defp server_loop(destination) do
    RNS.log(
      "Link example " <>
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

defmodule Link.Client do
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
        ["linkexample"]
      )

    # And create a link
    link = RNS.Link.new()

    # We set a callback that will get executed
    # every time a packet is received over the
    # link
    link =
      link
      |> RNS.Link.set_packet_callback(fn message, _packet ->
        RNS.log("Received data on the link: " <> message)
        IO.write("> ")
      end)
      |> RNS.Link.set_link_established_callback(fn _link ->
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
        data = text
        mdu = RNS.Link.mdu()

        if byte_size(data) <= mdu do
          RNS.Packet.new(link, data) |> RNS.Packet.send()
        else
          RNS.log(
            "Cannot send this packet, the data size of " <>
              "#{byte_size(data)} bytes exceeds the link packet MDU of " <>
              "#{mdu} bytes",
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
    Link.Server.run(opts[:config])

  length(args) > 0 ->
    [destination_hexhash | _] = args
    Link.Client.run(destination_hexhash, opts[:config])

  true ->
    IO.puts("")
    IO.puts("Usage: mix run examples/link.exs [-s | --server] [--config PATH] [DESTINATION_HASH]")
    IO.puts("")
end
