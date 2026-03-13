defmodule RNS.Integration.LinkEstablishmentTest do
  @moduledoc """
  Integration tests for link establishment between two endpoints.

  Tests the complete 3-step ECDH handshake:
    1. Initiator creates link request with ephemeral X25519 keypair
    2. Responder validates request, generates own keypair, derives shared secret, produces proof
    3. Initiator validates proof, derives same shared secret, activates link

  Also tests encrypted communication over established links,
  data exchange via LocalInterface TCP, and link lifecycle (keepalive, teardown).
  """

  use ExUnit.Case, async: false

  alias RNS.Cryptography.Ed25519
  alias RNS.Cryptography.X25519
  alias RNS.Destination
  alias RNS.Identity
  alias RNS.Link
  alias RNS.Packet
  alias RNS.Transport

  # ── Setup ─────────────────────────────────────────────────────────

  setup do
    # Clear ETS tables for clean state (Transport is supervised by the application)
    RNS.Test.SupervisedHelpers.clear_transport_tables()
    :ok
  end

  # ── Handshake: Step-by-step (unit integration) ───────────────────

  describe "3-step ECDH handshake" do
    test "complete handshake produces matching encryption keys" do
      # === Setup: create server identity and destination ===
      server_identity = Identity.new()

      server_dest =
        Destination.new(
          server_identity,
          Destination.direction_in(),
          Destination.single(),
          "testapp",
          ["linktest"]
        )

      # === Step 1: Initiator creates link request ===
      initiator_prv = X25519.generate_keypair()
      initiator_pub = X25519.public_key(initiator_prv)
      initiator_sig_prv = Ed25519.generate_keypair()
      initiator_sig_pub = Ed25519.public_key(initiator_sig_prv)

      # Link request payload: initiator's X25519 pub (32) + Ed25519 pub (32) = 64 bytes
      link_request_data = initiator_pub <> initiator_sig_pub

      # Build a proper link request packet
      link_request_packet =
        Packet.new(server_dest, link_request_data,
          packet_type: Packet.linkrequest(),
          create_receipt: false
        )

      link_request_packet = Packet.pack(link_request_packet)
      hashable_part = Packet.hashable_part(link_request_packet)
      link_request_packet = Map.put(link_request_packet, :hashable_part, hashable_part)

      # === Step 2: Responder validates and creates proof ===
      {:ok, responder_link} =
        Link.validate_request(server_dest, link_request_data, link_request_packet)

      assert responder_link.status == Link.handshake()
      assert responder_link.peer.peer_pub_bytes == initiator_pub
      assert responder_link.peer.peer_sig_pub_bytes == initiator_sig_pub
      assert responder_link.crypto.shared_key != nil
      assert responder_link.crypto.derived_key != nil
      # AES256_CBC
      assert byte_size(responder_link.crypto.derived_key) == 64

      # Responder generates proof
      {proof_data, _updated_responder} = Link.prove(responder_link)
      assert is_binary(proof_data)

      # === Step 3: Initiator validates proof ===
      # Set up the initiator's link struct
      initiator_link = %Link{
        Link.new()
        | initiator: true,
          status: Link.pending(),
          crypto: %Link.CryptoState{
            prv: initiator_prv,
            pub_bytes: initiator_pub,
            sig_prv: initiator_sig_prv,
            sig_pub_bytes: initiator_sig_pub
          },
          destination: server_dest,
          link_id: responder_link.link_id,
          request_time: System.system_time(:second)
      }

      # Build proof packet
      proof_packet = %{
        data: proof_data,
        destination_hash: server_dest.hash,
        raw: proof_data,
        receiving_interface: %{name: "TestInterface"}
      }

      {:ok, activated_link} = Link.validate_proof(initiator_link, proof_packet)

      assert activated_link.status == Link.active()
      assert activated_link.crypto.shared_key != nil
      assert activated_link.crypto.derived_key != nil
      assert activated_link.stats.rtt != nil
      assert activated_link.activated_at != nil

      # === Verify: both sides derived the same shared key ===
      assert responder_link.crypto.shared_key == activated_link.crypto.shared_key
      assert responder_link.crypto.derived_key == activated_link.crypto.derived_key
    end

    test "encryption/decryption works with derived keys" do
      {initiator, responder} = make_handshaken_pair()

      plaintext = "Hello over encrypted link!"

      # Initiator encrypts
      {:ok, ciphertext} = Link.encrypt(initiator, plaintext)
      assert ciphertext != plaintext
      assert byte_size(ciphertext) > byte_size(plaintext)

      # Responder decrypts
      {:ok, decrypted} = Link.decrypt(responder, ciphertext)
      assert decrypted == plaintext

      # And the other direction
      {:ok, ciphertext2} = Link.encrypt(responder, "Reply from responder")
      {:ok, decrypted2} = Link.decrypt(initiator, ciphertext2)
      assert decrypted2 == "Reply from responder"
    end

    test "encryption with wrong key fails" do
      {initiator, _responder} = make_handshaken_pair()
      {_other_initiator, other_responder} = make_handshaken_pair()

      {:ok, ciphertext} = Link.encrypt(initiator, "secret message")

      # Trying to decrypt with a different link's key should fail
      assert {:error, _} = Link.decrypt(other_responder, ciphertext)
    end

    test "link signing and validation works" do
      {initiator, responder} = make_handshaken_pair()

      message = "message to authenticate"
      signature = Link.sign(initiator, message)

      assert byte_size(signature) == 64
      assert Link.validate(responder, signature, message)
      refute Link.validate(responder, signature, "tampered message")
    end
  end

  # ── Link over LocalInterface TCP ─────────────────────────────────

  describe "link data exchange via LocalInterface" do
    test "server and client can exchange HDLC-framed data" do
      test_pid = self()

      # Start a local server
      port = Enum.random(40_000..49_999)

      {:ok, server_pid} =
        RNS.Interfaces.LocalServerInterface.start_link(
          name: "TestServer",
          owner: fn data, _iface ->
            send(test_pid, {:server_received, data})
          end,
          bindport: port
        )

      # Give server time to start listening
      Process.sleep(50)

      # Start a local client
      {:ok, client_pid} =
        RNS.Interfaces.LocalClientInterface.start_link(
          name: "TestClient",
          owner: fn data, _iface ->
            send(test_pid, {:client_received, data})
          end,
          target_port: port
        )

      Process.sleep(100)

      # Verify client is connected
      client_state = RNS.Interfaces.LocalClientInterface.get_state(client_pid)
      assert client_state.online == true

      # Send data from client to server
      # Must be > 19 bytes (HEADER_MINSIZE) to pass the local interface filter
      test_data = :crypto.strong_rand_bytes(32)
      :ok = RNS.Interfaces.LocalClientInterface.send_data(client_pid, test_data)

      # Server should receive the data (via spawned client interface)
      assert_receive {:server_received, received_data}, 2000
      assert received_data == test_data

      # Cleanup
      RNS.Interfaces.LocalClientInterface.stop(client_pid)
      RNS.Interfaces.LocalServerInterface.stop(server_pid)
      Process.sleep(50)
    end
  end

  # ── Link Registration with Transport ─────────────────────────────

  describe "link registration with Transport" do
    test "pending link can be registered and found" do
      {initiator, _responder} = make_handshaken_pair()
      pending = %{initiator | status: Link.pending(), initiator: true}

      Transport.register_link(pending)

      found = Transport.find_link_for_request_packet(%{destination_hash: pending.link_id})
      assert found != nil
      assert found.link_id == pending.link_id
    end

    test "active link can be registered and retrieved" do
      {initiator, _responder} = make_handshaken_pair()
      # register_link with initiator=false goes to active table
      active = %{initiator | status: Link.active(), initiator: false}

      Transport.register_link(active)

      # find_best_link looks up by key (link_id) in active table
      found = Transport.find_best_link(active.link_id)
      assert found != nil
      assert found.link_id == active.link_id
    end

    test "link can be moved from pending to active" do
      {initiator, _responder} = make_handshaken_pair()
      pending = %{initiator | status: Link.pending(), initiator: true}

      Transport.register_link(pending)
      pending_links = Transport.get_pending_links()
      assert Enum.any?(pending_links, fn l -> l.link_id == pending.link_id end)

      # activate_link expects :active atom status (matches Python behavior)
      activated = %{pending | status: :active}
      result = Transport.activate_link(activated)
      assert result == :ok

      # Should now be in active links
      active_links = Transport.get_active_links()
      assert Enum.any?(active_links, fn l -> l.link_id == activated.link_id end)

      # Should no longer be in pending
      pending_links2 = Transport.get_pending_links()
      refute Enum.any?(pending_links2, fn l -> l.link_id == pending.link_id end)
    end
  end

  # ── Link Lifecycle ───────────────────────────────────────────────

  describe "link lifecycle" do
    test "keepalive data is generated correctly" do
      {link, _} = make_handshaken_pair()
      active = %{link | status: Link.active(), activated_at: System.system_time(:second)}

      {data, context, updated} = Link.send_keepalive(active)

      assert data == <<0xFF>>
      assert context == :keepalive
      assert updated.stats.last_outbound > 0
      assert updated.stats.last_keepalive > 0
    end

    test "teardown transitions link to closed state" do
      {link, _} = make_handshaken_pair()
      active = %{link | status: Link.active(), activated_at: System.system_time(:second)}

      {teardown_data, closed_link} = Link.teardown(active)

      assert closed_link.status == Link.closed()
      assert is_binary(teardown_data)
    end

    test "timing queries work on active link" do
      now = System.system_time(:second)
      {link, _} = make_handshaken_pair()

      active = %{
        link
        | status: Link.active(),
          activated_at: now - 100,
          stats: %{
            link.stats
            | last_inbound: now - 10,
              last_outbound: now - 5,
              last_data: now - 15
          }
      }

      assert Link.get_age(active) >= 100
      assert Link.no_inbound_for(active) >= 10
      assert Link.no_outbound_for(active) >= 5
      assert Link.no_data_for(active) >= 15
      assert Link.inactive_for(active) >= 5
    end

    test "stale detection via timing thresholds" do
      now = System.system_time(:second)
      {link, _} = make_handshaken_pair()

      # stale_time is a struct field: stale_factor(2) * keepalive(360) = 720
      stale_time = Link.stale_factor() * Link.keepalive_max()

      # Link with recent activity — inactive_for < stale_time
      fresh = %{
        link
        | status: Link.active(),
          activated_at: now - 10,
          stats: %{link.stats | last_inbound: now - 5, last_outbound: now - 3, last_data: now - 5}
      }

      assert Link.inactive_for(fresh) < stale_time

      # Link with no activity for longer than stale_time
      stale = %{
        link
        | status: Link.active(),
          activated_at: now - 1000,
          stats: %{
            link.stats
            | last_inbound: now - 800,
              last_outbound: now - 800,
              last_data: now - 800
          }
      }

      assert Link.inactive_for(stale) > stale_time
    end
  end

  # ── Full Announce → Path → Link Request Flow ────────────────────

  describe "announce then link request flow" do
    test "after announce, destination hash can be used to create link request" do
      # Server side creates identity and destination
      server_identity = Identity.new()

      server_dest =
        Destination.new(
          server_identity,
          Destination.direction_in(),
          Destination.single(),
          "testapp",
          ["linkflow"]
        )

      # Don't register destination — simulate client side receiving an announce
      # from a remote server (client doesn't have the destination registered)

      # Server announces
      {announce_packet, _} = Destination.announce(server_dest, send: false)
      packed = Packet.pack(announce_packet)

      # Simulate receiving the announce on the client's Transport
      mock_interface = %{name: "TestInterface", out: true, mode: nil, ifac_identity: nil}
      Transport.inbound(packed.raw, mock_interface)

      # Client side — verify path exists from the announce
      assert Transport.has_path(server_dest.hash)

      # Client creates link request data
      initiator_prv = X25519.generate_keypair()
      initiator_pub = X25519.public_key(initiator_prv)
      initiator_sig_prv = Ed25519.generate_keypair()
      initiator_sig_pub = Ed25519.public_key(initiator_sig_prv)

      link_request_data = initiator_pub <> initiator_sig_pub

      # Verify the request data is the correct size (64 bytes = ECPUBSIZE)
      assert byte_size(link_request_data) == Link.ecpubsize()

      # The server destination hash is known from the announce
      assert byte_size(server_dest.hash) == 16

      # Path info is available
      assert Transport.hops_to(server_dest.hash) == 1
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp make_handshaken_pair do
    # Create server identity and destination
    server_identity = Identity.new()

    server_dest =
      Destination.new(
        server_identity,
        Destination.direction_in(),
        Destination.single(),
        "testapp",
        ["handshake"]
      )

    # Initiator keys
    initiator_prv = X25519.generate_keypair()
    initiator_pub = X25519.public_key(initiator_prv)
    initiator_sig_prv = Ed25519.generate_keypair()
    initiator_sig_pub = Ed25519.public_key(initiator_sig_prv)

    link_request_data = initiator_pub <> initiator_sig_pub

    # Build a proper link request packet using Packet.pack
    link_request_packet =
      Packet.new(server_dest, link_request_data,
        packet_type: Packet.linkrequest(),
        create_receipt: false
      )

    link_request_packet = Packet.pack(link_request_packet)

    # Compute hashable part and attach it to the packet
    hashable_part = Packet.hashable_part(link_request_packet)
    link_request_packet = Map.put(link_request_packet, :hashable_part, hashable_part)

    # Responder validates
    {:ok, responder_link} =
      Link.validate_request(server_dest, link_request_data, link_request_packet)

    {proof_data, updated_responder} = Link.prove(responder_link)

    # Initiator validates proof
    initiator_link = %Link{
      Link.new()
      | initiator: true,
        status: Link.pending(),
        crypto: %Link.CryptoState{
          prv: initiator_prv,
          pub_bytes: initiator_pub,
          sig_prv: initiator_sig_prv,
          sig_pub_bytes: initiator_sig_pub
        },
        destination: server_dest,
        link_id: responder_link.link_id,
        request_time: System.system_time(:second)
    }

    proof_packet = %{
      data: proof_data,
      destination_hash: server_dest.hash,
      raw: proof_data,
      receiving_interface: %{name: "TestInterface"}
    }

    {:ok, activated_initiator} = Link.validate_proof(initiator_link, proof_packet)

    {activated_initiator, updated_responder}
  end
end
