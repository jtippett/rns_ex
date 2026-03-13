##########################################################
# This RNS example demonstrates setting up announce      #
# callbacks, which will let an application receive a     #
# notification when an announce relevant for it arrives  #
##########################################################

# Parse command-line arguments
{opts, _args, _} =
  OptionParser.parse(System.argv(), strict: [config: :string])

configpath = opts[:config]

app_name = "example_utilities"

# We initialise two lists of strings to use as app_data
fruits = ["Peach", "Quince", "Date", "Tangerine", "Pomelo", "Carambola", "Grape"]
noble_gases = ["Helium", "Neon", "Argon", "Krypton", "Xenon", "Radon", "Oganesson"]

# ── Program Setup ──────────────────────────────────────

# We must first initialise Reticulum
RNS.Reticulum.start_link(configdir: configpath)

# Randomly create a new identity for our example
identity = RNS.Identity.new()

# Using the identity we just created, we create two destinations
# in the "example_utilities.announcesample" application space.
#
# Destinations are endpoints in Reticulum, that can be addressed
# and communicated with. Destinations can also announce their
# existence, which will let the network know they are reachable
# and automatically create paths to them, from anywhere else
# in the network.
destination_1 =
  RNS.Destination.new(
    identity,
    RNS.Destination.direction_in(),
    RNS.Destination.single(),
    app_name,
    ["announcesample", "fruits"]
  )

destination_2 =
  RNS.Destination.new(
    identity,
    RNS.Destination.direction_in(),
    RNS.Destination.single(),
    app_name,
    ["announcesample", "noble_gases"]
  )

# We configure the destinations to automatically prove all
# packets addressed to it.
destination_1 = RNS.Destination.set_proof_strategy(destination_1, RNS.Destination.prove_all())
destination_2 = RNS.Destination.set_proof_strategy(destination_2, RNS.Destination.prove_all())

# We create an announce handler and configure it to only ask for
# announces from "example_utilities.announcesample.fruits".
# Try changing the filter and see what happens.
announce_handler = %{
  aspect_filter: "example_utilities.announcesample.fruits",
  received_announce: fn destination_hash, _announced_identity, app_data ->
    RNS.log("Received an announce from " <> RNS.prettyhexrep(destination_hash))

    if app_data do
      RNS.log("The announce contained the following app data: " <> app_data)
    end
  end
}

# We register the announce handler with Reticulum
RNS.Transport.register_announce_handler(announce_handler)

# ── Announce Loop ──────────────────────────────────────

# Let the user know that everything is ready
RNS.log("Announce example running, hit enter to manually send an announce (Ctrl-C to quit)")

defmodule Announce.Loop do
  def run(destination_1, destination_2, fruits, noble_gases) do
    IO.gets("")

    # Randomly select a fruit
    fruit = Enum.random(fruits)

    # Send the announce including the app data
    {_receipt, destination_1} = RNS.Destination.announce(destination_1, app_data: fruit)

    RNS.log(
      "Sent announce from " <>
        RNS.prettyhexrep(destination_1.hash) <>
        " (" <> destination_1.name <> ")"
    )

    # Randomly select a noble gas
    noble_gas = Enum.random(noble_gases)

    # Send the announce including the app data
    {_receipt, destination_2} = RNS.Destination.announce(destination_2, app_data: noble_gas)

    RNS.log(
      "Sent announce from " <>
        RNS.prettyhexrep(destination_2.hash) <>
        " (" <> destination_2.name <> ")"
    )

    run(destination_1, destination_2, fruits, noble_gases)
  end
end

Announce.Loop.run(destination_1, destination_2, fruits, noble_gases)
