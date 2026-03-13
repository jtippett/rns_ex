##########################################################
# This RNS example demonstrates a simple client/server   #
# echo utility. A client can send an echo request to the #
# server, and the server will respond by proving receipt #
# of the packet.                                         #
##########################################################

# Parse command-line arguments
{opts, args, _} =
  OptionParser.parse(System.argv(),
    strict: [server: :boolean, timeout: :float, config: :string]
  )

app_name = "example_utilities"

##########################################################
#### Server Part #########################################
##########################################################

defmodule Echo.Server do
  def run(configpath) do
    # We must first initialise Reticulum
    RNS.Reticulum.start_link(configdir: configpath)

    # Randomly create a new identity for our echo server
    server_identity = RNS.Identity.new()

    # We create a destination that clients can query. We want
    # to be able to verify echo replies to our clients, so we
    # create a "single" destination that can receive encrypted
    # messages. This way the client can send a request and be
    # certain that no-one else than this destination was able
    # to read it.
    echo_destination =
      RNS.Destination.new(
        server_identity,
        RNS.Destination.direction_in(),
        RNS.Destination.single(),
        "example_utilities",
        ["echo", "request"]
      )

    # We configure the destination to automatically prove all
    # packets addressed to it. By doing this, RNS will automatically
    # generate a proof for each incoming packet and transmit it
    # back to the sender of that packet.
    echo_destination =
      RNS.Destination.set_proof_strategy(echo_destination, RNS.Destination.prove_all())

    # Tell the destination which function in our program to
    # run when a packet is received. We do this so we can
    # print a log message when the server receives a request
    echo_destination =
      RNS.Destination.set_packet_callback(echo_destination, fn _message, packet ->
        reception_stats =
          [
            if(packet.rssi, do: " [RSSI #{packet.rssi} dBm]", else: ""),
            if(packet.snr, do: " [SNR #{packet.snr} dB]", else: "")
          ]
          |> Enum.join()

        RNS.log("Received packet from echo client, proof sent" <> reception_stats)
      end)

    # Everything's ready!
    # Let's wait for client requests or user input
    announce_loop(echo_destination)
  end

  defp announce_loop(destination) do
    # Let the user know that everything is ready
    RNS.log(
      "Echo server " <>
        RNS.prettyhexrep(destination.hash) <>
        " running, hit enter to manually send an announce (Ctrl-C to quit)"
    )

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

defmodule Echo.Client do
  def run(destination_hexhash, configpath, timeout) do
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

    # Tell the user that the client is ready!
    RNS.log(
      "Echo client ready, hit enter to send echo request to " <>
        destination_hexhash <>
        " (Ctrl-C to quit)"
    )

    # We enter a loop that runs until the user exits.
    # If the user hits enter, we will try to send an
    # echo request to the destination specified on the
    # command line.
    do_loop(destination_hash, timeout)
  end

  defp do_loop(destination_hash, timeout) do
    IO.gets("")

    # Let's first check if RNS knows a path to the destination.
    # If it does, we'll load the server identity and create a packet
    if RNS.Transport.has_path(destination_hash) do
      # To address the server, we need to know its public
      # key, so we check if Reticulum knows this destination.
      server_identity = RNS.Identity.recall(destination_hash)

      # We got the correct identity instance from the
      # recall method, so let's create an outgoing destination.
      request_destination =
        RNS.Destination.new(
          server_identity,
          RNS.Destination.direction_out(),
          RNS.Destination.single(),
          "example_utilities",
          ["echo", "request"]
        )

      # The destination is ready, so let's create a packet.
      # We set the destination to the request_destination
      # that was just created, and the only data we add
      # is a random hash.
      echo_request = RNS.Packet.new(request_destination, RNS.Identity.random_hash())

      # Send the packet! If the packet is successfully
      # sent, it will return a PacketReceipt instance.
      packet_receipt = RNS.Packet.send(echo_request)

      # If the user specified a timeout, we set this
      # timeout on the packet receipt, and configure
      # a callback function, that will get called if
      # the packet times out.
      packet_receipt =
        if timeout do
          packet_receipt
          |> RNS.PacketReceipt.set_timeout(timeout)
          |> RNS.PacketReceipt.set_timeout_callback(fn receipt ->
            if RNS.PacketReceipt.status(receipt) == RNS.PacketReceipt.failed() do
              RNS.log("Packet " <> RNS.prettyhexrep(receipt.hash) <> " timed out")
            end
          end)
        else
          packet_receipt
        end

      # We can then set a delivery callback on the receipt.
      # This will get automatically called when a proof for
      # this specific packet is received from the destination.
      RNS.PacketReceipt.set_delivery_callback(packet_receipt, fn receipt ->
        if RNS.PacketReceipt.status(receipt) == RNS.PacketReceipt.delivered() do
          rtt = RNS.PacketReceipt.rtt(receipt)

          rttstring =
            if rtt >= 1 do
              "#{Float.round(rtt / 1.0, 3)} seconds"
            else
              "#{Float.round(rtt * 1000.0, 3)} milliseconds"
            end

          reception_stats =
            if receipt.proof_packet do
              [
                if(receipt.proof_packet.rssi,
                  do: " [RSSI #{receipt.proof_packet.rssi} dBm]",
                  else: ""
                ),
                if(receipt.proof_packet.snr,
                  do: " [SNR #{receipt.proof_packet.snr} dB]",
                  else: ""
                )
              ]
              |> Enum.join()
            else
              ""
            end

          RNS.log(
            "Valid reply received from " <>
              RNS.prettyhexrep(receipt.destination.hash) <>
              ", round-trip time is " <> rttstring <> reception_stats
          )
        end
      end)

      # Tell the user that the echo request was sent
      RNS.log("Sent echo request to " <> RNS.prettyhexrep(request_destination.hash))
    else
      # If we do not know this destination, tell the
      # user to wait for an announce to arrive.
      RNS.log("Destination is not yet known. Requesting path...")
      RNS.log("Hit enter to manually retry once an announce is received.")
      RNS.Transport.request_path(destination_hash)
    end

    do_loop(destination_hash, timeout)
  end
end

##########################################################
#### Program Startup #####################################
##########################################################

cond do
  opts[:server] ->
    Echo.Server.run(opts[:config])

  length(args) > 0 ->
    [destination_hexhash | _] = args
    Echo.Client.run(destination_hexhash, opts[:config], opts[:timeout])

  true ->
    IO.puts("")
    IO.puts("Usage: mix run examples/echo.exs [-s | --server] [--timeout SECONDS] [--config PATH] [DESTINATION_HASH]")
    IO.puts("")
end
