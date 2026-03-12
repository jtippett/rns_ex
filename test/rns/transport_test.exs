defmodule RNS.TransportTest do
  use ExUnit.Case, async: false

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
      path = Path.join(System.tmp_dir!(), "rns_test_path_table_#{:erlang.unique_integer([:positive])}")

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

      path = Path.join(System.tmp_dir!(), "rns_test_path_table_skip_#{:erlang.unique_integer([:positive])}")
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

      path = Path.join(System.tmp_dir!(), "rns_test_path_table_expired_#{:erlang.unique_integer([:positive])}")
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

  # Helper functions

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
end
