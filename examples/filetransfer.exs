##########################################################
# This RNS example demonstrates a simple filetransfer    #
# server and client program. The server will serve a     #
# directory of files, and the clients can list and       #
# download files from the server.                        #
#                                                        #
# Please note that using RNS Resources for large file    #
# transfers is not recommended, since compression,       #
# encryption and hashmap sequencing can take a long time #
# on systems with slow CPUs, which will probably result  #
# in the client timing out before the resource sender    #
# can complete preparing the resource.                   #
#                                                        #
# If you need to transfer large files, use the Bundle    #
# class instead, which will automatically slice the data #
# into chunks suitable for packing as a Resource.        #
##########################################################

# Parse command-line arguments
{opts, args, _} =
  OptionParser.parse(System.argv(),
    strict: [serve: :string, config: :string]
  )

app_name = "example_utilities"
app_timeout = 45.0

##########################################################
#### Server Part #########################################
##########################################################

defmodule Filetransfer.Server do
  @app_timeout 45.0

  def run(configpath, serve_path) do
    # We must first initialise Reticulum
    RNS.Reticulum.start_link(configdir: configpath)

    # Randomly create a new identity for our file server
    server_identity = RNS.Identity.new()

    # Store the serve path for later access
    Process.put(:serve_path, serve_path)

    # We create a destination that clients can connect to. We
    # want clients to create links to this destination, so we
    # need to create a "single" destination type.
    server_destination =
      RNS.Destination.new(
        server_identity,
        RNS.Destination.direction_in(),
        RNS.Destination.single(),
        "example_utilities",
        ["filetransfer", "server"]
      )

    # We configure a function that will get called every time
    # a new client creates a link to this destination.
    server_destination =
      RNS.Destination.set_link_established_callback(server_destination, fn link ->
        serve_path = Process.get(:serve_path)

        if File.dir?(serve_path) do
          RNS.log("Client connected, sending file list...")

          link =
            link
            |> RNS.Link.set_link_closed_callback(fn _link ->
              RNS.log("Client disconnected")
            end)
            |> RNS.Link.set_packet_callback(fn message, packet ->
              # Client is requesting a file
              serve_path = Process.get(:serve_path)
              filename = message

              if filename in list_files(serve_path) do
                RNS.log("Client requested \"#{filename}\"")
                filepath = Path.join(serve_path, filename)
                file_data = File.read!(filepath)

                _resource =
                  RNS.Resource.new(file_data, packet.link,
                    callback: fn resource ->
                      if resource.status == RNS.Resource.status_complete() do
                        RNS.log("Done sending \"#{filename}\" to client")
                      else
                        RNS.log("Sending \"#{filename}\" to client failed")
                      end
                    end
                  )
              else
                RNS.log("Client requested an unknown file")
                RNS.Link.teardown(packet.link)
              end
            end)

          # Pack the file list using msgpack and send it
          files = list_files(serve_path)
          data = Msgpax.pack!(files, iodata: false)

          if byte_size(data) <= RNS.Link.mdu() do
            list_packet = RNS.Packet.new(link, data)
            receipt = RNS.Packet.send(list_packet)

            receipt
            |> RNS.PacketReceipt.set_timeout(@app_timeout)
            |> RNS.PacketReceipt.set_delivery_callback(fn _receipt ->
              RNS.log("The file list was received by the client")
            end)
            |> RNS.PacketReceipt.set_timeout_callback(fn receipt ->
              RNS.log("Sending list to client timed out, closing this link")
              RNS.Link.teardown(receipt.destination)
            end)
          else
            RNS.log("Too many files in served directory!", :error)
          end

          link
        else
          RNS.log("Client connected, but served path no longer exists!", :error)
          RNS.Link.teardown(link)
          link
        end
      end)

    # Everything's ready!
    # Let's wait for client requests or user input
    announce_loop(server_destination)
  end

  defp list_files(serve_path) do
    serve_path
    |> File.ls!()
    |> Enum.filter(fn file ->
      full_path = Path.join(serve_path, file)
      File.regular?(full_path) and not String.starts_with?(file, ".")
    end)
  end

  defp announce_loop(destination) do
    RNS.log("File server " <> RNS.prettyhexrep(destination.hash) <> " running")
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

