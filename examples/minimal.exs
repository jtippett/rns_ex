##########################################################
# This RNS example demonstrates a minimal setup, that    #
# will start up the Reticulum Network Stack, generate a  #
# new destination, and let the user send an announce.    #
##########################################################

# Parse command-line arguments
{opts, _args, _} =
  OptionParser.parse(System.argv(), strict: [config: :string])

configpath = opts[:config]

# Let's define an app name. We'll use this for all
# destinations we create. Since this basic example
# is part of a range of example utilities, we'll put
# them all within the app namespace "example_utilities"
app_name = "example_utilities"

# ── Program Setup ──────────────────────────────────────

# We must first initialise Reticulum
RNS.Reticulum.start_link(configdir: configpath)

# Randomly create a new identity for our example
identity = RNS.Identity.new()

# Using the identity we just created, we create a destination.
# Destinations are endpoints in Reticulum, that can be addressed
# and communicated with. Destinations can also announce their
# existence, which will let the network know they are reachable
# and automatically create paths to them, from anywhere else
# in the network.
destination =
  RNS.Destination.new(
    identity,
    RNS.Destination.direction_in(),
    RNS.Destination.single(),
    app_name,
    ["minimalsample"]
  )

# We configure the destination to automatically prove all
# packets addressed to it. By doing this, RNS will automatically
# generate a proof for each incoming packet and transmit it
# back to the sender of that packet. This will let anyone that
# tries to communicate with the destination know whether their
# communication was received correctly.
destination = RNS.Destination.set_proof_strategy(destination, RNS.Destination.prove_all())

# ── Announce Loop ──────────────────────────────────────

# Let the user know that everything is ready
RNS.log(
  "Minimal example " <>
    RNS.prettyhexrep(destination.hash) <>
    " running, hit enter to manually send an announce (Ctrl-C to quit)"
)

# We enter a loop that runs until the user exits.
# If the user hits enter, we will announce our server
# destination on the network, which will let clients
# know how to create messages directed towards it.
defmodule Minimal.Loop do
  def run(destination) do
    IO.gets("")
    {_receipt, destination} = RNS.Destination.announce(destination)
    RNS.log("Sent announce from " <> RNS.prettyhexrep(destination.hash))
    run(destination)
  end
end

Minimal.Loop.run(destination)
