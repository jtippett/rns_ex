##########################################################
# This RNS example demonstrates a simple speedtest       #
# program to measure link throughput.                    #
#                                                        #
# The current configuration is suited for testing fast   #
# links. If you want to measure slow links like LoRa or  #
# packet radio, you must significantly lower the         #
# data_cap variable, which defines how much data is sent #
# for each test.                                         #
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

defmodule Speedtest.Server do
  @data_cap 2 * 1024 * 1024

  def run(configpath) do
    # We must first initialise Reticulum
    RNS.Reticulum.start_link(configdir: configpath)

    # Randomly create a new identity for our speedtest
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
        ["speedtest"]
      )

    # We configure a function that will get called every time
    # a new client creates a link to this destination.
    server_destination =
      RNS.Destination.set_link_established_callback(server_destination, fn link ->
        RNS.log("Client connected")

        # Reset state for this connection
        Process.put(:first_packet_at, System.monotonic_time(:millisecond))
        Process.put(:received_data, 0)
        Process.put(:rc, 0)

        link
        |> RNS.Link.set_link_closed_callback(fn _link ->
          RNS.log("Client disconnected")
        end)
        |> RNS.Link.set_packet_callback(fn _message, packet ->
          received_data = Process.get(:received_data, 0) + byte_size(packet.data)
          rc = Process.get(:rc, 0) + 1
          Process.put(:received_data, received_data)

          if rc >= 50 do
            RNS.log(size_str(received_data))
            Process.put(:rc, 0)
          else
            Process.put(:rc, rc)
          end

          if received_data > @data_cap do
            last_packet_at = System.monotonic_time(:millisecond)
            first_packet_at = Process.get(:first_packet_at)
            download_time = (last_packet_at - first_packet_at) / 1000.0

            print_statistics(received_data, download_time)

            # Reset
            Process.put(:received_data, 0)
            Process.put(:rc, 0)

            RNS.Link.teardown(packet.link)
          end
        end)
      end)

    # Everything's ready!
    server_loop(server_destination)
  end

  defp server_loop(destination) do
    RNS.log(
      "Speedtest " <>
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

  defp print_statistics(data_transferred, download_time) do
    hours = trunc(download_time / 3600)
    rem_time = download_time - hours * 3600
    minutes = trunc(rem_time / 60)
    seconds = rem_time - minutes * 60

    timestring =
      :io_lib.format("~2..0B:~2..0B:~5.2.0f", [hours, minutes, seconds])
      |> IO.iodata_to_binary()

    IO.puts("")
    IO.puts("")
    IO.puts("--- Statistics -----")
    IO.puts("\tTime taken       : #{timestring}")
    IO.puts("\tData transferred : #{size_str(data_transferred)}")

    if download_time > 0 do
      IO.puts("\tTransfer rate    : #{size_str(data_transferred / download_time, "b")}/s")
    end

    IO.puts("")
  end

  defp size_str(num, suffix \\ "B") do
    {num, units, last_unit} =
      if suffix == "b" do
        {num * 8, ["", "K", "M", "G", "T", "P", "E", "Z"], "Y"}
      else
        {num, ["", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi"], "Yi"}
      end

    do_size_str(num / 1, units, last_unit, suffix)
  end

  defp do_size_str(num, [unit], _last_unit, suffix) do
    :io_lib.format("~.2f ~s~s", [num, unit, suffix]) |> IO.iodata_to_binary()
  end

  defp do_size_str(num, [unit | rest], last_unit, suffix) do
    if abs(num) < 1024.0 do
      :io_lib.format("~.2f ~s~s", [num, unit, suffix]) |> IO.iodata_to_binary()
    else
      do_size_str(num / 1024.0, rest, last_unit, suffix)
    end
  end
end

##########################################################
#### Client Part #########################################
##########################################################

defmodule Speedtest.Client do
  @data_cap 2 * 1024 * 1024

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
        ["speedtest"]
      )

    # And create a link
    link = RNS.Link.new()

    # We'll set up functions to inform the
    # user when the link is established or closed
    link =
      link
      |> RNS.Link.set_link_established_callback(fn link ->
        Process.put(:server_link, link)

        RNS.log("Link established with server, sending...")

        # Generate random data of MDU size
        rd = :crypto.strong_rand_bytes(RNS.Link.mdu())
        started = System.monotonic_time(:millisecond)
        printed = send_data(link, rd, 0, started, false)
        _ = printed
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
    client_loop()
  end

  defp wait_for_path(destination_hash) do
    unless RNS.Transport.has_path(destination_hash) do
      Process.sleep(100)
      wait_for_path(destination_hash)
    end
  end

  defp send_data(link, rd, data_sent, started, printed) do
    if link.status == RNS.Link.active() and data_sent < @data_cap * 1.25 do
      RNS.Packet.new(link, rd, create_receipt: false) |> RNS.Packet.send()
      data_sent = data_sent + byte_size(rd)

      printed =
        if data_sent > @data_cap and not printed do
          ended = System.monotonic_time(:millisecond)
          download_time = (ended - started) / 1000.0
          print_statistics(data_sent, download_time)
          Process.sleep(100)
          true
        else
          printed
        end

      send_data(link, rd, data_sent, started, printed)
    else
      printed
    end
  end

  defp print_statistics(data_transferred, download_time) do
    hours = trunc(download_time / 3600)
    rem_time = download_time - hours * 3600
    minutes = trunc(rem_time / 60)
    seconds = rem_time - minutes * 60

    timestring =
      :io_lib.format("~2..0B:~2..0B:~5.2.0f", [hours, minutes, seconds])
      |> IO.iodata_to_binary()

    IO.puts("")
    IO.puts("")
    IO.puts("--- Statistics -----")
    IO.puts("\tTime taken       : #{timestring}")
    IO.puts("\tData transferred : #{size_str(data_transferred)}")

    if download_time > 0 do
      IO.puts("\tTransfer rate    : #{size_str(data_transferred / download_time, "b")}/s")
    end

    IO.puts("")
  end

  defp size_str(num, suffix \\ "B") do
    {num, units, last_unit} =
      if suffix == "b" do
        {num * 8, ["", "K", "M", "G", "T", "P", "E", "Z"], "Y"}
      else
        {num, ["", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi"], "Yi"}
      end

    do_size_str(num / 1, units, last_unit, suffix)
  end

  defp do_size_str(num, [unit], _last_unit, suffix) do
    :io_lib.format("~.2f ~s~s", [num, unit, suffix]) |> IO.iodata_to_binary()
  end

  defp do_size_str(num, [unit | rest], last_unit, suffix) do
    if abs(num) < 1024.0 do
      :io_lib.format("~.2f ~s~s", [num, unit, suffix]) |> IO.iodata_to_binary()
    else
      do_size_str(num / 1024.0, rest, last_unit, suffix)
    end
  end

  defp client_loop do
    # Wait for the link to become active and data to be sent
    Process.sleep(200)

    unless Process.get(:should_quit, false) do
      client_loop()
    end
  end
end

##########################################################
#### Program Startup #####################################
##########################################################

cond do
  opts[:server] ->
    Speedtest.Server.run(opts[:config])

  length(args) > 0 ->
    [destination_hexhash | _] = args
    Speedtest.Client.run(destination_hexhash, opts[:config])

  true ->
    IO.puts("")
    IO.puts("Usage: mix run examples/speedtest.exs [-s | --server] [--config PATH] [DESTINATION_HASH]")
    IO.puts("")
end
