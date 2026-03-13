defmodule RNS.TransportTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias RNS.Transport

  # We need to restart Transport between tests to get clean ETS tables
  setup do
    # Stop Transport if running, then start fresh
    try do
      case GenServer.whereis(RNS.Transport) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end
    catch
      :exit, _ -> :ok
    end

    Process.sleep(10)
    {:ok, _pid} = Transport.start_link([])
    :ok
  end

  describe "constants" do
    test "transport types" do
      assert Transport.broadcast() == 0x00
      assert Transport.transport() == 0x01
      assert Transport.relay() == 0x02
      assert Transport.tunnel() == 0x03
      assert Transport.types() == [0x00, 0x01, 0x02, 0x03]
    end

    test "reachability constants" do
      assert Transport.reachability_unreachable() == 0x00
      assert Transport.reachability_direct() == 0x01
      assert Transport.reachability_transport() == 0x02
    end

    test "app name" do
      assert Transport.app_name() == "rnstransport"
    end

    test "pathfinder parameters" do
      assert Transport.pathfinder_m() == 128
      assert Transport.pathfinder_r() == 1
      assert Transport.pathfinder_g() == 5
      assert Transport.pathfinder_rw() == 0.5
      assert Transport.pathfinder_e() == 60 * 60 * 24 * 7
    end

    test "path time constants" do
      assert Transport.ap_path_time() == 60 * 60 * 24
      assert Transport.roaming_path_time() == 60 * 60 * 6
    end

    test "misc constants" do
      assert Transport.local_rebroadcasts_max() == 2
      assert Transport.path_request_timeout() == 15
      assert Transport.path_request_grace() == 0.4
      assert Transport.path_request_rg() == 1.5
      assert Transport.path_request_mi() == 20
    end

    test "state constants" do
      assert Transport.state_unknown() == 0x00
      assert Transport.state_unresponsive() == 0x01
      assert Transport.state_responsive() == 0x02
    end

    test "timeout constants" do
      # LINK_TIMEOUT = STALE_TIME * 1.25 = (2 * 360) * 1.25 = 900
      assert Transport.link_timeout() == 900
      assert Transport.reverse_timeout() == 8 * 60
      assert Transport.destination_timeout() == 60 * 60 * 24 * 7
    end

    test "limit constants" do
      assert Transport.max_receipts() == 1024
      assert Transport.max_rate_timestamps() == 16
      assert Transport.persist_random_blobs() == 32
      assert Transport.max_random_blobs() == 64
      assert Transport.local_client_cache_maxsize() == 512
      assert Transport.max_pr_tags() == 32_000
    end

    test "job interval constants" do
      assert Transport.job_interval() == 250
      assert Transport.links_check_interval() == 1_000
      assert Transport.receipts_check_interval() == 1_000
      assert Transport.announces_check_interval() == 1_000
      assert Transport.tables_cull_interval() == 5_000
      assert Transport.interface_jobs_interval() == 5_000
      assert Transport.cache_clean_interval() == 300_000
    end
  end

  describe "ETS tables" do
    test "all ETS tables are created on init" do
      assert :ets.info(:rns_destinations) != :undefined
      assert :ets.info(:rns_pending_links) != :undefined
      assert :ets.info(:rns_active_links) != :undefined
      assert :ets.info(:rns_packet_hashlist) != :undefined
      assert :ets.info(:rns_receipts) != :undefined
      assert :ets.info(:rns_announce_table) != :undefined
      assert :ets.info(:rns_path_table) != :undefined
      assert :ets.info(:rns_reverse_table) != :undefined
      assert :ets.info(:rns_link_table) != :undefined
      assert :ets.info(:rns_held_announces) != :undefined
      assert :ets.info(:rns_tunnel_table) != :undefined
      assert :ets.info(:rns_announce_rate_table) != :undefined
      assert :ets.info(:rns_path_requests) != :undefined
      assert :ets.info(:rns_path_states) != :undefined
    end

    test "ETS tables are initially empty" do
      assert :ets.info(:rns_destinations, :size) == 0
      assert :ets.info(:rns_pending_links, :size) == 0
      assert :ets.info(:rns_active_links, :size) == 0
      assert :ets.info(:rns_packet_hashlist, :size) == 0
      assert :ets.info(:rns_path_table, :size) == 0
      assert :ets.info(:rns_announce_table, :size) == 0
      assert :ets.info(:rns_reverse_table, :size) == 0
      assert :ets.info(:rns_link_table, :size) == 0
      assert :ets.info(:rns_tunnel_table, :size) == 0
    end

    test "ETS tables have public read concurrency" do
      assert :ets.info(:rns_path_table, :protection) == :public
      assert :ets.info(:rns_destinations, :protection) == :public
    end
  end

  describe "register_destination/1" do
    test "registers an incoming destination" do
      dest = make_destination(:in)
      assert :ok == Transport.register_destination(dest)
      assert Transport.destination_registered?(dest.hash)
    end

    test "rejects duplicate destination registration" do
      dest = make_destination(:in)
      assert :ok == Transport.register_destination(dest)
      assert {:error, :already_registered} == Transport.register_destination(dest)
    end

    test "only registers incoming destinations" do
      dest = make_destination(:out)
      assert :ok == Transport.register_destination(dest)
      # OUT destinations still get registered but without the duplicate check
    end

    test "multiple different destinations can be registered" do
      dest1 = make_destination(:in)
      dest2 = make_destination(:in)
      assert :ok == Transport.register_destination(dest1)
      assert :ok == Transport.register_destination(dest2)
      assert Transport.destination_registered?(dest1.hash)
      assert Transport.destination_registered?(dest2.hash)
    end
  end

  describe "deregister_destination/1" do
    test "removes a registered destination" do
      dest = make_destination(:in)
      Transport.register_destination(dest)
      assert :ok == Transport.deregister_destination(dest)
      refute Transport.destination_registered?(dest.hash)
    end

    test "no-op for non-registered destination" do
      dest = make_destination(:in)
      assert :ok == Transport.deregister_destination(dest)
    end
  end

  describe "register_interface/1" do
    test "registers an interface" do
      iface = make_interface("TestInterface")
      assert :ok == Transport.register_interface(iface)
      assert Transport.interface_registered?(iface.hash)
    end

    test "multiple interfaces can be registered" do
      iface1 = make_interface("Interface1")
      iface2 = make_interface("Interface2")
      Transport.register_interface(iface1)
      Transport.register_interface(iface2)
      assert Transport.interface_registered?(iface1.hash)
      assert Transport.interface_registered?(iface2.hash)
    end
  end

  describe "deregister_interface/1" do
    test "removes a registered interface" do
      iface = make_interface("TestInterface")
      Transport.register_interface(iface)
      assert :ok == Transport.deregister_interface(iface)
      refute Transport.interface_registered?(iface.hash)
    end

    test "no-op for non-registered interface" do
      iface = make_interface("TestInterface")
      assert :ok == Transport.deregister_interface(iface)
    end
  end

  describe "has_path/1" do
    test "returns false for unknown destination" do
      hash = :crypto.strong_rand_bytes(16)
      refute Transport.has_path(hash)
    end

    test "returns true after path is added" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      assert Transport.has_path(hash)
    end
  end

  describe "hops_to/1" do
    test "returns PATHFINDER_M for unknown destination" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.hops_to(hash) == 128
    end

    test "returns correct hop count for known destination" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash, hops: 3)
      assert Transport.hops_to(hash) == 3
    end
  end

  describe "next_hop/1" do
    test "returns nil for unknown destination" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.next_hop(hash) == nil
    end

    test "returns correct next hop for known destination" do
      hash = :crypto.strong_rand_bytes(16)
      next_hop_hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash, next_hop: next_hop_hash)
      assert Transport.next_hop(hash) == next_hop_hash
    end
  end

  describe "next_hop_interface/1" do
    test "returns nil for unknown destination" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.next_hop_interface(hash) == nil
    end

    test "returns correct interface for known destination" do
      hash = :crypto.strong_rand_bytes(16)
      iface = make_interface("TestIface")
      Transport.register_interface(iface)
      add_path_entry(hash, interface: iface)
      assert Transport.next_hop_interface(hash) == iface
    end
  end

  describe "expire_path/1" do
    test "returns false for non-existent path" do
      hash = :crypto.strong_rand_bytes(16)
      refute Transport.expire_path(hash)
    end

    test "returns true and sets timestamp to 0 for existing path" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      assert Transport.expire_path(hash)
      # After expiring, the path entry still exists but with timestamp 0
      assert Transport.has_path(hash)
      entry = Transport.get_path_entry(hash)
      assert entry.timestamp == 0
    end
  end

  describe "mark_path_unresponsive/1" do
    test "returns false for non-existent path" do
      hash = :crypto.strong_rand_bytes(16)
      refute Transport.mark_path_unresponsive(hash)
    end

    test "marks an existing path as unresponsive" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      assert Transport.mark_path_unresponsive(hash)
      assert Transport.path_is_unresponsive(hash)
    end
  end

  describe "mark_path_responsive/1" do
    test "returns false for non-existent path" do
      hash = :crypto.strong_rand_bytes(16)
      refute Transport.mark_path_responsive(hash)
    end

    test "marks an existing path as responsive" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      Transport.mark_path_unresponsive(hash)
      assert Transport.mark_path_responsive(hash)
      refute Transport.path_is_unresponsive(hash)
    end
  end

  describe "mark_path_unknown_state/1" do
    test "returns false for non-existent path" do
      hash = :crypto.strong_rand_bytes(16)
      refute Transport.mark_path_unknown_state(hash)
    end

    test "resets path state to unknown" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      Transport.mark_path_unresponsive(hash)
      assert Transport.mark_path_unknown_state(hash)
      refute Transport.path_is_unresponsive(hash)
    end
  end

  describe "path_is_unresponsive/1" do
    test "returns false for unknown destination" do
      hash = :crypto.strong_rand_bytes(16)
      refute Transport.path_is_unresponsive(hash)
    end

    test "returns false for path in unknown state" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      refute Transport.path_is_unresponsive(hash)
    end

    test "returns true for unresponsive path" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      Transport.mark_path_unresponsive(hash)
      assert Transport.path_is_unresponsive(hash)
    end
  end

  describe "interfaces list" do
    test "get_interfaces returns empty list initially" do
      assert Transport.get_interfaces() == []
    end

    test "get_interfaces returns registered interfaces" do
      iface1 = make_interface("IF1")
      iface2 = make_interface("IF2")
      Transport.register_interface(iface1)
      Transport.register_interface(iface2)
      interfaces = Transport.get_interfaces()
      assert length(interfaces) == 2
    end
  end

  describe "destinations list" do
    test "get_destinations returns empty list initially" do
      assert Transport.get_destinations() == []
    end

    test "get_destinations returns registered destinations" do
      dest1 = make_destination(:in)
      dest2 = make_destination(:in)
      Transport.register_destination(dest1)
      Transport.register_destination(dest2)
      destinations = Transport.get_destinations()
      assert length(destinations) == 2
    end
  end

  describe "find_interface_from_hash/1" do
    test "returns nil for unknown hash" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.find_interface_from_hash(hash) == nil
    end

    test "returns interface with matching hash" do
      iface = make_interface("TestIface")
      Transport.register_interface(iface)
      assert Transport.find_interface_from_hash(iface.hash) == iface
    end
  end

  describe "save_path_table/1 and load_path_table/1" do
    test "round-trips path table to disk" do
      hash1 = :crypto.strong_rand_bytes(16)
      hash2 = :crypto.strong_rand_bytes(16)
      iface = make_interface("SaveTestIface")
      Transport.register_interface(iface)

      add_path_entry(hash1, hops: 2, next_hop: :crypto.strong_rand_bytes(16), interface: iface)
      add_path_entry(hash2, hops: 5, next_hop: :crypto.strong_rand_bytes(16), interface: iface)

      # Save to a temp file
      path =
        Path.join(System.tmp_dir!(), "rns_test_path_table_#{:erlang.unique_integer([:positive])}")

      assert :ok == Transport.save_path_table(path)

      # Clear the path table
      :ets.delete_all_objects(:rns_path_table)
      refute Transport.has_path(hash1)
      refute Transport.has_path(hash2)

      # Load it back
      assert :ok == Transport.load_path_table(path)
      assert Transport.has_path(hash1)
      assert Transport.has_path(hash2)
      assert Transport.hops_to(hash1) == 2
      assert Transport.hops_to(hash2) == 5

      # Clean up
      File.rm(path)
    end

    test "load_path_table returns error for missing file" do
      assert {:error, _} = Transport.load_path_table("/nonexistent/path")
    end

    test "save_path_table skips entries with no active interface" do
      hash = :crypto.strong_rand_bytes(16)
      # Add entry with an interface that is NOT registered
      unregistered_iface = make_interface("UnregisteredIface")
      add_path_entry(hash, interface: unregistered_iface)

      path =
        Path.join(
          System.tmp_dir!(),
          "rns_test_path_table_skip_#{:erlang.unique_integer([:positive])}"
        )

      assert :ok == Transport.save_path_table(path)

      :ets.delete_all_objects(:rns_path_table)
      Transport.load_path_table(path)

      # Should not have loaded the entry since interface was not active
      refute Transport.has_path(hash)
      File.rm(path)
    end

    test "load_path_table skips expired entries" do
      hash = :crypto.strong_rand_bytes(16)
      iface = make_interface("ExpiredTestIface")
      Transport.register_interface(iface)

      # Add an entry that's already expired
      add_path_entry(hash, interface: iface, expires: System.system_time(:second) - 100)

      path =
        Path.join(
          System.tmp_dir!(),
          "rns_test_path_table_expired_#{:erlang.unique_integer([:positive])}"
        )

      Transport.save_path_table(path)

      :ets.delete_all_objects(:rns_path_table)
      Transport.load_path_table(path)

      # Should not have loaded expired entry
      refute Transport.has_path(hash)
      File.rm(path)
    end
  end

  describe "packet hashlist" do
    test "packet_hash_known? returns false for unknown hash" do
      hash = :crypto.strong_rand_bytes(16)
      refute Transport.packet_hash_known?(hash)
    end

    test "mark_packet_hash marks a hash as known" do
      hash = :crypto.strong_rand_bytes(16)
      Transport.mark_packet_hash(hash)
      assert Transport.packet_hash_known?(hash)
    end
  end

  describe "announce_table operations" do
    test "get_announce_entry returns nil for unknown hash" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.get_announce_entry(hash) == nil
    end
  end

  describe "reverse_table operations" do
    test "get_reverse_entry returns nil for unknown hash" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.get_reverse_entry(hash) == nil
    end
  end

  describe "link_table operations" do
    test "get_link_entry returns nil for unknown hash" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.get_link_entry(hash) == nil
    end
  end

  # ── Task 4.3: Packet Routing and Delivery Tests ──────────────────────

  describe "link registration" do
    test "register_link adds initiator link to pending table" do
      link = %{link_id: :crypto.strong_rand_bytes(16), initiator: true, status: :pending}
      assert :ok == Transport.register_link(link)
      assert Transport.get_pending_links() |> Enum.any?(fn l -> l.link_id == link.link_id end)
    end

    test "register_link adds non-initiator link to active table" do
      link = %{link_id: :crypto.strong_rand_bytes(16), initiator: false, status: :active}
      assert :ok == Transport.register_link(link)
      assert Transport.get_active_links() |> Enum.any?(fn l -> l.link_id == link.link_id end)
    end

    test "activate_link moves pending link to active" do
      link_id = :crypto.strong_rand_bytes(16)
      link = %{link_id: link_id, initiator: true, status: :pending}
      Transport.register_link(link)

      activated_link = %{link | status: :active}
      assert :ok == Transport.activate_link(activated_link)

      assert Transport.get_pending_links() == []
      assert Transport.get_active_links() |> Enum.any?(fn l -> l.link_id == link_id end)
    end

    test "activate_link returns error for non-pending link" do
      link = %{link_id: :crypto.strong_rand_bytes(16), status: :active}
      assert {:error, :not_pending} == Transport.activate_link(link)
    end

    test "activate_link returns error for non-active status" do
      link_id = :crypto.strong_rand_bytes(16)
      link = %{link_id: link_id, initiator: true, status: :pending}
      Transport.register_link(link)

      assert {:error, :invalid_status} == Transport.activate_link(link)
    end

    test "find_link_for_request_packet finds pending link" do
      link_id = :crypto.strong_rand_bytes(16)
      link = %{link_id: link_id, initiator: true, status: :pending}
      Transport.register_link(link)

      packet = %{destination_hash: link_id}
      assert Transport.find_link_for_request_packet(packet) == link
    end

    test "find_link_for_request_packet returns nil when not found" do
      packet = %{destination_hash: :crypto.strong_rand_bytes(16)}
      assert Transport.find_link_for_request_packet(packet) == nil
    end

    test "find_best_link finds active link by destination hash" do
      link_id = :crypto.strong_rand_bytes(16)
      link = %{link_id: link_id, initiator: false, status: :active}
      Transport.register_link(link)

      assert Transport.find_best_link(link_id) == link
    end

    test "find_best_link returns nil when no active link found" do
      assert Transport.find_best_link(:crypto.strong_rand_bytes(16)) == nil
    end

    test "remove_pending_link deletes from pending table" do
      link_id = :crypto.strong_rand_bytes(16)
      Transport.register_link(%{link_id: link_id, initiator: true, status: :pending})
      Transport.remove_pending_link(link_id)
      assert Transport.get_pending_links() == []
    end

    test "remove_active_link deletes from active table" do
      link_id = :crypto.strong_rand_bytes(16)
      Transport.register_link(%{link_id: link_id, initiator: false, status: :active})
      Transport.remove_active_link(link_id)
      assert Transport.get_active_links() == []
    end
  end

  describe "reverse table operations" do
    test "put and get reverse entry" do
      hash = :crypto.strong_rand_bytes(16)
      iface1 = make_interface("RevIface1")
      iface2 = make_interface("RevIface2")

      entry = %Transport.ReverseEntry{
        received_on_interface: iface1,
        outbound_interface: iface2,
        timestamp: System.system_time(:second)
      }

      Transport.put_reverse_entry(hash, entry)
      assert Transport.get_reverse_entry(hash) == entry
    end

    test "delete_reverse_entry removes entry" do
      hash = :crypto.strong_rand_bytes(16)

      entry = %Transport.ReverseEntry{
        received_on_interface: nil,
        outbound_interface: nil,
        timestamp: System.system_time(:second)
      }

      Transport.put_reverse_entry(hash, entry)
      Transport.delete_reverse_entry(hash)
      assert Transport.get_reverse_entry(hash) == nil
    end

    test "pop_reverse_entry returns and removes entry" do
      hash = :crypto.strong_rand_bytes(16)

      entry = %Transport.ReverseEntry{
        received_on_interface: nil,
        outbound_interface: nil,
        timestamp: System.system_time(:second)
      }

      Transport.put_reverse_entry(hash, entry)
      assert Transport.pop_reverse_entry(hash) == entry
      assert Transport.get_reverse_entry(hash) == nil
    end

    test "pop_reverse_entry returns nil for missing entry" do
      assert Transport.pop_reverse_entry(:crypto.strong_rand_bytes(16)) == nil
    end
  end

  describe "link table operations" do
    test "put and get link entry" do
      link_id = :crypto.strong_rand_bytes(16)

      entry = %Transport.LinkEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        next_hop_interface: make_interface("LinkIface1"),
        remaining_hops: 3,
        received_on_interface: make_interface("LinkIface2"),
        taken_hops: 2,
        destination_hash: :crypto.strong_rand_bytes(16),
        validated: false,
        proof_timeout: System.system_time(:second) + 120
      }

      Transport.put_link_entry(link_id, entry)
      assert Transport.get_link_entry(link_id) == entry
    end

    test "delete_link_entry removes entry" do
      link_id = :crypto.strong_rand_bytes(16)

      entry = %Transport.LinkEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        next_hop_interface: nil,
        remaining_hops: 1,
        received_on_interface: nil,
        taken_hops: 1,
        destination_hash: :crypto.strong_rand_bytes(16),
        validated: false,
        proof_timeout: System.system_time(:second) + 60
      }

      Transport.put_link_entry(link_id, entry)
      Transport.delete_link_entry(link_id)
      assert Transport.get_link_entry(link_id) == nil
    end
  end

  describe "tunnel table operations" do
    test "put and get tunnel entry" do
      tunnel_id = :crypto.strong_rand_bytes(32)

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: make_interface("TunIface"),
        paths: %{},
        expires: System.system_time(:second) + 3600
      }

      Transport.put_tunnel_entry(tunnel_id, entry)
      assert Transport.get_tunnel_entry(tunnel_id) == entry
    end

    test "delete_tunnel_entry removes entry" do
      tunnel_id = :crypto.strong_rand_bytes(32)

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: nil,
        paths: %{},
        expires: System.system_time(:second) + 3600
      }

      Transport.put_tunnel_entry(tunnel_id, entry)
      Transport.delete_tunnel_entry(tunnel_id)
      assert Transport.get_tunnel_entry(tunnel_id) == nil
    end

    test "get_all_tunnels returns all entries" do
      t1 = :crypto.strong_rand_bytes(32)
      t2 = :crypto.strong_rand_bytes(32)

      e1 = %Transport.TunnelEntry{tunnel_id: t1, interface: nil, paths: %{}, expires: 0}
      e2 = %Transport.TunnelEntry{tunnel_id: t2, interface: nil, paths: %{}, expires: 0}

      Transport.put_tunnel_entry(t1, e1)
      Transport.put_tunnel_entry(t2, e2)

      tunnels = Transport.get_all_tunnels()
      assert length(tunnels) == 2
    end
  end

  describe "receipt management" do
    test "register and get receipt" do
      receipt = %{hash: :crypto.strong_rand_bytes(32), sent_at: System.system_time(:second)}
      Transport.register_receipt(receipt)
      assert Transport.get_receipt(receipt.hash) == receipt
    end

    test "remove_receipt deletes receipt" do
      receipt = %{hash: :crypto.strong_rand_bytes(32), sent_at: System.system_time(:second)}
      Transport.register_receipt(receipt)
      Transport.remove_receipt(receipt.hash)
      assert Transport.get_receipt(receipt.hash) == nil
    end

    test "get_all_receipts returns all" do
      r1 = %{hash: :crypto.strong_rand_bytes(32), sent_at: 1}
      r2 = %{hash: :crypto.strong_rand_bytes(32), sent_at: 2}
      Transport.register_receipt(r1)
      Transport.register_receipt(r2)
      assert Transport.receipt_count() == 2
      assert length(Transport.get_all_receipts()) == 2
    end

    test "receipt_count tracks count" do
      assert Transport.receipt_count() == 0
      r = %{hash: :crypto.strong_rand_bytes(32), sent_at: 1}
      Transport.register_receipt(r)
      assert Transport.receipt_count() == 1
    end
  end

  describe "path request tracking" do
    test "record and retrieve path request timestamp" do
      hash = :crypto.strong_rand_bytes(16)
      assert Transport.last_path_request(hash) == 0

      Transport.record_path_request(hash)
      ts = Transport.last_path_request(hash)
      assert ts > 0
      assert_in_delta ts, System.system_time(:second), 2
    end
  end

  describe "held announces" do
    test "put and get held announce" do
      hash = :crypto.strong_rand_bytes(16)
      entry = %{some: :data}
      Transport.put_held_announce(hash, entry)
      assert Transport.get_held_announce(hash) == entry
    end

    test "pop_held_announce returns and removes" do
      hash = :crypto.strong_rand_bytes(16)
      entry = %{some: :data}
      Transport.put_held_announce(hash, entry)
      assert Transport.pop_held_announce(hash) == entry
      assert Transport.get_held_announce(hash) == nil
    end

    test "pop_held_announce returns nil for missing" do
      assert Transport.pop_held_announce(:crypto.strong_rand_bytes(16)) == nil
    end
  end

  describe "packet_filter/2" do
    test "accepts all packets when shared instance" do
      packet = make_filter_packet()
      assert Transport.packet_filter(packet, is_shared_instance: true)
    end

    test "rejects packet for other transport instance" do
      other_hash = :crypto.strong_rand_bytes(16)
      my_hash = :crypto.strong_rand_bytes(16)

      packet = %{
        make_filter_packet()
        | transport_id: other_hash,
          packet_type: 0x00
      }

      refute Transport.packet_filter(packet, transport_identity_hash: my_hash)
    end

    test "allows announce packets even with different transport_id" do
      other_hash = :crypto.strong_rand_bytes(16)
      my_hash = :crypto.strong_rand_bytes(16)

      packet = %{
        make_filter_packet()
        | transport_id: other_hash,
          packet_type: 0x01
      }

      # Announce packets bypass the transport_id check
      assert Transport.packet_filter(packet, transport_identity_hash: my_hash)
    end

    test "allows passthrough contexts" do
      for context <- [0xFA, 0x03, 0x05, 0x01, 0x08, 0x0E] do
        packet = %{make_filter_packet() | context: context}
        assert Transport.packet_filter(packet), "context #{context} should pass"
      end
    end

    test "rejects PLAIN destination announces" do
      packet = %{make_filter_packet() | destination_type: 0x02, packet_type: 0x01}
      refute Transport.packet_filter(packet)
    end

    test "allows PLAIN destination data with 1 hop or less" do
      packet = %{make_filter_packet() | destination_type: 0x02, packet_type: 0x00, hops: 1}
      assert Transport.packet_filter(packet)
    end

    test "rejects PLAIN destination data with more than 1 hop" do
      packet = %{make_filter_packet() | destination_type: 0x02, packet_type: 0x00, hops: 2}
      refute Transport.packet_filter(packet)
    end

    test "rejects GROUP destination announces" do
      packet = %{make_filter_packet() | destination_type: 0x01, packet_type: 0x01}
      refute Transport.packet_filter(packet)
    end

    test "allows GROUP destination data with 1 hop or less" do
      packet = %{make_filter_packet() | destination_type: 0x01, packet_type: 0x00, hops: 1}
      assert Transport.packet_filter(packet)
    end

    test "rejects GROUP destination data with more than 1 hop" do
      packet = %{make_filter_packet() | destination_type: 0x01, packet_type: 0x00, hops: 2}
      refute Transport.packet_filter(packet)
    end

    test "accepts unknown packet hash" do
      packet = make_filter_packet()
      assert Transport.packet_filter(packet)
    end

    test "rejects known packet hash (duplicate)" do
      packet = make_filter_packet()
      Transport.mark_packet_hash(packet.packet_hash)
      refute Transport.packet_filter(packet)
    end

    test "allows known hash for SINGLE announces (path updates)" do
      packet = %{
        make_filter_packet()
        | packet_type: 0x01,
          destination_type: 0x00
      }

      Transport.mark_packet_hash(packet.packet_hash)
      assert Transport.packet_filter(packet)
    end
  end

  describe "transmit/2" do
    test "calls process_outgoing function on interface" do
      test_pid = self()

      interface = %{
        process_outgoing: fn raw ->
          send(test_pid, {:transmitted, raw})
        end,
        ifac_identity: nil
      }

      raw = <<0x00, 0x01, 0x02, 0x03>>
      assert :ok == Transport.transmit(interface, raw)
      assert_receive {:transmitted, ^raw}
    end

    test "sends to pid-based interface" do
      test_pid = self()

      interface = %{
        pid: test_pid,
        ifac_identity: nil
      }

      raw = <<0x00, 0x01, 0x02, 0x03>>
      assert :ok == Transport.transmit(interface, raw)
      assert_receive {:process_outgoing, ^raw}
    end

    test "returns error for interface with no handler" do
      interface = %{ifac_identity: nil}
      assert {:error, :no_handler} == Transport.transmit(interface, <<0x00>>)
    end

    test "transmit with IFAC masking" do
      identity = RNS.Identity.new()
      test_pid = self()

      interface = %{
        ifac_identity: identity,
        ifac_size: 2,
        ifac_key: :crypto.strong_rand_bytes(32),
        process_outgoing: fn raw ->
          send(test_pid, {:transmitted, raw})
        end
      }

      raw = <<0x00, 0x01, 0x02, 0x03, 0x04, 0x05>>
      assert :ok == Transport.transmit(interface, raw)
      assert_receive {:transmitted, masked_raw}

      # Masked raw should have IFAC flag set (0x80) in first byte
      <<first_byte, _rest::binary>> = masked_raw
      assert (first_byte &&& 0x80) == 0x80

      # Masked raw should be longer due to IFAC insertion
      assert byte_size(masked_raw) == byte_size(raw) + interface.ifac_size
    end
  end

  describe "outbound/2" do
    test "broadcasts on all interfaces when no path exists" do
      test_pid = self()

      iface =
        make_interface("OutIface1")
        |> Map.merge(%{
          out: true,
          process_outgoing: fn raw -> send(test_pid, {:sent_on, "OutIface1", raw}) end
        })

      Transport.register_interface(iface)

      packet = %{
        destination_hash: :crypto.strong_rand_bytes(16),
        packet_type: 0x00,
        destination_type: 0x00,
        header_type: 0x00,
        packet_hash: :crypto.strong_rand_bytes(32),
        raw: <<0x00, 0x01>> <> :crypto.strong_rand_bytes(20),
        context: 0x00,
        flags: 0x00,
        attached_interface: nil,
        create_receipt: false
      }

      assert Transport.outbound(packet)
      assert_receive {:sent_on, "OutIface1", _raw}
    end

    test "routes via path table when path exists with single hop" do
      test_pid = self()
      dest_hash = :crypto.strong_rand_bytes(16)

      iface =
        make_interface("PathIface")
        |> Map.put(:process_outgoing, fn raw -> send(test_pid, {:sent_via_path, raw}) end)

      Transport.register_interface(iface)
      add_path_entry(dest_hash, hops: 1, interface: iface)

      packet = %{
        destination_hash: dest_hash,
        packet_type: 0x00,
        destination_type: 0x00,
        header_type: 0x00,
        packet_hash: :crypto.strong_rand_bytes(32),
        raw: <<0x00, 0x01>> <> :crypto.strong_rand_bytes(20),
        context: 0x00,
        flags: 0x00,
        attached_interface: nil,
        create_receipt: false
      }

      assert Transport.outbound(packet)
      assert_receive {:sent_via_path, _raw}
    end

    test "broadcasts announces (skips path table)" do
      test_pid = self()
      dest_hash = :crypto.strong_rand_bytes(16)

      iface =
        make_interface("AnnIface")
        |> Map.merge(%{
          out: true,
          process_outgoing: fn raw -> send(test_pid, {:announce_sent, raw}) end
        })

      Transport.register_interface(iface)
      add_path_entry(dest_hash, hops: 3, interface: iface)

      packet = %{
        destination_hash: dest_hash,
        packet_type: 0x01,
        destination_type: 0x00,
        header_type: 0x00,
        packet_hash: :crypto.strong_rand_bytes(32),
        raw: <<0x00, 0x01>> <> :crypto.strong_rand_bytes(20),
        context: 0x00,
        flags: 0x00,
        attached_interface: nil,
        create_receipt: false
      }

      assert Transport.outbound(packet)
      assert_receive {:announce_sent, _raw}
    end
  end

  describe "forward/2" do
    test "returns :no_path when path doesn't exist" do
      packet = %{
        destination_hash: :crypto.strong_rand_bytes(16),
        raw: <<0x40, 0x01>> <> :crypto.strong_rand_bytes(30),
        hops: 1,
        flags: 0x40,
        packet_type: 0x00,
        receiving_interface: nil,
        data: :crypto.strong_rand_bytes(32),
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      assert :no_path == Transport.forward(packet)
    end

    test "forwards packet to next hop via path table" do
      test_pid = self()
      dest_hash = :crypto.strong_rand_bytes(16)
      next_hop = :crypto.strong_rand_bytes(16)

      iface =
        make_interface("FwdIface")
        |> Map.put(:process_outgoing, fn raw -> send(test_pid, {:forwarded, raw}) end)

      Transport.register_interface(iface)
      add_path_entry(dest_hash, hops: 3, next_hop: next_hop, interface: iface)

      packet = %RNS.Packet{
        destination_hash: dest_hash,
        raw: <<0x40, 0x01>> <> :crypto.strong_rand_bytes(30),
        hops: 1,
        flags: 0x40,
        header_type: 0x01,
        packet_type: 0x00,
        receiving_interface: make_interface("InIface"),
        data: :crypto.strong_rand_bytes(40),
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      assert :ok == Transport.forward(packet)
      assert_receive {:forwarded, _raw}
    end

    test "records reverse entry for non-linkrequest packets" do
      test_pid = self()
      dest_hash = :crypto.strong_rand_bytes(16)

      iface =
        make_interface("RevFwdIface")
        |> Map.put(:process_outgoing, fn _raw -> send(test_pid, :forwarded) end)

      Transport.register_interface(iface)
      add_path_entry(dest_hash, hops: 2, interface: iface)

      # Build a proper packet that looks like a real HEADER_2 data packet
      recv_iface = make_interface("RecvIface")

      packet = %RNS.Packet{
        destination_hash: dest_hash,
        raw: <<0x40, 0x01>> <> :crypto.strong_rand_bytes(40),
        hops: 1,
        flags: 0x40,
        header_type: 0x01,
        packet_type: 0x00,
        receiving_interface: recv_iface,
        data: :crypto.strong_rand_bytes(32),
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      Transport.forward(packet)
      assert_receive :forwarded

      # Verify a reverse entry was created (for proof routing)
      # The truncated hash is based on the packet's hashable part
      truncated = RNS.Packet.get_truncated_hash(packet)
      rev = Transport.get_reverse_entry(truncated)
      assert rev != nil
      assert rev.received_on_interface == recv_iface
    end
  end

  describe "table culling" do
    test "cull_path_states removes orphaned states" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      Transport.mark_path_unresponsive(hash)
      assert Transport.path_is_unresponsive(hash)

      # Remove path entry, state should be orphaned
      :ets.delete(:rns_path_table, hash)
      Transport.cull_path_states()
      refute Transport.path_is_unresponsive(hash)
    end

    test "cull_path_states keeps states for active paths" do
      hash = :crypto.strong_rand_bytes(16)
      add_path_entry(hash)
      Transport.mark_path_unresponsive(hash)

      Transport.cull_path_states()
      assert Transport.path_is_unresponsive(hash)
    end

    test "cull_reverse_table removes expired entries" do
      hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      entry = %Transport.ReverseEntry{
        received_on_interface: make_interface("CullRevIface1"),
        outbound_interface: make_interface("CullRevIface2"),
        timestamp: now - Transport.reverse_timeout() - 10
      }

      Transport.register_interface(entry.received_on_interface)
      Transport.register_interface(entry.outbound_interface)
      Transport.put_reverse_entry(hash, entry)

      Transport.cull_reverse_table(now)
      assert Transport.get_reverse_entry(hash) == nil
    end

    test "cull_reverse_table keeps fresh entries" do
      hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)
      iface1 = make_interface("FreshRevIface1")
      iface2 = make_interface("FreshRevIface2")

      Transport.register_interface(iface1)
      Transport.register_interface(iface2)

      entry = %Transport.ReverseEntry{
        received_on_interface: iface1,
        outbound_interface: iface2,
        timestamp: now
      }

      Transport.put_reverse_entry(hash, entry)

      Transport.cull_reverse_table(now)
      assert Transport.get_reverse_entry(hash) != nil
    end

    test "cull_link_table removes unvalidated entries past proof timeout" do
      link_id = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      entry = %Transport.LinkEntry{
        timestamp: now - 200,
        next_hop: :crypto.strong_rand_bytes(16),
        next_hop_interface: make_interface("CullLinkIface1"),
        remaining_hops: 2,
        received_on_interface: make_interface("CullLinkIface2"),
        taken_hops: 1,
        destination_hash: :crypto.strong_rand_bytes(16),
        validated: false,
        proof_timeout: now - 10
      }

      Transport.register_interface(entry.next_hop_interface)
      Transport.register_interface(entry.received_on_interface)
      Transport.put_link_entry(link_id, entry)

      Transport.cull_link_table(now)
      assert Transport.get_link_entry(link_id) == nil
    end

    test "cull_link_table removes validated entries past link timeout" do
      link_id = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)
      iface1 = make_interface("CullVLinkIface1")
      iface2 = make_interface("CullVLinkIface2")

      Transport.register_interface(iface1)
      Transport.register_interface(iface2)

      entry = %Transport.LinkEntry{
        timestamp: now - Transport.link_timeout() - 10,
        next_hop: :crypto.strong_rand_bytes(16),
        next_hop_interface: iface1,
        remaining_hops: 2,
        received_on_interface: iface2,
        taken_hops: 1,
        destination_hash: :crypto.strong_rand_bytes(16),
        validated: true,
        proof_timeout: now + 1000
      }

      Transport.put_link_entry(link_id, entry)

      Transport.cull_link_table(now)
      assert Transport.get_link_entry(link_id) == nil
    end

    test "cull_link_table keeps fresh validated entries" do
      link_id = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)
      iface1 = make_interface("KeepLinkIface1")
      iface2 = make_interface("KeepLinkIface2")

      Transport.register_interface(iface1)
      Transport.register_interface(iface2)

      entry = %Transport.LinkEntry{
        timestamp: now,
        next_hop: :crypto.strong_rand_bytes(16),
        next_hop_interface: iface1,
        remaining_hops: 2,
        received_on_interface: iface2,
        taken_hops: 1,
        destination_hash: :crypto.strong_rand_bytes(16),
        validated: true,
        proof_timeout: now + 1000
      }

      Transport.put_link_entry(link_id, entry)

      Transport.cull_link_table(now)
      assert Transport.get_link_entry(link_id) != nil
    end

    test "cull_tunnel_table removes expired tunnels" do
      tunnel_id = :crypto.strong_rand_bytes(32)
      now = System.system_time(:second)

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: nil,
        paths: %{},
        expires: now - 10
      }

      Transport.put_tunnel_entry(tunnel_id, entry)

      Transport.cull_tunnel_table(now)
      assert Transport.get_tunnel_entry(tunnel_id) == nil
    end

    test "cull_tunnel_table keeps active tunnels" do
      tunnel_id = :crypto.strong_rand_bytes(32)
      now = System.system_time(:second)

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: nil,
        paths: %{},
        expires: now + 3600
      }

      Transport.put_tunnel_entry(tunnel_id, entry)

      Transport.cull_tunnel_table(now)
      assert Transport.get_tunnel_entry(tunnel_id) != nil
    end
  end

  describe "inbound/3" do
    test "drops packets that are too short" do
      assert :dropped == Transport.inbound(<<0x00, 0x01>>, nil)
    end

    test "drops packets with IFAC flag but no interface IFAC" do
      # Set IFAC flag (0x80) in first byte
      raw = <<0x80, 0x01, 0x02, 0x03, 0x04, 0x05>>
      interface = %{ifac_identity: nil}
      assert :dropped == Transport.inbound(raw, interface)
    end

    test "drops packets without IFAC flag when interface requires IFAC" do
      identity = RNS.Identity.new()
      raw = <<0x00, 0x01, 0x02, 0x03, 0x04, 0x05>>

      interface = %{
        ifac_identity: identity,
        ifac_size: 2,
        ifac_key: :crypto.strong_rand_bytes(32)
      }

      assert :dropped == Transport.inbound(raw, interface)
    end

    test "processes valid packet without IFAC" do
      # Build a valid HEADER_1 DATA packet
      dest_hash = :crypto.strong_rand_bytes(16)
      # flags: header_1(0) | broadcast(0) | single(0) | data(0)
      flags = 0x00
      hops = 0x00
      context = 0x00
      data = :crypto.strong_rand_bytes(10)
      raw = <<flags, hops>> <> dest_hash <> <<context>> <> data

      interface = %{ifac_identity: nil}
      result = Transport.inbound(raw, interface)

      # Should process successfully (returns :ok since no local destination matches)
      assert result == :ok
    end
  end

  describe "periodic jobs" do
    test "start_jobs enables the job scheduler" do
      Transport.start_jobs()
      # Give it a moment to process the cast
      Process.sleep(50)

      # Verify the GenServer is still alive (jobs didn't crash it)
      assert Process.alive?(GenServer.whereis(RNS.Transport))
    end

    test "jobs tick processes without crashing" do
      # Start jobs and let a tick happen
      Transport.start_jobs()
      Process.sleep(300)

      # Transport should still be alive
      assert Process.alive?(GenServer.whereis(RNS.Transport))
    end
  end

  describe "internal_inbound/2" do
    test "delivers data packet to registered destination" do
      test_pid = self()
      dest_hash = :crypto.strong_rand_bytes(16)

      dest = %{
        hash: dest_hash,
        direction: 0x11,
        type: 0x00,
        receive_packet: fn packet ->
          send(test_pid, {:received, packet.destination_hash})
          true
        end,
        proof_strategy: nil
      }

      Transport.register_destination(dest)

      packet = %{
        destination_hash: dest_hash,
        destination_type: 0x00,
        packet_type: 0x00,
        transport_id: nil,
        context: 0x00,
        hops: 1,
        packet_hash: :crypto.strong_rand_bytes(32),
        receiving_interface: nil,
        data: :crypto.strong_rand_bytes(20),
        raw: <<0x00, 0x01>> <> :crypto.strong_rand_bytes(30),
        flags: 0x00,
        header_type: 0x00,
        context_flag: 0
      }

      Transport.internal_inbound(packet)
      assert_receive {:received, ^dest_hash}
    end

    test "delivers link data to active link" do
      test_pid = self()
      link_id = :crypto.strong_rand_bytes(16)

      link = %{
        link_id: link_id,
        initiator: false,
        status: :active,
        attached_interface: nil,
        receive: fn packet ->
          send(test_pid, {:link_received, packet.destination_hash})
        end
      }

      Transport.register_link(link)

      packet = %{
        destination_hash: link_id,
        destination_type: 0x03,
        packet_type: 0x00,
        transport_id: nil,
        context: 0x00,
        hops: 1,
        packet_hash: :crypto.strong_rand_bytes(32),
        receiving_interface: nil,
        data: :crypto.strong_rand_bytes(20),
        raw: <<0x00, 0x01>> <> :crypto.strong_rand_bytes(30),
        flags: 0x00,
        header_type: 0x00,
        context_flag: 0
      }

      Transport.internal_inbound(packet)
      assert_receive {:link_received, ^link_id}
    end

    test "delivers link request to matching destination" do
      test_pid = self()
      dest_hash = :crypto.strong_rand_bytes(16)

      dest = %{
        hash: dest_hash,
        direction: 0x11,
        type: 0x00,
        receive_packet: fn packet ->
          send(test_pid, {:link_request, packet.destination_hash})
          true
        end
      }

      Transport.register_destination(dest)

      packet = %{
        destination_hash: dest_hash,
        destination_type: 0x00,
        packet_type: 0x02,
        transport_id: nil,
        context: 0x00,
        hops: 1,
        packet_hash: :crypto.strong_rand_bytes(32),
        receiving_interface: nil,
        data: :crypto.strong_rand_bytes(20),
        raw: <<0x00, 0x01>> <> :crypto.strong_rand_bytes(30),
        flags: 0x00,
        header_type: 0x00,
        context_flag: 0
      }

      Transport.internal_inbound(packet)
      assert_receive {:link_request, ^dest_hash}
    end
  end

  describe "TunnelManagement" do
    alias RNS.Transport.TunnelManagement

    test "handle_tunnel creates new tunnel entry" do
      tunnel_id = :crypto.strong_rand_bytes(32)
      iface = make_interface("TunnelIface")

      TunnelManagement.handle_tunnel(tunnel_id, iface)

      entry = Transport.get_tunnel_entry(tunnel_id)
      assert entry != nil
      assert entry.tunnel_id == tunnel_id
      assert entry.interface == iface
      assert entry.paths == %{}
      assert entry.expires > System.system_time(:second)
    end

    test "handle_tunnel updates existing tunnel" do
      tunnel_id = :crypto.strong_rand_bytes(32)
      iface1 = make_interface("TunIface1")
      iface2 = make_interface("TunIface2")

      TunnelManagement.handle_tunnel(tunnel_id, iface1)
      TunnelManagement.handle_tunnel(tunnel_id, iface2)

      entry = Transport.get_tunnel_entry(tunnel_id)
      assert entry.interface == iface2
    end

    test "handle_tunnel restores valid paths from existing tunnel" do
      tunnel_id = :crypto.strong_rand_bytes(32)
      dest_hash = :crypto.strong_rand_bytes(16)
      iface = make_interface("RestoreIface")

      # Create initial tunnel with stored paths
      path_entry = %Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 2,
        expires: System.system_time(:second) + 3600,
        random_blobs: [],
        interface: iface,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      initial_entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: iface,
        paths: %{dest_hash => path_entry},
        expires: System.system_time(:second) + 3600
      }

      Transport.put_tunnel_entry(tunnel_id, initial_entry)

      # Simulate tunnel reappearing with new interface
      new_iface = make_interface("NewRestoreIface")
      TunnelManagement.handle_tunnel(tunnel_id, new_iface)

      # Path should be restored
      restored = Transport.get_path_entry(dest_hash)
      assert restored != nil
      assert restored.hops == 2
      assert restored.interface == new_iface
    end

    test "handle_tunnel does not restore expired paths" do
      tunnel_id = :crypto.strong_rand_bytes(32)
      dest_hash = :crypto.strong_rand_bytes(16)
      iface = make_interface("ExpiredPathIface")

      expired_path = %Transport.PathEntry{
        timestamp: System.system_time(:second) - 100,
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 2,
        expires: System.system_time(:second) - 50,
        random_blobs: [],
        interface: iface,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      initial_entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: iface,
        paths: %{dest_hash => expired_path},
        expires: System.system_time(:second) + 3600
      }

      Transport.put_tunnel_entry(tunnel_id, initial_entry)

      new_iface = make_interface("NewExpPathIface")
      TunnelManagement.handle_tunnel(tunnel_id, new_iface)

      # Expired path should NOT be restored
      assert Transport.get_path_entry(dest_hash) == nil
    end

    test "void_tunnel_interface sets interface to nil" do
      tunnel_id = :crypto.strong_rand_bytes(32)
      iface = make_interface("VoidIface")

      TunnelManagement.handle_tunnel(tunnel_id, iface)
      entry = Transport.get_tunnel_entry(tunnel_id)
      assert entry.interface == iface

      TunnelManagement.void_tunnel_interface(tunnel_id)
      entry = Transport.get_tunnel_entry(tunnel_id)
      assert entry.interface == nil
    end

    test "void_tunnel_interface is no-op for unknown tunnel" do
      assert :ok == TunnelManagement.void_tunnel_interface(:crypto.strong_rand_bytes(32))
    end

    test "tunnel_synthesize_handler rejects invalid data length" do
      assert :invalid == TunnelManagement.tunnel_synthesize_handler(<<1, 2, 3>>, %{})
    end

    test "tunnel_synthesize_handler validates and creates tunnel with valid data" do
      identity = RNS.Identity.new()
      public_key = RNS.Identity.get_public_key(identity)
      interface_hash = :crypto.strong_rand_bytes(32)
      random_hash = :crypto.strong_rand_bytes(16)

      tunnel_id_data = public_key <> interface_hash
      signed_data = tunnel_id_data <> random_hash
      signature = RNS.Identity.sign(identity, signed_data)

      data = public_key <> interface_hash <> random_hash <> signature
      iface = make_interface("SynthIface")
      packet = %{receiving_interface: iface}

      assert :ok == TunnelManagement.tunnel_synthesize_handler(data, packet)

      # Verify tunnel was created
      tunnel_id = RNS.Identity.full_hash(tunnel_id_data)
      entry = Transport.get_tunnel_entry(tunnel_id)
      assert entry != nil
      assert entry.interface == iface
    end

    test "tunnel_synthesize_handler rejects invalid signature" do
      identity = RNS.Identity.new()
      public_key = RNS.Identity.get_public_key(identity)
      interface_hash = :crypto.strong_rand_bytes(32)
      random_hash = :crypto.strong_rand_bytes(16)

      # Use random bytes as a bad signature
      bad_signature = :crypto.strong_rand_bytes(64)

      data = public_key <> interface_hash <> random_hash <> bad_signature
      packet = %{receiving_interface: nil}

      assert :invalid == TunnelManagement.tunnel_synthesize_handler(data, packet)
    end
  end

  describe "Identity.validate_announce/1" do
    test "validates a properly signed announce" do
      identity = RNS.Identity.new()
      public_key = RNS.Identity.get_public_key(identity)
      name_hash = :crypto.strong_rand_bytes(10)
      random_blob = :crypto.strong_rand_bytes(10)
      destination_hash = RNS.Identity.truncated_hash(name_hash <> identity.hash)

      signed_data = destination_hash <> public_key <> name_hash <> random_blob <> <<>>
      signature = RNS.Identity.sign(identity, signed_data)

      data = public_key <> name_hash <> random_blob <> signature
      packet = %{destination_hash: destination_hash, data: data, context_flag: 0}

      assert RNS.Identity.validate_announce(packet)
    end

    test "rejects announce with invalid signature" do
      identity = RNS.Identity.new()
      public_key = RNS.Identity.get_public_key(identity)
      name_hash = :crypto.strong_rand_bytes(10)
      random_blob = :crypto.strong_rand_bytes(10)
      destination_hash = :crypto.strong_rand_bytes(16)

      bad_sig = :crypto.strong_rand_bytes(64)

      data = public_key <> name_hash <> random_blob <> bad_sig
      packet = %{destination_hash: destination_hash, data: data, context_flag: 0}

      refute RNS.Identity.validate_announce(packet)
    end

    test "rejects malformed announce data" do
      packet = %{
        destination_hash: :crypto.strong_rand_bytes(16),
        data: <<1, 2, 3>>,
        context_flag: 0
      }

      refute RNS.Identity.validate_announce(packet)
    end
  end

  describe "CacheManagement" do
    alias RNS.Transport.CacheManagement

    setup do
      # Create a temp directory for cache tests
      tmp_dir = Path.join(System.tmp_dir!(), "rns_test_cache_#{:rand.uniform(999_999)}")
      File.mkdir_p!(tmp_dir)
      storage_dir = Path.join(tmp_dir, "storage")
      File.mkdir_p!(storage_dir)
      cache_dir = Path.join(storage_dir, "cache")
      File.mkdir_p!(cache_dir)
      announces_dir = Path.join(cache_dir, "announces")
      File.mkdir_p!(announces_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{
        tmp_dir: tmp_dir,
        storage_dir: storage_dir,
        cache_dir: cache_dir,
        announces_dir: announces_dir
      }
    end

    # ── should_cache ──────────────────────────────────────────────

    test "should_cache always returns false (caching disabled)" do
      refute CacheManagement.should_cache(%{})
      refute CacheManagement.should_cache(%{context: 0x05})
    end

    # ── cache/2 ───────────────────────────────────────────────────

    test "cache does nothing when should_cache is false and force_cache is false" do
      packet = %{raw: <<1, 2, 3>>, receiving_interface: nil}
      assert :ok == CacheManagement.cache(packet)
    end

    test "cache writes packet to disk when force_cache is true", %{cache_dir: cache_dir} do
      Application.put_env(:rns_ex, :cachepath, cache_dir)

      raw = :crypto.strong_rand_bytes(30)
      packet_hash = :crypto.hash(:sha256, raw)
      packet = %RNS.Packet{raw: raw, receiving_interface: nil}
      packet = %{packet | packet_hash: packet_hash}

      assert :ok == CacheManagement.cache(packet, force_cache: true)

      hex_hash = Base.encode16(packet_hash, case: :lower)
      assert File.exists?(Path.join(cache_dir, hex_hash))

      Application.delete_env(:rns_ex, :cachepath)
    end

    test "cache writes announce to announces subdirectory", %{cache_dir: cache_dir} do
      Application.put_env(:rns_ex, :cachepath, cache_dir)

      raw = :crypto.strong_rand_bytes(30)
      packet_hash = :crypto.hash(:sha256, raw)
      packet = %RNS.Packet{raw: raw, receiving_interface: nil}
      packet = %{packet | packet_hash: packet_hash}

      assert :ok == CacheManagement.cache(packet, force_cache: true, packet_type: "announce")

      hex_hash = Base.encode16(packet_hash, case: :lower)
      assert File.exists?(Path.join([cache_dir, "announces", hex_hash]))

      Application.delete_env(:rns_ex, :cachepath)
    end

    # ── get_cached_packet ─────────────────────────────────────────

    test "get_cached_packet returns nil for non-existent hash", %{cache_dir: cache_dir} do
      Application.put_env(:rns_ex, :cachepath, cache_dir)

      assert CacheManagement.get_cached_packet(:crypto.strong_rand_bytes(32)) == nil

      Application.delete_env(:rns_ex, :cachepath)
    end

    test "cache and get_cached_packet roundtrip", %{cache_dir: cache_dir} do
      Application.put_env(:rns_ex, :cachepath, cache_dir)

      raw = :crypto.strong_rand_bytes(30)
      packet_hash = :crypto.hash(:sha256, raw)
      packet = %RNS.Packet{raw: raw, receiving_interface: nil}
      packet = %{packet | packet_hash: packet_hash}

      CacheManagement.cache(packet, force_cache: true)

      retrieved = CacheManagement.get_cached_packet(packet_hash)
      assert retrieved != nil
      assert retrieved.raw == raw

      Application.delete_env(:rns_ex, :cachepath)
    end

    test "get_cached_packet retrieves announce type", %{cache_dir: cache_dir} do
      Application.put_env(:rns_ex, :cachepath, cache_dir)

      raw = :crypto.strong_rand_bytes(30)
      packet_hash = :crypto.hash(:sha256, raw)
      packet = %RNS.Packet{raw: raw, receiving_interface: nil}
      packet = %{packet | packet_hash: packet_hash}

      CacheManagement.cache(packet, force_cache: true, packet_type: "announce")

      retrieved = CacheManagement.get_cached_packet(packet_hash, packet_type: "announce")
      assert retrieved != nil
      assert retrieved.raw == raw

      Application.delete_env(:rns_ex, :cachepath)
    end

    # ── cache_request_packet ──────────────────────────────────────

    test "cache_request_packet returns false for wrong data length" do
      packet = %{data: <<1, 2, 3>>}
      refute CacheManagement.cache_request_packet(packet)
    end

    test "cache_request_packet returns false when cache miss" do
      # HASHLENGTH/8 = 32 bytes
      packet = %{data: :crypto.strong_rand_bytes(32)}
      refute CacheManagement.cache_request_packet(packet)
    end

    # ── save_packet_hashlist / load_packet_hashlist ────────────────

    test "save_packet_hashlist roundtrip", %{storage_dir: storage_dir} do
      # Insert some hashes
      h1 = :crypto.strong_rand_bytes(32)
      h2 = :crypto.strong_rand_bytes(32)
      h3 = :crypto.strong_rand_bytes(32)
      Transport.mark_packet_hash(h1)
      Transport.mark_packet_hash(h2)
      Transport.mark_packet_hash(h3)

      file_path = Path.join(storage_dir, "packet_hashlist")
      assert :ok == CacheManagement.save_packet_hashlist(file_path)
      assert File.exists?(file_path)

      # Clear the hashlist table
      :ets.delete_all_objects(:rns_packet_hashlist)
      refute Transport.packet_hash_known?(h1)

      # Load it back
      assert :ok == CacheManagement.load_packet_hashlist(file_path)
      assert Transport.packet_hash_known?(h1)
      assert Transport.packet_hash_known?(h2)
      assert Transport.packet_hash_known?(h3)
    end

    test "load_packet_hashlist returns error for non-existent file" do
      assert {:error, :enoent} ==
               CacheManagement.load_packet_hashlist(
                 "/tmp/nonexistent_hashlist_#{:rand.uniform(999_999)}"
               )
    end

    test "save_packet_hashlist with empty hashlist", %{storage_dir: storage_dir} do
      file_path = Path.join(storage_dir, "empty_hashlist")
      assert :ok == CacheManagement.save_packet_hashlist(file_path)
      assert File.exists?(file_path)

      # Load it back (no-op but should work)
      assert :ok == CacheManagement.load_packet_hashlist(file_path)
    end

    # ── save_tunnel_table / load_tunnel_table ─────────────────────

    test "save_tunnel_table roundtrip", %{storage_dir: storage_dir} do
      tunnel_id = :crypto.strong_rand_bytes(32)
      dest_hash = :crypto.strong_rand_bytes(16)

      path_entry = %Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 3,
        expires: System.system_time(:second) + 7200,
        random_blobs: [:crypto.strong_rand_bytes(10)],
        interface: nil,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: nil,
        paths: %{dest_hash => path_entry},
        expires: System.system_time(:second) + 7200
      }

      Transport.put_tunnel_entry(tunnel_id, entry)

      file_path = Path.join(storage_dir, "tunnels")
      assert :ok == CacheManagement.save_tunnel_table(file_path)
      assert File.exists?(file_path)

      # Clear and reload
      :ets.delete_all_objects(:rns_tunnel_table)
      assert Transport.get_tunnel_entry(tunnel_id) == nil

      assert :ok == CacheManagement.load_tunnel_table(file_path)

      loaded = Transport.get_tunnel_entry(tunnel_id)
      assert loaded != nil
      assert loaded.tunnel_id == tunnel_id
      assert Map.has_key?(loaded.paths, dest_hash)

      loaded_path = loaded.paths[dest_hash]
      assert loaded_path.hops == 3
      assert loaded_path.next_hop == path_entry.next_hop
    end

    test "load_tunnel_table returns error for non-existent file" do
      assert {:error, :enoent} ==
               CacheManagement.load_tunnel_table(
                 "/tmp/nonexistent_tunnels_#{:rand.uniform(999_999)}"
               )
    end

    test "save_tunnel_table with empty table", %{storage_dir: storage_dir} do
      file_path = Path.join(storage_dir, "empty_tunnels")
      assert :ok == CacheManagement.save_tunnel_table(file_path)

      # Load back - should be empty
      assert :ok == CacheManagement.load_tunnel_table(file_path)
    end

    test "save_tunnel_table truncates random_blobs", %{storage_dir: storage_dir} do
      tunnel_id = :crypto.strong_rand_bytes(32)
      dest_hash = :crypto.strong_rand_bytes(16)

      # Create many random blobs (more than PERSIST_RANDOM_BLOBS=32)
      many_blobs = for _ <- 1..50, do: :crypto.strong_rand_bytes(10)

      path_entry = %Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 1,
        expires: System.system_time(:second) + 7200,
        random_blobs: many_blobs,
        interface: nil,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: nil,
        paths: %{dest_hash => path_entry},
        expires: System.system_time(:second) + 7200
      }

      Transport.put_tunnel_entry(tunnel_id, entry)

      file_path = Path.join(storage_dir, "tunnels_truncated")
      CacheManagement.save_tunnel_table(file_path)

      # Clear and reload
      :ets.delete_all_objects(:rns_tunnel_table)
      CacheManagement.load_tunnel_table(file_path)

      loaded = Transport.get_tunnel_entry(tunnel_id)
      loaded_path = loaded.paths[dest_hash]
      # Should have at most 32 blobs
      assert length(loaded_path.random_blobs) <= 32
    end

    test "load_tunnel_table skips tunnels with no valid paths", %{storage_dir: storage_dir} do
      # Create tunnel with empty paths
      tunnel_id = :crypto.strong_rand_bytes(32)

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: nil,
        paths: %{},
        expires: System.system_time(:second) + 7200
      }

      Transport.put_tunnel_entry(tunnel_id, entry)

      file_path = Path.join(storage_dir, "tunnels_empty_paths")
      CacheManagement.save_tunnel_table(file_path)

      # Clear and reload
      :ets.delete_all_objects(:rns_tunnel_table)
      CacheManagement.load_tunnel_table(file_path)

      # Tunnel with no paths should not be loaded
      assert Transport.get_tunnel_entry(tunnel_id) == nil
    end

    # ── clean_announce_cache ──────────────────────────────────────

    test "clean_announce_cache removes unreferenced cached announces", %{cache_dir: cache_dir} do
      announces_dir = Path.join(cache_dir, "announces")

      # Create some fake cached announce files
      referenced_hash = :crypto.strong_rand_bytes(16)
      unreferenced_hash = :crypto.strong_rand_bytes(16)

      ref_file = Path.join(announces_dir, Base.encode16(referenced_hash, case: :lower))
      unref_file = Path.join(announces_dir, Base.encode16(unreferenced_hash, case: :lower))

      File.write!(ref_file, "data")
      File.write!(unref_file, "data")

      # Add a path table entry referencing the first hash
      add_path_entry(:crypto.strong_rand_bytes(16), packet_hash: referenced_hash)

      CacheManagement.clean_announce_cache(cache_dir)

      # Referenced file should still exist
      assert File.exists?(ref_file)
      # Unreferenced file should be removed
      refute File.exists?(unref_file)
    end

    test "clean_announce_cache keeps tunnel-referenced announces", %{cache_dir: cache_dir} do
      announces_dir = Path.join(cache_dir, "announces")

      tunnel_hash = :crypto.strong_rand_bytes(16)
      tunnel_file = Path.join(announces_dir, Base.encode16(tunnel_hash, case: :lower))
      File.write!(tunnel_file, "data")

      # Add a tunnel entry referencing this hash
      tunnel_id = :crypto.strong_rand_bytes(32)
      dest_hash = :crypto.strong_rand_bytes(16)

      path_entry = %Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 1,
        expires: System.system_time(:second) + 3600,
        random_blobs: [],
        interface: nil,
        packet_hash: tunnel_hash
      }

      entry = %Transport.TunnelEntry{
        tunnel_id: tunnel_id,
        interface: nil,
        paths: %{dest_hash => path_entry},
        expires: System.system_time(:second) + 3600
      }

      Transport.put_tunnel_entry(tunnel_id, entry)

      CacheManagement.clean_announce_cache(cache_dir)

      # Tunnel-referenced file should still exist
      assert File.exists?(tunnel_file)
    end

    test "clean_announce_cache removes files with invalid hex names", %{cache_dir: cache_dir} do
      announces_dir = Path.join(cache_dir, "announces")

      invalid_file = Path.join(announces_dir, "not_a_hex_hash")
      File.write!(invalid_file, "data")

      CacheManagement.clean_announce_cache(cache_dir)

      refute File.exists?(invalid_file)
    end

    test "clean_announce_cache handles non-existent directory" do
      assert :ok ==
               CacheManagement.clean_announce_cache(
                 "/tmp/nonexistent_cache_#{:rand.uniform(999_999)}"
               )
    end

    # ── persist_data ──────────────────────────────────────────────

    test "persist_data saves all data", %{storage_dir: storage_dir} do
      # Add some data to persist
      Transport.mark_packet_hash(:crypto.strong_rand_bytes(32))
      add_path_entry(:crypto.strong_rand_bytes(16))

      iface = make_interface("PersistIface")
      Transport.register_interface(iface)
      add_path_entry(:crypto.strong_rand_bytes(16), interface: iface)

      assert :ok == CacheManagement.persist_data(storage_dir)

      assert File.exists?(Path.join(storage_dir, "packet_hashlist"))
      assert File.exists?(Path.join(storage_dir, "destination_table"))
      assert File.exists?(Path.join(storage_dir, "tunnels"))
    end
  end

  describe "GenServer terminate persists data" do
    test "terminate saves data when storage_path is set" do
      tmp_dir = Path.join(System.tmp_dir!(), "rns_test_terminate_#{:rand.uniform(999_999)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Stop current transport, start one with storage_path
      GenServer.stop(RNS.Transport, :normal)
      Process.sleep(10)
      {:ok, _pid} = Transport.start_link(storage_path: tmp_dir)

      # Add some data
      Transport.mark_packet_hash(:crypto.strong_rand_bytes(32))

      # Stop gracefully - should trigger persist_data
      GenServer.stop(RNS.Transport, :normal)
      Process.sleep(10)

      assert File.exists?(Path.join(tmp_dir, "packet_hashlist"))

      # Restart for subsequent tests
      {:ok, _pid} = Transport.start_link([])
    end
  end

  # ── Helper functions ────────────────────────────────────────────────

  defp make_destination(direction) do
    hash = :crypto.strong_rand_bytes(16)
    dir = if direction == :in, do: 0x11, else: 0x12

    %{
      hash: hash,
      direction: dir,
      type: 0x00,
      mtu: 500
    }
  end

  defp make_interface(name) do
    hash = RNS.Cryptography.Hashes.truncated_hash(name)

    %{
      name: name,
      hash: hash,
      online: true,
      bitrate: 1_000_000
    }
  end

  defp add_path_entry(destination_hash, opts \\ []) do
    entry = %Transport.PathEntry{
      timestamp: opts[:timestamp] || System.system_time(:second),
      next_hop: opts[:next_hop] || :crypto.strong_rand_bytes(16),
      hops: opts[:hops] || 1,
      expires: opts[:expires] || System.system_time(:second) + Transport.pathfinder_e(),
      random_blobs: opts[:random_blobs] || [],
      interface: opts[:interface] || make_interface("DefaultIface"),
      packet_hash: opts[:packet_hash] || :crypto.strong_rand_bytes(16)
    }

    Transport.put_path_entry(destination_hash, entry)
  end

  defp make_filter_packet(opts \\ []) do
    %{
      transport_id: opts[:transport_id] || nil,
      packet_type: opts[:packet_type] || 0x00,
      destination_type: opts[:destination_type] || 0x00,
      context: opts[:context] || 0x00,
      hops: opts[:hops] || 1,
      packet_hash: opts[:packet_hash] || :crypto.strong_rand_bytes(32),
      destination_hash: opts[:destination_hash] || :crypto.strong_rand_bytes(16)
    }
  end
end