defmodule Filetransfer.Client do
  @app_timeout 45.0

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
        ["filetransfer", "server"]
      )

    # We also want to automatically prove incoming packets
    server_destination =
      RNS.Destination.set_proof_strategy(server_destination, RNS.Destination.prove_all())

    # And create a link
    link = RNS.Link.new()

    # We expect any normal data packets on the link
    # to contain a list of served files, so we set
    # a callback accordingly
    link =
      link
      |> RNS.Link.set_packet_callback(fn filelist_data, _packet ->
        filelist = Msgpax.unpack!(filelist_data)
        existing = Process.get(:server_files, [])
        updated = Enum.uniq(existing ++ filelist)
        Process.put(:server_files, updated)
      end)
      |> RNS.Link.set_link_established_callback(fn link ->
        Process.put(:server_link, link)
        RNS.log("Link established with server")
        RNS.log("Waiting for filelist...")

        # Start a timeout watcher
        spawn(fn ->
          Process.sleep(round(@app_timeout * 1000))

          if Process.get(:server_files, []) == [] do
            RNS.log("Timed out waiting for filelist, exiting")
            System.halt(0)
          end
        end)
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
      |> RNS.Link.set_resource_strategy(RNS.Link.accept_all())
      |> RNS.Link.set_resource_started_callback(fn resource ->
        Process.put(:current_download, resource)

        if Process.get(:download_started) == nil do
          Process.put(:download_started, System.monotonic_time(:millisecond))
        end

        transfer_size = Process.get(:transfer_size, 0) + resource.size
        Process.put(:transfer_size, transfer_size)
        Process.put(:file_size, resource.total_size)

        IO.puts("Download started")
      end)
      |> RNS.Link.set_resource_concluded_callback(fn resource ->
        download_finished = System.monotonic_time(:millisecond)
        download_started = Process.get(:download_started, download_finished)
        download_time = (download_finished - download_started) / 1000.0
        transfer_size = Process.get(:transfer_size, 0)
        file_size = Process.get(:file_size, 0)
        current_filename = Process.get(:current_filename, "download")

        if resource.status == RNS.Resource.status_complete() do
          # Find a unique filename
          saved_filename = unique_filename(current_filename)

          case File.write(saved_filename, resource.data) do
            :ok ->
              print_statistics(download_time, file_size, transfer_size)
              IO.puts("The download completed! Press enter to return to the menu.")
              IO.gets("")

            {:error, _} ->
              IO.puts("Could not write downloaded file to disk")
          end
        else
          IO.puts("")
          IO.puts("The download failed! Press enter to return to the menu.")
          IO.gets("")
        end

        # Reset download state
        Process.put(:current_download, nil)
        Process.put(:download_started, nil)
        Process.put(:transfer_size, 0)
        Process.put(:menu_mode, :main)
      end)

    # Enter the menu loop
    menu(link)
  end

  defp wait_for_path(destination_hash) do
    unless RNS.Transport.has_path(destination_hash) do
      Process.sleep(100)
      wait_for_path(destination_hash)
    end
  end

  defp menu(_link) do
    # Wait until we have a filelist
    wait_for_filelist()
    RNS.log("Ready!")
    Process.sleep(500)
    Process.put(:menu_mode, :main)
    menu_loop()
  end

  defp wait_for_filelist do
    if Process.get(:server_files, []) == [] do
      Process.sleep(100)
      wait_for_filelist()
    end
  end

  defp menu_loop do
    server_files = Process.get(:server_files, [])
    server_link = Process.get(:server_link)

    clear_screen()
    print_filelist(server_files)
    IO.puts("")
    IO.puts("Select a file to download by entering name or number, or q to quit")
    IO.write("> ")

    user_input = IO.gets("") |> String.trim()

    cond do
      user_input in ["q", "quit", "exit"] ->
        if server_link, do: RNS.Link.teardown(server_link)

      user_input in server_files ->
        download(user_input, server_link)
        menu_loop()

      true ->
        case Integer.parse(user_input) do
          {index, ""} when index >= 0 and index < length(server_files) ->
            download(Enum.at(server_files, index), server_link)
            menu_loop()

          _ ->
            menu_loop()
        end
    end
  end

  defp download(filename, server_link) do
    Process.put(:current_filename, filename)
    Process.put(:download_started, nil)
    Process.put(:transfer_size, 0)

    # Send a packet containing the requested filename
    request_packet = RNS.Packet.new(server_link, filename, create_receipt: false)
    RNS.Packet.send(request_packet)

    IO.puts("")
    IO.puts("Requested \"#{filename}\" from server, waiting for download to begin...")

    # Wait for the download to complete
    wait_for_download()
  end

  defp wait_for_download do
    case Process.get(:menu_mode) do
      :main ->
        :ok

      _ ->
        Process.sleep(250)
        wait_for_download()
    end
  end

  defp print_filelist(files) do
    IO.puts("Files on server:")

    files
    |> Enum.with_index()
    |> Enum.each(fn {file, index} ->
      IO.puts("\t(#{index})\t#{file}")
    end)
  end

  defp print_statistics(download_time, file_size, transfer_size) do
    IO.write("\rProgress: 100.0 % ")

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
    IO.puts("\tFile size        : #{size_str(file_size)}")
    IO.puts("\tData transferred : #{size_str(transfer_size)}")

    if download_time > 0 do
      IO.puts("\tEffective rate   : #{size_str(file_size / download_time, "b")}/s")
      IO.puts("\tTransfer rate    : #{size_str(transfer_size / download_time, "b")}/s")
    end

    IO.puts("")
  end

  defp unique_filename(filename, counter \\ 0) do
    candidate = if counter == 0, do: filename, else: "#{filename}.#{counter}"

    if File.exists?(candidate) do
      unique_filename(filename, counter + 1)
    else
      candidate
    end
  end

  defp size_str(num, suffix \\ "B") do
    {num, units, last_unit} =
      if suffix == "b" do
        {num * 8, ["", "K", "M", "G", "T", "P", "E", "Z"], "Y"}
      else
        {num, ["", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi"], "Yi"}
      end

    do_size_str(num, units, last_unit, suffix)
  end

  defp do_size_str(num, [unit], last_unit, suffix) do
    _ = last_unit
    :io_lib.format("~.2f ~s~s", [num, unit, suffix]) |> IO.iodata_to_binary()
  end

  defp do_size_str(num, [unit | rest], last_unit, suffix) do
    if abs(num) < 1024.0 do
      :io_lib.format("~.2f ~s~s", [num, unit, suffix]) |> IO.iodata_to_binary()
    else
      do_size_str(num / 1024.0, rest, last_unit, suffix)
    end
  end

  defp clear_screen do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
  end
end

##########################################################
#### Program Startup #####################################
##########################################################

cond do
  opts[:serve] ->
    if File.dir?(opts[:serve]) do
      Filetransfer.Server.run(opts[:config], opts[:serve])
    else
      RNS.log("The specified directory does not exist")
    end

  length(args) > 0 ->
    [destination_hexhash | _] = args
    Filetransfer.Client.run(destination_hexhash, opts[:config])

  true ->
    IO.puts("")
    IO.puts("Usage: mix run examples/filetransfer.exs [--serve DIR] [--config PATH] [DESTINATION_HASH]")
    IO.puts("")
end
