defmodule RNS.TransportControlDestinationsTest do
  use ExUnit.Case, async: false

  alias RNS.Transport
  alias RNS.Destination
  alias RNS.Identity

  setup do
    RNS.Test.SupervisedHelpers.clear_transport_tables()
    :ok
  end

  # ── Control destinations (always created) ─────────────────────────────

  describe "control destinations" do
    test "create_destinations creates path_request_destination" do
      Transport.create_destinations([])
      dest = Transport.path_request_destination()

      assert dest != nil
      assert dest.type == Destination.plain()
      assert dest.direction == Destination.direction_in()
      assert dest.identity == nil
      # Aspect is "path.request" under app "rnstransport"
      assert dest.name =~ "rnstransport"
      assert dest.name =~ "path"
      assert dest.name =~ "request"
    end

    test "create_destinations creates tunnel_synthesize_destination" do
      Transport.create_destinations([])
      dest = Transport.tunnel_synthesize_destination()

      assert dest != nil
      assert dest.type == Destination.plain()
      assert dest.direction == Destination.direction_in()
      assert dest.identity == nil
      assert dest.name =~ "tunnel"
      assert dest.name =~ "synthesize"
    end

    test "path_request_destination has a packet callback" do
      Transport.create_destinations([])
      dest = Transport.path_request_destination()

      assert dest.callbacks.packet != nil
      assert is_function(dest.callbacks.packet, 2)
    end

    test "tunnel_synthesize_destination has a packet callback" do
      Transport.create_destinations([])
      dest = Transport.tunnel_synthesize_destination()

      assert dest.callbacks.packet != nil
      assert is_function(dest.callbacks.packet, 2)
    end

    test "control destinations are registered with Transport" do
      Transport.create_destinations([])

      destinations = Transport.get_destinations()
      path_req = Transport.path_request_destination()
      tunnel_synth = Transport.tunnel_synthesize_destination()

      hashes = Enum.map(destinations, & &1.hash)
      assert path_req.hash in hashes
      assert tunnel_synth.hash in hashes
    end

    test "control_hashes returns hashes of control destinations" do
      Transport.create_destinations([])
      hashes = Transport.control_hashes()

      assert is_list(hashes)
      assert length(hashes) == 2
      assert Transport.path_request_destination().hash in hashes
      assert Transport.tunnel_synthesize_destination().hash in hashes
    end
  end

  # ── Probe destination (conditional) ───────────────────────────────────

  describe "probe destination" do
    test "created when probe_enabled is true" do
      Transport.create_destinations(probe_enabled: true)
      dest = Transport.probe_destination()

      assert dest != nil
      assert dest.type == Destination.single()
      assert dest.direction == Destination.direction_in()
      assert dest.identity != nil
      assert dest.name =~ "probe"
    end

    test "probe destination uses transport identity" do
      Transport.create_destinations(probe_enabled: true)
      dest = Transport.probe_destination()
      identity = Transport.identity()

      assert dest.identity == identity
    end

    test "probe destination does not accept links" do
      Transport.create_destinations(probe_enabled: true)
      dest = Transport.probe_destination()

      assert Destination.accepts_links?(dest) == false
    end

    test "probe destination has PROVE_ALL proof strategy" do
      Transport.create_destinations(probe_enabled: true)
      dest = Transport.probe_destination()

      assert dest.proof_strategy == Destination.prove_all()
    end

    test "probe destination not created when probe_enabled is false" do
      Transport.create_destinations(probe_enabled: false)
      assert Transport.probe_destination() == nil
    end

    test "probe destination is in mgmt_destinations" do
      Transport.create_destinations(probe_enabled: true)

      mgmt_hashes = Transport.mgmt_hashes()
      probe = Transport.probe_destination()
      assert probe.hash in mgmt_hashes
    end
  end

  # ── Remote management destination (conditional) ───────────────────────

  describe "remote management destination" do
    test "created when remote_management_enabled and not connected to shared" do
      Transport.create_destinations(
        remote_management_enabled: true,
        is_connected_to_shared_instance: false
      )

      dest = Transport.remote_management_destination()

      assert dest != nil
      assert dest.type == Destination.single()
      assert dest.direction == Destination.direction_in()
      assert dest.name =~ "remote"
      assert dest.name =~ "management"
    end

    test "remote management destination uses transport identity" do
      Transport.create_destinations(
        remote_management_enabled: true,
        is_connected_to_shared_instance: false
      )

      dest = Transport.remote_management_destination()
      identity = Transport.identity()
      assert dest.identity == identity
    end

    test "remote management destination has request handlers for /status and /path" do
      Transport.create_destinations(
        remote_management_enabled: true,
        is_connected_to_shared_instance: false
      )

      dest = Transport.remote_management_destination()

      # Request handlers are keyed by truncated hash of path
      status_hash = Identity.truncated_hash("/status")
      path_hash = Identity.truncated_hash("/path")

      assert Map.has_key?(dest.request_handlers, status_hash)
      assert Map.has_key?(dest.request_handlers, path_hash)
    end

    test "not created when connected to shared instance" do
      Transport.create_destinations(
        remote_management_enabled: true,
        is_connected_to_shared_instance: true
      )

      assert Transport.remote_management_destination() == nil
    end

    test "not created when remote_management_enabled is false" do
      Transport.create_destinations(
        remote_management_enabled: false,
        is_connected_to_shared_instance: false
      )

      assert Transport.remote_management_destination() == nil
    end
  end

  # ── Blackhole destination (conditional) ───────────────────────────────

  describe "blackhole destination" do
    test "created when publish_blackhole and not connected to shared" do
      Transport.create_destinations(
        publish_blackhole: true,
        is_connected_to_shared_instance: false
      )

      dest = Transport.blackhole_destination()

      assert dest != nil
      assert dest.type == Destination.single()
      assert dest.direction == Destination.direction_in()
      assert dest.name =~ "info"
      assert dest.name =~ "blackhole"
    end

    test "blackhole destination has /list request handler" do
      Transport.create_destinations(
        publish_blackhole: true,
        is_connected_to_shared_instance: false
      )

      dest = Transport.blackhole_destination()
      list_hash = Identity.truncated_hash("/list")
      assert Map.has_key?(dest.request_handlers, list_hash)
    end

    test "not created when publish_blackhole is false" do
      Transport.create_destinations(
        publish_blackhole: false,
        is_connected_to_shared_instance: false
      )

      assert Transport.blackhole_destination() == nil
    end

    test "not created when connected to shared instance" do
      Transport.create_destinations(
        publish_blackhole: true,
        is_connected_to_shared_instance: true
      )

      assert Transport.blackhole_destination() == nil
    end
  end

  # ── Network destinations (conditional) ────────────────────────────────

  describe "network destinations" do
    test "instance and network destinations created when network_identity exists" do
      net_identity = Identity.new()

      Transport.create_destinations(
        network_identity: net_identity,
        is_connected_to_shared_instance: false
      )

      inst = Transport.instance_destination()
      net = Transport.network_destination()

      assert inst != nil
      assert net != nil
      assert inst.type == Destination.single()
      assert net.type == Destination.single()
      assert inst.identity == net_identity
      assert net.identity == net_identity
    end

    test "instance destination includes network identity hexhash in aspects" do
      net_identity = Identity.new()

      Transport.create_destinations(
        network_identity: net_identity,
        is_connected_to_shared_instance: false
      )

      inst = Transport.instance_destination()
      assert inst.name =~ "network"
      assert inst.name =~ "instance"
      assert inst.name =~ Base.encode16(net_identity.hash, case: :lower)
    end

    test "network destination has 'network' aspect" do
      net_identity = Identity.new()

      Transport.create_destinations(
        network_identity: net_identity,
        is_connected_to_shared_instance: false
      )

      net = Transport.network_destination()
      assert net.name =~ "network"
    end

    test "not created when no network_identity" do
      Transport.create_destinations(
        network_identity: nil,
        is_connected_to_shared_instance: false
      )

      assert Transport.instance_destination() == nil
      assert Transport.network_destination() == nil
    end

    test "not created when connected to shared instance" do
      net_identity = Identity.new()

      Transport.create_destinations(
        network_identity: net_identity,
        is_connected_to_shared_instance: true
      )

      assert Transport.instance_destination() == nil
      assert Transport.network_destination() == nil
    end

    test "network destinations are in mgmt_destinations" do
      net_identity = Identity.new()

      Transport.create_destinations(
        network_identity: net_identity,
        is_connected_to_shared_instance: false
      )

      mgmt_hashes = Transport.mgmt_hashes()
      inst = Transport.instance_destination()
      net = Transport.network_destination()

      assert inst.hash in mgmt_hashes
      assert net.hash in mgmt_hashes
    end
  end

  # ── Integration ───────────────────────────────────────────────────────

  describe "create_destinations integration" do
    test "all destinations created together with full config" do
      net_identity = Identity.new()

      Transport.create_destinations(
        probe_enabled: true,
        remote_management_enabled: true,
        publish_blackhole: true,
        is_connected_to_shared_instance: false,
        network_identity: net_identity
      )

      # Control destinations always exist
      assert Transport.path_request_destination() != nil
      assert Transport.tunnel_synthesize_destination() != nil

      # Management destinations
      assert Transport.probe_destination() != nil
      assert Transport.remote_management_destination() != nil
      assert Transport.blackhole_destination() != nil

      # Network destinations
      assert Transport.instance_destination() != nil
      assert Transport.network_destination() != nil

      # Verify control_hashes and mgmt_hashes
      assert length(Transport.control_hashes()) == 2
      # probe + remote_mgmt + blackhole + instance + network = 5
      assert length(Transport.mgmt_hashes()) >= 3
    end

    test "idempotent — calling twice doesn't duplicate destinations" do
      Transport.create_destinations([])
      hash1 = Transport.path_request_destination().hash

      Transport.create_destinations([])
      hash2 = Transport.path_request_destination().hash

      assert hash1 == hash2
    end
  end
end
