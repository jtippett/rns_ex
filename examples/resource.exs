##########################################################
# This RNS example demonstrates how to transfer a        #
# resource over an established link.                      #
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

defmodule Resource.Server do
  def run(configpath) do
    # We must first initialise Reticulum
    RNS.Reticulum.start_link(configdir: configpath)

    # Randomly create a new identity for our resource example
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
        ["resourceexample"]
      )

    # We configure a function that will get called every time
    # a new client creates a link to this destination.
    server_destination =
      RNS.Destination.set_link_established_callback(server_destination, fn link ->
        RNS.log("Client connected")

        link
        |> RNS.Link.set_resource_strategy(RNS.Link.accept_all())
        |> RNS.Link.set_resource_concluded_callback(fn resource ->
          if resource.status == RNS.Resource.status_complete() do
            RNS.log("Resource received")
            RNS.log("Metadata: #{inspect(resource.metadata)}")
            RNS.log("Data length: #{byte_size(resource.data)}")
            RNS.log("First 32 bytes of data: #{RNS.hexrep(binary_part(resource.data, 0, min(32, byte_size(resource.data))))}")
          else
            RNS.log("Receiving resource failed")
          end
        end)
        |> RNS.Link.set_link_closed_callback(fn _link ->
          RNS.log("Client disconnected")
        end)
      end)

    # Everything's ready!
    # Let's wait for client resources or user input
    server_loop(server_destination)
  end

  defp server_loop(destination) do
    RNS.log(
      "Resource example " <>
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

defmodule Resource.Client do
  @random_texts [
    "They looked up",
    "On each full moon",
    "Becky was upset",
    "I'll stay away from it",
    "The pet shop stocks everything"
  ]

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
        ["resourceexample"]
      )

    # And create a link
    link = RNS.Link.new()

    # We'll set up functions to inform the
    # user when the link is established or closed
    link =
      link
      |> RNS.Link.set_link_established_callback(fn link ->
        # Store the link reference for use in the client loop
        Process.put(:server_link, link)

        RNS.log(
          "Link established with server, hit enter to send a resource, or type \"quit\" to quit"
        )
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
    # Wait for the link to become active
    link = wait_for_link(link)

    IO.write("> ")
    text = IO.gets("") |> String.trim()

    cond do
      text in ["quit", "q", "exit"] ->
        RNS.Link.teardown(link)

      true ->
        # Generate 32 megabytes of random data
        data = :crypto.strong_rand_bytes(32 * 1024 * 1024)
        RNS.log("Data length: #{byte_size(data)}")
        RNS.log("First 32 bytes of data: #{RNS.hexrep(binary_part(data, 0, 32))}")

        # Generate some metadata
        metadata = %{
          "text" => Enum.random(@random_texts),
          "numbers" => [1, 2, 3, 4],
          "blob" => :crypto.strong_rand_bytes(16)
        }

        # Send the resource
        _resource =
          RNS.Resource.new(data, link,
            metadata: metadata,
            callback: fn resource ->
              if resource.status == RNS.Resource.status_complete() do
                RNS.log("The resource was sent successfully")
              else
                RNS.log("Sending the resource failed")
              end
            end,
            auto_compress: false
          )

        client_loop(link, _destination)
    end
  end

  defp wait_for_link(link) do
    case Process.get(:server_link) do
      nil ->
        Process.sleep(100)
        wait_for_link(link)

      established_link ->
        established_link
    end
  end
end

##########################################################
#### Program Startup #####################################
##########################################################

cond do
  opts[:server] ->
    Resource.Server.run(opts[:config])

  length(args) > 0 ->
    [destination_hexhash | _] = args
    Resource.Client.run(destination_hexhash, opts[:config])

  true ->
    IO.puts("")
    IO.puts("Usage: mix run examples/resource.exs [-s | --server] [--config PATH] [DESTINATION_HASH]")
    IO.puts("")
end
