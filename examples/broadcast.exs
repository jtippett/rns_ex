##########################################################
# This RNS example demonstrates broadcasting unencrypted #
# information to any listening destinations.             #
##########################################################

# Parse command-line arguments
{opts, _args, _} =
  OptionParser.parse(System.argv(), strict: [config: :string, channel: :string])

configpath = opts[:config]

app_name = "example_utilities"

# ── Program Setup ──────────────────────────────────────

# We must first initialise Reticulum
RNS.Reticulum.start_link(configdir: configpath)

# If the user did not select a "channel" we use
# a default one called "public_information".
# This "channel" is added to the destination name-
# space, so the user can select different broadcast
# channels.
channel = opts[:channel] || "public_information"

# We create a PLAIN destination. This is an unencrypted endpoint
# that anyone can listen to and send information to.
broadcast_destination =
  RNS.Destination.new(
    nil,
    RNS.Destination.direction_in(),
    RNS.Destination.plain(),
    app_name,
    ["broadcast", channel]
  )

# We specify a callback that will get called every time
# the destination receives data.
broadcast_destination =
  RNS.Destination.set_packet_callback(broadcast_destination, fn data, _packet ->
    IO.puts("")
    IO.write("Received data: " <> data <> "\r\n> ")
  end)

# ── Broadcast Loop ─────────────────────────────────────

# Let the user know that everything is ready
RNS.log(
  "Broadcast example " <>
    RNS.prettyhexrep(broadcast_destination.hash) <>
    " running, enter text and hit enter to broadcast (Ctrl-C to quit)"
)

defmodule Broadcast.Loop do
  def run(destination) do
    IO.write("> ")
    entered = IO.gets("") |> String.trim()

    if entered != "" do
      packet = RNS.Packet.new(destination, entered)
      RNS.Packet.send(packet)
    end

    run(destination)
  end
end

Broadcast.Loop.run(broadcast_destination)
