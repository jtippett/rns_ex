defmodule RNS.LinkLifecycleTest do
  use ExUnit.Case, async: true

  alias RNS.Link
  alias RNS.Identity
  alias RNS.Cryptography.X25519
  alias RNS.Cryptography.Ed25519

  # ── Helper: create a fully handshaken link pair ──────────────────

  defp make_handshaken_pair(opts \\ []) do
    initiator_x25519 = X25519.generate_keypair()
    responder_x25519 = X25519.generate_keypair()
    initiator_ed25519 = Ed25519.generate_keypair()
    responder_ed25519 = Ed25519.generate_keypair()
    link_id = :crypto.strong_rand_bytes(16)
    mode = Keyword.get(opts, :mode, Link.mode_aes256_cbc())

    initiator = %Link{
      Link.new()
      | status: Link.pending(),
        initiator: true,
        prv: initiator_x25519,
        pub_bytes: X25519.public_key(initiator_x25519),
        sig_prv: initiator_ed25519,
        sig_pub_bytes: Ed25519.public_key(initiator_ed25519),
        peer_pub_bytes: X25519.public_key(responder_x25519),
        peer_sig_pub_bytes: Ed25519.public_key(responder_ed25519),
        link_id: link_id,
        mode: mode,
        request_time: System.system_time(:second) - 1
    }

    responder_identity = Identity.new()

    responder = %Link{
      Link.new()
      | status: Link.pending(),
        initiator: false,
        prv: responder_x25519,
        pub_bytes: X25519.public_key(responder_x25519),
        sig_prv: responder_ed25519,
        sig_pub_bytes: Ed25519.public_key(responder_ed25519),
        peer_pub_bytes: X25519.public_key(initiator_x25519),
        peer_sig_pub_bytes: Ed25519.public_key(initiator_ed25519),
        link_id: link_id,
        mode: mode,
        owner: %{identity: responder_identity},
        request_time: System.system_time(:second) - 1
    }

    {:ok, init_hs} = Link.handshake(initiator)
    {:ok, resp_hs} = Link.handshake(responder)

    # Activate both
    now = System.system_time(:second)

    init_active = %{
      init_hs
      | status: Link.active(),
        activated_at: now,
        rtt: 1.0,
        last_inbound: now,
        last_outbound: now
    }

    resp_active = %{
      resp_hs
      | status: Link.active(),
        activated_at: now,
        rtt: 1.0,
        last_inbound: now,
        last_outbound: now
    }

    {init_active, resp_active}
  end

  defp make_active_link(opts \\ []) do
    {init, _resp} = make_handshaken_pair(opts)
    init
  end

  # ══════════════════════════════════════════════════════════════════
  # Timing queries
  # ══════════════════════════════════════════════════════════════════

  describe "get_age/1" do
    test "returns nil when link not activated" do
      link = Link.new()
      assert Link.get_age(link) == nil
    end

    test "returns time since activation" do
      link = %Link{Link.new() | activated_at: System.system_time(:second) - 5}
      age = Link.get_age(link)
      assert age >= 5
      assert age < 10
    end
  end

  describe "no_inbound_for/1" do
    test "returns time since last inbound" do
      link = %Link{Link.new() | last_inbound: System.system_time(:second) - 3}
      silence = Link.no_inbound_for(link)
      assert silence >= 3
      assert silence < 10
    end

    test "uses activated_at if later than last_inbound" do
      now = System.system_time(:second)
      link = %Link{Link.new() | last_inbound: now - 10, activated_at: now - 2}
      silence = Link.no_inbound_for(link)
      assert silence >= 2
      assert silence < 5
    end

    test "returns large value when no inbound ever" do
      link = %Link{Link.new() | last_inbound: 0, activated_at: nil}
      silence = Link.no_inbound_for(link)
      assert silence > 1_000_000
    end
  end

  describe "no_outbound_for/1" do
    test "returns time since last outbound" do
      link = %Link{Link.new() | last_outbound: System.system_time(:second) - 5}
      silence = Link.no_outbound_for(link)
      assert silence >= 5
      assert silence < 10
    end
  end

  describe "no_data_for/1" do
    test "returns time since last data" do
      link = %Link{Link.new() | last_data: System.system_time(:second) - 7}
      silence = Link.no_data_for(link)
      assert silence >= 7
      assert silence < 12
    end
  end

  describe "inactive_for/1" do
    test "returns minimum of inbound and outbound silence" do
      now = System.system_time(:second)
      link = %Link{Link.new() | last_inbound: now - 10, last_outbound: now - 3, activated_at: nil}
      assert Link.inactive_for(link) >= 3
      assert Link.inactive_for(link) < 5
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Send keepalive
  # ══════════════════════════════════════════════════════════════════

  describe "send_keepalive/1" do
    test "returns keepalive data with 0xFF byte" do
      link = make_active_link()
      {data, context, _updated} = Link.send_keepalive(link)
      assert data == <<0xFF>>
      assert context == :keepalive
    end

    test "updates last_outbound and last_keepalive" do
      link = make_active_link()
      {_data, _ctx, updated} = Link.send_keepalive(link)
      assert updated.last_outbound > 0
      assert updated.last_keepalive == updated.last_outbound
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Prove (responder side)
  # ══════════════════════════════════════════════════════════════════

  describe "prove/1" do
    test "builds proof data with signature + pub_bytes + signalling" do
      responder_identity = Identity.new()
      responder_x25519 = X25519.generate_keypair()
      responder_ed25519 = Ed25519.generate_keypair()
      link_id = :crypto.strong_rand_bytes(16)

      link = %Link{
        Link.new()
        | status: Link.handshake(),
          initiator: false,
          prv: responder_x25519,
          pub_bytes: X25519.public_key(responder_x25519),
          sig_prv: responder_ed25519,
          sig_pub_bytes: Ed25519.public_key(responder_ed25519),
          link_id: link_id,
          mtu: 500,
          mode: Link.mode_aes256_cbc(),
          owner: %{identity: responder_identity}
      }

      {proof_data, updated} = Link.prove(link)

      # proof_data = signature(64) + pub_bytes(32) + signalling(3) = 99
      assert byte_size(proof_data) == 64 + 32 + 3
      assert updated.last_outbound > 0
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Prove packet (data packet proof)
  # ══════════════════════════════════════════════════════════════════

  describe "prove_packet/2" do
    test "builds explicit proof with packet_hash + signature" do
      sig_prv = Ed25519.generate_keypair()
      link = %Link{Link.new() | sig_prv: sig_prv}

      packet_hash = :crypto.strong_rand_bytes(32)
      {proof_data, updated} = Link.prove_packet(link, packet_hash)

      # proof_data = packet_hash(32) + signature(64) = 96
      assert byte_size(proof_data) == 32 + 64
      # First 32 bytes should be the packet hash
      assert binary_part(proof_data, 0, 32) == packet_hash
      assert updated.last_outbound > 0
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Teardown
  # ══════════════════════════════════════════════════════════════════

  describe "teardown/1" do
    test "closes an active link and returns teardown data" do
      link = make_active_link()
      {teardown_data, updated} = Link.teardown(link)

      assert updated.status == Link.closed()
      assert updated.teardown_reason == Link.initiator_closed()
      assert is_binary(teardown_data)
      # Keys should be cleared
      assert updated.prv == nil
      assert updated.shared_key == nil
      assert updated.derived_key == nil
    end

    test "responder teardown sets DESTINATION_CLOSED reason" do
      {_init, resp} = make_handshaken_pair()
      {_data, updated} = Link.teardown(resp)
      assert updated.teardown_reason == Link.destination_closed()
    end

    test "pending link teardown returns nil teardown data" do
      link = %Link{Link.new() | status: Link.pending(), initiator: true}
      {teardown_data, updated} = Link.teardown(link)
      assert teardown_data == nil
      assert updated.status == Link.closed()
    end

    test "invokes link_closed callback" do
      test_pid = self()
      link = make_active_link()

      link =
        Link.set_link_closed_callback(link, fn _link ->
          send(test_pid, :link_closed_called)
        end)

      {_data, _updated} = Link.teardown(link)
      assert_receive :link_closed_called, 100
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Teardown packet (incoming LINKCLOSE)
  # ══════════════════════════════════════════════════════════════════

  describe "teardown_packet/2" do
    test "processes valid teardown packet" do
      {init, resp} = make_handshaken_pair()

      # Initiator sends teardown: encrypts link_id
      {:ok, encrypted_link_id} = Link.encrypt(init, init.link_id)

      # Responder receives teardown packet
      packet = %{data: encrypted_link_id}
      result = Link.teardown_packet(resp, packet)

      assert {:ok, closed} = result
      assert closed.status == Link.closed()
      assert closed.teardown_reason == Link.initiator_closed()
    end

    test "rejects teardown with wrong data" do
      {init, resp} = make_handshaken_pair()

      # Encrypt wrong data
      {:ok, wrong_data} = Link.encrypt(init, :crypto.strong_rand_bytes(16))
      packet = %{data: wrong_data}
      result = Link.teardown_packet(resp, packet)

      assert {:error, :invalid_teardown_data} = result
    end

    test "rejects teardown with wrong key" do
      {_init, resp} = make_handshaken_pair()

      # Create garbage encrypted data
      packet = %{data: :crypto.strong_rand_bytes(64)}
      result = Link.teardown_packet(resp, packet)

      assert {:error, _} = result
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Link closed
  # ══════════════════════════════════════════════════════════════════

  describe "link_closed/1" do
    test "clears encryption keys" do
      link = make_active_link()
      closed = Link.link_closed(link)

      assert closed.prv == nil
      assert closed.pub_bytes == nil
      assert closed.shared_key == nil
      assert closed.derived_key == nil
      assert closed.token == nil
    end

    test "invokes link_closed callback" do
      test_pid = self()
      link = make_active_link()

      link =
        Link.set_link_closed_callback(link, fn _link ->
          send(test_pid, :closed_callback)
        end)

      Link.link_closed(link)
      assert_receive :closed_callback, 100
    end

    test "handles nil callbacks gracefully" do
      link = %Link{Link.new() | callbacks: nil}
      result = Link.link_closed(link)
      assert result.prv == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Update phy stats
  # ══════════════════════════════════════════════════════════════════

  describe "update_phy_stats/3" do
    test "updates stats when tracking enabled" do
      link = %Link{Link.new() | track_phy_stats: true}
      packet = %{rssi: -60, snr: 12.5, q: 0.95}
      updated = Link.update_phy_stats(link, packet)

      assert updated.rssi == -60
      assert updated.snr == 12.5
      assert updated.q == 0.95
    end

    test "does not update stats when tracking disabled" do
      link = Link.new()
      packet = %{rssi: -60, snr: 12.5, q: 0.95}
      updated = Link.update_phy_stats(link, packet)

      assert updated.rssi == nil
      assert updated.snr == nil
      assert updated.q == nil
    end

    test "updates stats when force_update is true" do
      link = Link.new()
      packet = %{rssi: -70, snr: 8.0, q: 0.8}
      updated = Link.update_phy_stats(link, packet, force_update: true)

      assert updated.rssi == -70
      assert updated.snr == 8.0
      assert updated.q == 0.8
    end

    test "preserves existing stats when packet has nil values" do
      link = %Link{Link.new() | track_phy_stats: true, rssi: -50, snr: 10.0, q: 0.9}
      packet = %{rssi: nil, snr: nil, q: nil}
      updated = Link.update_phy_stats(link, packet)

      assert updated.rssi == -50
      assert updated.snr == 10.0
      assert updated.q == 0.9
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Receive packet
  # ══════════════════════════════════════════════════════════════════

  describe "receive_packet/2" do
    test "ignores packets on closed links" do
      link = %Link{Link.new() | status: Link.closed()}
      packet = %{data: <<0xFF>>, context: :keepalive, receiving_interface: nil}
      assert {:ignored, _} = Link.receive_packet(link, packet)
    end

    test "initiator ignores keepalive request (0xFF)" do
      link = %Link{make_active_link() | initiator: true}
      packet = %{data: <<0xFF>>, context: :keepalive, receiving_interface: nil}
      assert {:ignored, _} = Link.receive_packet(link, packet)
    end

    test "updates last_inbound and rx counter" do
      {_init, resp} = make_handshaken_pair()
      now = System.system_time(:second)
      resp = %{resp | last_inbound: now - 10}

      # A keepalive from initiator
      packet = %{
        data: <<0xFF>>,
        context: :keepalive,
        receiving_interface: nil,
        packet_type: :data
      }

      {:ok, updated, _actions} = Link.receive_packet(resp, packet)

      assert updated.rx == resp.rx + 1
      assert updated.last_inbound >= now
    end

    test "revives stale link on inbound" do
      link = %Link{make_active_link() | status: Link.stale(), initiator: false}

      packet = %{
        data: <<0xFF>>,
        context: :keepalive,
        receiving_interface: nil,
        packet_type: :data
      }

      {:ok, updated, _actions} = Link.receive_packet(link, packet)
      assert updated.status == Link.active()
    end

    test "responder replies to keepalive request" do
      {_init, resp} = make_handshaken_pair()

      packet = %{
        data: <<0xFF>>,
        context: :keepalive,
        receiving_interface: nil,
        packet_type: :data
      }

      {:ok, _updated, actions} = Link.receive_packet(resp, packet)
      assert {:send_keepalive_response, <<0xFE>>} in actions
    end

    test "updates last_data for non-keepalive packets" do
      {init, resp} = make_handshaken_pair()
      resp = %{resp | last_data: 0}

      # Encrypt a data packet
      {:ok, encrypted} = Link.encrypt(init, "hello")

      packet = %{
        data: encrypted,
        context: :none,
        receiving_interface: nil,
        packet_type: :data,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      {:ok, updated, _actions} = Link.receive_packet(resp, packet)
      assert updated.last_data > 0
    end

    test "does not update last_data for keepalive packets" do
      {_init, resp} = make_handshaken_pair()
      resp = %{resp | last_data: 0}

      packet = %{
        data: <<0xFF>>,
        context: :keepalive,
        receiving_interface: nil,
        packet_type: :data
      }

      {:ok, updated, _actions} = Link.receive_packet(resp, packet)
      assert updated.last_data == 0
    end

    test "decrypts and dispatches data packets" do
      test_pid = self()
      {init, resp} = make_handshaken_pair()

      resp =
        Link.set_packet_callback(resp, fn plaintext, _pkt ->
          send(test_pid, {:packet_received, plaintext})
        end)

      {:ok, encrypted} = Link.encrypt(init, "test data")

      packet = %{
        data: encrypted,
        context: :none,
        receiving_interface: nil,
        packet_type: :data,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      {:ok, _updated, actions} = Link.receive_packet(resp, packet)

      # The callback action should be in the actions list
      assert Enum.any?(actions, fn
               {:callback, _fun, [plaintext, _pkt]} -> plaintext == "test data"
               _ -> false
             end)
    end

    test "handles LINKCLOSE context" do
      {init, resp} = make_handshaken_pair()

      {:ok, teardown_data} = Link.encrypt(init, init.link_id)

      packet = %{
        data: teardown_data,
        context: :linkclose,
        receiving_interface: nil,
        packet_type: :data
      }

      {:ok, updated, _actions} = Link.receive_packet(resp, packet)
      assert updated.status == Link.closed()
    end

    test "rejects packets on wrong interface" do
      link = %Link{make_active_link() | attached_interface: :expected_interface}

      packet = %{
        data: <<>>,
        context: :none,
        receiving_interface: :other_interface,
        packet_type: :data
      }

      assert {:ignored, _} = Link.receive_packet(link, packet)
    end

    test "handles LINKIDENTIFY context (responder side)" do
      {init, resp} = make_handshaken_pair()
      identity = Identity.new()

      # Build identify data
      {:ok, identify_data} =
        Link.build_identify_data(
          %{init | initiator: true, status: Link.active(), link_id: init.link_id},
          identity
        )

      {:ok, encrypted} = Link.encrypt(init, identify_data)

      packet = %{
        data: encrypted,
        context: :linkidentify,
        receiving_interface: nil,
        packet_type: :data
      }

      {:ok, updated, _actions} = Link.receive_packet(resp, packet)
      assert updated.remote_identity != nil
    end

    test "handles channel data" do
      {init, resp} = make_handshaken_pair()
      # Create channel on responder
      {_channel, resp} = Link.channel(resp)

      {:ok, encrypted} = Link.encrypt(init, "channel data")

      packet = %{
        data: encrypted,
        context: :channel,
        receiving_interface: nil,
        packet_type: :data,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      {:ok, _updated, actions} = Link.receive_packet(resp, packet)

      assert Enum.any?(actions, fn
               {:channel_receive, _} -> true
               _ -> false
             end)
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Resource management
  # ══════════════════════════════════════════════════════════════════

  describe "set_resource_strategy/2" do
    test "sets ACCEPT_NONE" do
      link = Link.new()
      updated = Link.set_resource_strategy(link, Link.accept_none())
      assert updated.resource_strategy == Link.accept_none()
    end

    test "sets ACCEPT_APP" do
      link = Link.new()
      updated = Link.set_resource_strategy(link, Link.accept_app())
      assert updated.resource_strategy == Link.accept_app()
    end

    test "sets ACCEPT_ALL" do
      link = Link.new()
      updated = Link.set_resource_strategy(link, Link.accept_all())
      assert updated.resource_strategy == Link.accept_all()
    end
  end

  describe "register_outgoing_resource/2" do
    test "adds resource to outgoing list" do
      link = Link.new()
      resource = %{hash: :crypto.strong_rand_bytes(32)}
      updated = Link.register_outgoing_resource(link, resource)
      assert length(updated.outgoing_resources) == 1
      assert resource in updated.outgoing_resources
    end
  end

  describe "register_incoming_resource/2" do
    test "adds resource to incoming list" do
      link = Link.new()
      resource = %{hash: :crypto.strong_rand_bytes(32)}
      updated = Link.register_incoming_resource(link, resource)
      assert length(updated.incoming_resources) == 1
    end
  end

  describe "has_incoming_resource?/2" do
    test "returns true when resource hash matches" do
      hash = :crypto.strong_rand_bytes(32)
      resource = %{hash: hash}
      link = %Link{Link.new() | incoming_resources: [resource]}
      assert Link.has_incoming_resource?(link, %{hash: hash})
    end

    test "returns false when no match" do
      link = Link.new()
      assert Link.has_incoming_resource?(link, %{hash: :crypto.strong_rand_bytes(32)}) == false
    end
  end

  describe "cancel_outgoing_resource/2" do
    test "removes resource from list" do
      resource = %{hash: :crypto.strong_rand_bytes(32)}
      link = %Link{Link.new() | outgoing_resources: [resource]}
      updated = Link.cancel_outgoing_resource(link, resource)
      assert updated.outgoing_resources == []
    end
  end

  describe "cancel_incoming_resource/2" do
    test "removes resource from list" do
      resource = %{hash: :crypto.strong_rand_bytes(32)}
      link = %Link{Link.new() | incoming_resources: [resource]}
      updated = Link.cancel_incoming_resource(link, resource)
      assert updated.incoming_resources == []
    end
  end

  describe "ready_for_new_resource?/1" do
    test "true when no outgoing resources" do
      link = Link.new()
      assert Link.ready_for_new_resource?(link) == true
    end

    test "false when outgoing resources exist" do
      link = %Link{Link.new() | outgoing_resources: [%{hash: <<1>>}]}
      assert Link.ready_for_new_resource?(link) == false
    end
  end

  describe "resource_concluded/2" do
    test "removes concluded incoming resource" do
      resource = %{
        hash: <<1>>,
        started_transferring: System.system_time(:second) - 1,
        size: 1000,
        window: 4,
        eifr: 100.0
      }

      link = %Link{Link.new() | incoming_resources: [resource]}
      updated = Link.resource_concluded(link, resource)
      assert updated.incoming_resources == []
      assert updated.expected_rate != nil
    end

    test "removes concluded outgoing resource" do
      resource = %{hash: <<1>>, started_transferring: System.system_time(:second) - 1, size: 2000}
      link = %Link{Link.new() | outgoing_resources: [resource]}
      updated = Link.resource_concluded(link, resource)
      assert updated.outgoing_resources == []
      assert updated.expected_rate != nil
    end
  end

  describe "get_last_resource_window/1" do
    test "returns nil by default" do
      assert Link.get_last_resource_window(Link.new()) == nil
    end

    test "returns window value after resource" do
      link = %Link{Link.new() | last_resource_window: 12}
      assert Link.get_last_resource_window(link) == 12
    end
  end

  describe "get_last_resource_eifr/1" do
    test "returns nil by default" do
      assert Link.get_last_resource_eifr(Link.new()) == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Status-gated getters
  # ══════════════════════════════════════════════════════════════════

  describe "get_mtu/1" do
    test "returns MTU when active" do
      link = %Link{Link.new() | status: Link.active(), mtu: 500}
      assert Link.get_mtu(link) == 500
    end

    test "returns nil when not active" do
      link = %Link{Link.new() | status: Link.pending(), mtu: 500}
      assert Link.get_mtu(link) == nil
    end
  end

  describe "get_mdu/1 (status-gated)" do
    test "returns MDU when active" do
      link = %Link{Link.new() | status: Link.active()}
      assert Link.get_mdu(link) != nil
    end

    test "returns nil when not active" do
      link = %Link{Link.new() | status: Link.pending()}
      assert Link.get_mdu(link) == nil
    end
  end

  describe "get_expected_rate/1" do
    test "returns nil when not active" do
      link = %Link{Link.new() | expected_rate: 100.0}
      assert Link.get_expected_rate(link) == nil
    end

    test "returns rate when active" do
      link = %Link{Link.new() | status: Link.active(), expected_rate: 100.0}
      assert Link.get_expected_rate(link) == 100.0
    end
  end

  describe "get_mode/1" do
    test "returns mode" do
      link = %Link{Link.new() | mode: Link.mode_aes256_cbc()}
      assert Link.get_mode(link) == Link.mode_aes256_cbc()
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Watchdog check
  # ══════════════════════════════════════════════════════════════════

  describe "watchdog_check/1" do
    test "returns empty actions for closed link" do
      link = %Link{Link.new() | status: Link.closed()}
      {:ok, _link, actions} = Link.watchdog_check(link)
      assert actions == []
    end

    test "times out pending link after establishment timeout" do
      link = %Link{
        Link.new()
        | status: Link.pending(),
          request_time: System.system_time(:second) - 1000,
          expected_hops: 1
      }

      {:ok, updated, actions} = Link.watchdog_check(link)
      assert updated.status == Link.closed()
      assert updated.teardown_reason == Link.timeout()
      assert {:teardown, :timeout} in actions
    end

    test "does not time out recent pending link" do
      link = %Link{
        Link.new()
        | status: Link.pending(),
          request_time: System.system_time(:second),
          expected_hops: 1
      }

      {:ok, updated, actions} = Link.watchdog_check(link)
      assert updated.status == Link.pending()
      assert actions == []
    end

    test "times out handshake link after establishment timeout" do
      link = %Link{
        Link.new()
        | status: Link.handshake(),
          request_time: System.system_time(:second) - 1000,
          expected_hops: 1
      }

      {:ok, updated, actions} = Link.watchdog_check(link)
      assert updated.status == Link.closed()
      assert {:teardown, :timeout} in actions
    end

    test "sends keepalive when active and overdue (initiator)" do
      now = System.system_time(:second)

      link = %Link{
        Link.new()
        | status: Link.active(),
          initiator: true,
          activated_at: now - 400,
          last_inbound: now - 400,
          last_outbound: now - 400,
          last_keepalive: now - 400,
          last_proof: now - 400,
          keepalive: 360,
          stale_time: 720,
          rtt: 1.0
      }

      {:ok, _updated, actions} = Link.watchdog_check(link)
      assert {:send_keepalive} in actions
    end

    test "does not send keepalive when not initiator" do
      now = System.system_time(:second)

      link = %Link{
        Link.new()
        | status: Link.active(),
          initiator: false,
          activated_at: now - 400,
          last_inbound: now - 400,
          last_outbound: now - 400,
          last_keepalive: now - 400,
          last_proof: now - 400,
          keepalive: 360,
          stale_time: 720,
          rtt: 1.0
      }

      {:ok, _updated, actions} = Link.watchdog_check(link)
      refute {:send_keepalive} in actions
    end

    test "marks active link as stale after stale_time" do
      now = System.system_time(:second)

      link = %Link{
        Link.new()
        | status: Link.active(),
          activated_at: now - 800,
          last_inbound: now - 800,
          last_outbound: now - 800,
          last_proof: now - 800,
          keepalive: 360,
          stale_time: 720,
          rtt: 1.0
      }

      {:ok, updated, actions} = Link.watchdog_check(link)
      assert updated.status == Link.stale()
      assert {:stale} in actions
    end

    test "stale link triggers teardown" do
      link = make_active_link()
      stale_link = %{link | status: Link.stale()}

      {:ok, updated, actions} = Link.watchdog_check(stale_link)
      assert updated.status == Link.closed()

      assert Enum.any?(actions, fn
               {:teardown, :timeout} -> true
               _ -> false
             end)
    end

    test "active link with recent inbound has no actions" do
      now = System.system_time(:second)

      link = %Link{
        Link.new()
        | status: Link.active(),
          activated_at: now,
          last_inbound: now,
          last_outbound: now,
          last_proof: now,
          keepalive: 360,
          stale_time: 720,
          rtt: 1.0
      }

      {:ok, _updated, actions} = Link.watchdog_check(link)
      assert actions == []
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Handle request / Handle response
  # ══════════════════════════════════════════════════════════════════

  describe "handle_request/3" do
    test "returns empty actions for non-active link" do
      link = %Link{Link.new() | status: Link.pending()}
      {:ok, actions, _link} = Link.handle_request(link, <<1>>, [0, <<>>, "data"])
      assert actions == []
    end
  end

  describe "handle_response/5" do
    test "returns link unchanged when no matching request" do
      link = %Link{make_active_link() | pending_requests: []}
      updated = Link.handle_response(link, <<1>>, "response", 100, 100)
      assert updated.pending_requests == []
    end

    test "removes matching pending request" do
      request_id = :crypto.strong_rand_bytes(16)
      pending = %{request_id: request_id}
      link = %Link{make_active_link() | pending_requests: [pending]}

      updated = Link.handle_response(link, request_id, "response", 100, 100)
      assert updated.pending_requests == []
    end
  end
end
