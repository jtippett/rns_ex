defmodule RNS.TransportPersistenceTest do
  @moduledoc """
  Tests for Task 2.2 — Load and save packet hashlist, path table, and tunnel table.

  Verifies that:
  - Packet hashlist survives a save/load cycle
  - Path table survives a save/load cycle
  - Tunnel table survives a save/load cycle
  - Missing persistence files don't crash startup
  - Periodic persistence timers are running
  - Transport periodic jobs are started after boot
  """
  use ExUnit.Case, async: false

  alias RNS.Transport
  alias RNS.Transport.CacheManagement
  alias RNS.Transport.PathEntry
  alias RNS.Transport.PathManagement
  alias RNS.Transport.TunnelEntry

  setup do
    RNS.Test.SupervisedHelpers.clear_transport_tables()

    # Create a fresh tmp directory for each test
    tmp_dir = System.tmp_dir!() |> Path.join("rns_persist_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    # Save original storage path to restore after test
    reticulum_state = GenServer.call(RNS.Reticulum, :get_state)
    original_path = reticulum_state.storagepath

    on_exit(fn ->
      Transport.configure(storage_path: original_path)
      RNS.Test.SupervisedHelpers.clear_transport_tables()
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, original_path: original_path}
  end

  describe "packet hashlist persistence" do
    test "hashlist survives a save/load cycle", %{tmp_dir: tmp_dir} do
      # Insert some packet hashes into ETS
      hash1 = :crypto.strong_rand_bytes(32)
      hash2 = :crypto.strong_rand_bytes(32)
      hash3 = :crypto.strong_rand_bytes(32)

      :ets.insert(:rns_packet_hashlist, {hash1, true})
      :ets.insert(:rns_packet_hashlist, {hash2, true})
      :ets.insert(:rns_packet_hashlist, {hash3, true})

      assert :ets.info(:rns_packet_hashlist, :size) == 3

      # Save to disk
      file_path = Path.join(tmp_dir, "packet_hashlist")
      assert :ok = CacheManagement.save_packet_hashlist(file_path)
      assert File.exists?(file_path)

      # Clear ETS
      :ets.delete_all_objects(:rns_packet_hashlist)
      assert :ets.info(:rns_packet_hashlist, :size) == 0

      # Load from disk
      assert :ok = CacheManagement.load_packet_hashlist(file_path)

      # Verify all hashes restored
      assert :ets.info(:rns_packet_hashlist, :size) == 3
      assert [{^hash1, true}] = :ets.lookup(:rns_packet_hashlist, hash1)
      assert [{^hash2, true}] = :ets.lookup(:rns_packet_hashlist, hash2)
      assert [{^hash3, true}] = :ets.lookup(:rns_packet_hashlist, hash3)
    end

    test "loading missing hashlist file returns error, no crash", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "nonexistent_hashlist")
      refute File.exists?(file_path)

      result = CacheManagement.load_packet_hashlist(file_path)
      assert result == {:error, :enoent}
      # ETS table should be unaffected (still empty)
      assert :ets.info(:rns_packet_hashlist, :size) == 0
    end

    test "loading corrupt hashlist file returns error, no crash", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "corrupt_hashlist")
      File.write!(file_path, "this is not valid msgpack data!!")

      result = CacheManagement.load_packet_hashlist(file_path)
      assert {:error, _reason} = result
      # ETS table should be unaffected
      assert :ets.info(:rns_packet_hashlist, :size) == 0
    end
  end

  describe "path table persistence" do
    test "path table survives a save/load cycle with registered interface", %{tmp_dir: tmp_dir} do
      # Register a mock interface so find_interface_from_hash works during load
      interface_hash = :crypto.strong_rand_bytes(16)

      mock_interface = %{
        hash: interface_hash,
        name: "TestInterface",
        mode: 0x00,
        online: true,
        enabled: true
      }

      Transport.register_interface(mock_interface)

      # Insert path entries into ETS
      dest_hash1 = :crypto.strong_rand_bytes(16)
      dest_hash2 = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      entry1 = %PathEntry{
        timestamp: now,
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 2,
        expires: now + 86400,
        random_blobs: [:crypto.strong_rand_bytes(16)],
        interface: mock_interface,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      entry2 = %PathEntry{
        timestamp: now,
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 1,
        expires: now + 86400,
        random_blobs: [],
        interface: mock_interface,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      :ets.insert(:rns_path_table, {dest_hash1, entry1})
      :ets.insert(:rns_path_table, {dest_hash2, entry2})

      assert :ets.info(:rns_path_table, :size) == 2

      # Save to disk
      file_path = Path.join(tmp_dir, "destination_table")
      assert :ok = PathManagement.save_path_table(file_path)
      assert File.exists?(file_path)

      # Clear ETS
      :ets.delete_all_objects(:rns_path_table)
      assert :ets.info(:rns_path_table, :size) == 0

      # Load from disk (interface is still registered)
      assert :ok = PathManagement.load_path_table(file_path)

      # Verify entries restored
      assert :ets.info(:rns_path_table, :size) == 2

      [{^dest_hash1, loaded_entry1}] = :ets.lookup(:rns_path_table, dest_hash1)
      assert loaded_entry1.hops == entry1.hops
      assert loaded_entry1.next_hop == entry1.next_hop
      assert loaded_entry1.expires == entry1.expires
      assert loaded_entry1.packet_hash == entry1.packet_hash
      # Interface should be the registered one (looked up by hash during load)
      assert loaded_entry1.interface.hash == interface_hash

      [{^dest_hash2, loaded_entry2}] = :ets.lookup(:rns_path_table, dest_hash2)
      assert loaded_entry2.hops == entry2.hops
    end

    test "expired path entries are not restored on load", %{tmp_dir: tmp_dir} do
      interface_hash = :crypto.strong_rand_bytes(16)

      mock_interface = %{
        hash: interface_hash,
        name: "TestInterface",
        mode: 0x00,
        online: true,
        enabled: true
      }

      Transport.register_interface(mock_interface)

      dest_hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      # Create an already-expired entry
      expired_entry = %PathEntry{
        timestamp: now - 100_000,
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 3,
        expires: now - 1,
        random_blobs: [],
        interface: mock_interface,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      :ets.insert(:rns_path_table, {dest_hash, expired_entry})

      file_path = Path.join(tmp_dir, "destination_table")
      PathManagement.save_path_table(file_path)

      :ets.delete_all_objects(:rns_path_table)
      PathManagement.load_path_table(file_path)

      # Expired entry should NOT be restored
      assert :ets.info(:rns_path_table, :size) == 0
    end

    test "path entries with missing interface are not restored on load", %{tmp_dir: tmp_dir} do
      interface_hash = :crypto.strong_rand_bytes(16)
      mock_interface = %{hash: interface_hash, name: "TempInterface", mode: 0x00}

      Transport.register_interface(mock_interface)

      dest_hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      entry = %PathEntry{
        timestamp: now,
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 1,
        expires: now + 86400,
        random_blobs: [],
        interface: mock_interface,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      :ets.insert(:rns_path_table, {dest_hash, entry})

      file_path = Path.join(tmp_dir, "destination_table")
      PathManagement.save_path_table(file_path)

      # Clear path table AND deregister the interface
      :ets.delete_all_objects(:rns_path_table)
      Transport.deregister_interface(mock_interface)

      PathManagement.load_path_table(file_path)

      # Entry should NOT be restored (interface gone)
      assert :ets.info(:rns_path_table, :size) == 0
    end

    test "loading missing path table file returns error, no crash", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "nonexistent_path_table")
      result = PathManagement.load_path_table(file_path)
      assert {:error, :enoent} = result
    end
  end

  describe "tunnel table persistence" do
    test "tunnel table survives a save/load cycle", %{tmp_dir: tmp_dir} do
      tunnel_id = :crypto.strong_rand_bytes(16)
      interface_hash = :crypto.strong_rand_bytes(16)
      dest_hash = :crypto.strong_rand_bytes(16)
      now = System.system_time(:second)

      path_entry = %PathEntry{
        timestamp: now,
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 1,
        expires: now + 86400,
        random_blobs: [:crypto.strong_rand_bytes(16), :crypto.strong_rand_bytes(16)],
        interface: %{hash: interface_hash, name: "TunnelIface"},
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      tunnel_entry = %TunnelEntry{
        tunnel_id: tunnel_id,
        interface: %{hash: interface_hash},
        paths: %{dest_hash => path_entry},
        expires: now + 86400
      }

      Transport.put_tunnel_entry(tunnel_id, tunnel_entry)
      assert :ets.info(:rns_tunnel_table, :size) == 1

      # Save to disk
      file_path = Path.join(tmp_dir, "tunnels")
      assert :ok = CacheManagement.save_tunnel_table(file_path)
      assert File.exists?(file_path)

      # Clear ETS
      :ets.delete_all_objects(:rns_tunnel_table)
      assert :ets.info(:rns_tunnel_table, :size) == 0

      # Load from disk
      assert :ok = CacheManagement.load_tunnel_table(file_path)

      # Verify tunnel restored
      assert :ets.info(:rns_tunnel_table, :size) == 1

      [{^tunnel_id, loaded_tunnel}] = :ets.lookup(:rns_tunnel_table, tunnel_id)
      assert loaded_tunnel.tunnel_id == tunnel_id
      assert map_size(loaded_tunnel.paths) == 1
      loaded_path = Map.get(loaded_tunnel.paths, dest_hash)
      assert loaded_path.hops == 1
      assert loaded_path.next_hop == path_entry.next_hop
    end

    test "loading missing tunnel file returns error, no crash", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "nonexistent_tunnels")
      result = CacheManagement.load_tunnel_table(file_path)
      assert result == {:error, :enoent}
    end
  end

  describe "full persistence round-trip via configure" do
    test "packet hashlist loaded via Transport.configure", %{tmp_dir: tmp_dir} do
      # Insert hashes
      hash1 = :crypto.strong_rand_bytes(32)
      hash2 = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash1, true})
      :ets.insert(:rns_packet_hashlist, {hash2, true})

      # Save to the expected file location
      CacheManagement.save_packet_hashlist(Path.join(tmp_dir, "packet_hashlist"))

      # Clear ETS
      :ets.delete_all_objects(:rns_packet_hashlist)
      assert :ets.info(:rns_packet_hashlist, :size) == 0

      # Reconfigure Transport with this storage path — should load persisted data
      Transport.configure(storage_path: tmp_dir)

      # Verify hashes were loaded
      assert :ets.info(:rns_packet_hashlist, :size) == 2
      assert [{^hash1, true}] = :ets.lookup(:rns_packet_hashlist, hash1)
      assert [{^hash2, true}] = :ets.lookup(:rns_packet_hashlist, hash2)
    end

    test "configure with no persistence files doesn't crash", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty_storage")
      File.mkdir_p!(empty_dir)

      # This should not crash even though no persistence files exist
      assert :ok = Transport.configure(storage_path: empty_dir)

      # ETS tables should be empty but accessible
      assert :ets.info(:rns_packet_hashlist, :size) == 0
      assert :ets.info(:rns_path_table, :size) == 0
      assert :ets.info(:rns_tunnel_table, :size) == 0
    end
  end

  describe "periodic persistence timers" do
    test "Reticulum periodic job timer is running after boot" do
      # Reticulum should have scheduled :run_jobs via Process.send_after.
      # We verify by checking that the Reticulum GenServer is alive and has
      # the jobs_started flag set in its state.
      reticulum_state = GenServer.call(RNS.Reticulum, :get_state)
      assert reticulum_state.jobs_started == true
    end

    test "Reticulum has persist interval constants configured" do
      # Verify the persist intervals match Python's Transport constants
      assert RNS.Reticulum.persist_interval() == 60 * 60 * 12
      assert RNS.Reticulum.gracious_persist_interval() == 60 * 5
    end

    test "Transport periodic jobs are started after boot" do
      # Transport.start_jobs() should have been called during Reticulum's
      # init sequence, so jobs_started should be true in Transport state.
      transport_state = :sys.get_state(RNS.Transport)
      assert transport_state.jobs_started == true
    end
  end

  describe "shutdown persistence" do
    test "Transport terminate saves state to disk", %{tmp_dir: tmp_dir} do
      # Configure Transport with our tmp dir
      Transport.configure(storage_path: tmp_dir)

      # Insert some data
      hash = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash, true})

      # Manually call the terminate logic (can't actually stop Transport
      # without restarting the supervision tree)
      CacheManagement.persist_data(tmp_dir)

      # Verify files exist on disk
      assert File.exists?(Path.join(tmp_dir, "packet_hashlist"))
      assert File.exists?(Path.join(tmp_dir, "destination_table"))
      assert File.exists?(Path.join(tmp_dir, "tunnels"))
    end
  end
end
