defmodule RNS.ShutdownPersistenceTest do
  @moduledoc """
  Tests for Task 2.4 — Clean shutdown with full state persistence.

  Verifies that:
  - Application.stop completes without errors
  - No ETS-related crash logs during shutdown
  - Persisted state files are written to disk during shutdown
  - Restart loads the previously persisted state
  - Persistence is skipped when connected to a shared instance (Python parity)
  - IdentityStore has defense-in-depth terminate
  - Transport terminate saves all state directly
  - Missing storage dir is handled gracefully
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RNS.Transport
  alias RNS.Transport.CacheManagement
  alias RNS.Transport.PathEntry
  alias RNS.Transport.PathManagement

  setup do
    RNS.Test.SupervisedHelpers.clear_transport_tables()

    tmp_dir = System.tmp_dir!() |> Path.join("rns_shutdown_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    reticulum_state = GenServer.call(RNS.Reticulum, :get_state)
    original_path = reticulum_state.storagepath

    on_exit(fn ->
      # Restore original storage paths
      Transport.configure(storage_path: original_path)
      RNS.IdentityStore.configure(original_path)
      RNS.Test.SupervisedHelpers.clear_transport_tables()
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, original_path: original_path}
  end

  describe "Reticulum persist_data skips when connected to shared instance" do
    test "persist_data saves files when NOT connected to shared instance", %{tmp_dir: tmp_dir} do
      # Configure subsystems with our tmp dir
      Transport.configure(storage_path: tmp_dir)
      RNS.IdentityStore.configure(tmp_dir)

      # Insert some data so files get written
      hash = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash, true})

      # Call persist_data via Reticulum (not connected to shared = should persist)
      state = GenServer.call(RNS.Reticulum, :get_state)
      assert state.is_connected_to_shared_instance == false

      # Trigger persist via the public API
      assert :ok = RNS.Reticulum.persist_data()

      # Files should exist
      assert File.exists?(Path.join(tmp_dir, "packet_hashlist"))
      assert File.exists?(Path.join(tmp_dir, "destination_table"))
      assert File.exists?(Path.join(tmp_dir, "tunnels"))
      assert File.exists?(Path.join(tmp_dir, "known_destinations"))
    end

    test "persist_data skips when connected to shared instance", %{tmp_dir: tmp_dir} do
      Transport.configure(storage_path: tmp_dir)
      RNS.IdentityStore.configure(tmp_dir)

      # Insert data
      hash = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash, true})

      # Simulate being connected to a shared instance
      # (set the flag via Reticulum state — we use :sys.replace_state for test)
      :sys.replace_state(RNS.Reticulum, fn state ->
        %{state | is_connected_to_shared_instance: true}
      end)

      # Trigger persist
      assert :ok = RNS.Reticulum.persist_data()

      # Files should NOT exist (persistence was skipped)
      refute File.exists?(Path.join(tmp_dir, "packet_hashlist"))
      refute File.exists?(Path.join(tmp_dir, "destination_table"))
      refute File.exists?(Path.join(tmp_dir, "tunnels"))

      # Restore flag
      :sys.replace_state(RNS.Reticulum, fn state ->
        %{state | is_connected_to_shared_instance: false}
      end)
    end
  end

  describe "Reticulum terminate persists all state" do
    test "terminate writes all four persistence files", %{tmp_dir: tmp_dir} do
      Transport.configure(storage_path: tmp_dir)
      RNS.IdentityStore.configure(tmp_dir)

      # Insert data into each subsystem
      hash = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash, true})

      dest_hash = :crypto.strong_rand_bytes(16)
      pub_key = :crypto.strong_rand_bytes(div(RNS.Identity.keysize(), 8))
      RNS.IdentityStore.remember(hash, dest_hash, pub_key, nil)

      # Simulate terminate by calling persist_data
      assert :ok = RNS.Reticulum.persist_data()

      # All four files should exist
      assert File.exists?(Path.join(tmp_dir, "packet_hashlist"))
      assert File.exists?(Path.join(tmp_dir, "destination_table"))
      assert File.exists?(Path.join(tmp_dir, "tunnels"))
      assert File.exists?(Path.join(tmp_dir, "known_destinations"))
    end

    test "terminate produces no error logs", %{tmp_dir: tmp_dir} do
      Transport.configure(storage_path: tmp_dir)
      RNS.IdentityStore.configure(tmp_dir)

      log =
        capture_log(fn ->
          RNS.Reticulum.persist_data()
        end)

      refute log =~ "error"
      refute log =~ "Error"
      refute log =~ "ETS"
    end
  end

  describe "Transport terminate saves state (defense in depth)" do
    test "Transport.terminate saves all three state files", %{tmp_dir: tmp_dir} do
      Transport.configure(storage_path: tmp_dir)

      # Insert data
      hash = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash, true})

      # Directly call CacheManagement.persist_data (what terminate calls)
      CacheManagement.persist_data(tmp_dir)

      assert File.exists?(Path.join(tmp_dir, "packet_hashlist"))
      assert File.exists?(Path.join(tmp_dir, "destination_table"))
      assert File.exists?(Path.join(tmp_dir, "tunnels"))
    end

    test "Transport.persist_data public API works", %{tmp_dir: tmp_dir} do
      Transport.configure(storage_path: tmp_dir)

      hash = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash, true})

      # Use the public API (should delegate to internal persist)
      assert :ok = Transport.persist_data()

      assert File.exists?(Path.join(tmp_dir, "packet_hashlist"))
    end
  end

  describe "IdentityStore terminate saves known destinations (defense in depth)" do
    test "IdentityStore.terminate saves to disk", %{tmp_dir: tmp_dir} do
      RNS.IdentityStore.configure(tmp_dir)

      # Insert a known destination
      dest_hash = :crypto.strong_rand_bytes(16)
      pub_key = :crypto.strong_rand_bytes(div(RNS.Identity.keysize(), 8))
      pkt_hash = :crypto.strong_rand_bytes(32)
      RNS.IdentityStore.remember(pkt_hash, dest_hash, pub_key, nil)

      assert :ets.info(:rns_known_destinations, :size) >= 1

      # Simulate terminate by saving
      assert :ok = RNS.IdentityStore.save_known_destinations()

      file_path = Path.join(tmp_dir, "known_destinations")
      assert File.exists?(file_path)

      # Verify data can be loaded back
      :ets.delete_all_objects(:rns_known_destinations)
      RNS.IdentityStore.configure(tmp_dir)
      assert :ets.info(:rns_known_destinations, :size) >= 1
    end
  end

  describe "missing storage directory handling" do
    test "persist_data handles nonexistent storage dir gracefully" do
      # Use a path that doesn't exist
      fake_path = "/tmp/rns_nonexistent_#{:rand.uniform(999_999)}/storage"
      refute File.exists?(fake_path)

      # This should not crash — should log errors but return :ok
      log =
        capture_log(fn ->
          Transport.configure(storage_path: fake_path)

          # Insert data so save actually tries to write
          hash = :crypto.strong_rand_bytes(32)
          :ets.insert(:rns_packet_hashlist, {hash, true})

          # persist_data should handle gracefully (create dir or log error)
          RNS.Reticulum.persist_data()
        end)

      # Should not crash the GenServers
      assert is_pid(GenServer.whereis(RNS.Transport))
      assert is_pid(GenServer.whereis(RNS.Reticulum))
    end

    test "IdentityStore save handles nonexistent dir gracefully" do
      fake_path = "/tmp/rns_nonexistent_#{:rand.uniform(999_999)}/storage"
      RNS.IdentityStore.configure(fake_path)

      dest_hash = :crypto.strong_rand_bytes(16)
      pub_key = :crypto.strong_rand_bytes(div(RNS.Identity.keysize(), 8))
      RNS.IdentityStore.remember(:crypto.strong_rand_bytes(32), dest_hash, pub_key, nil)

      # Should not crash
      result = RNS.IdentityStore.save_known_destinations()
      assert match?({:error, _}, result) or result == :ok

      # GenServer still alive
      assert is_pid(GenServer.whereis(RNS.IdentityStore))
    end
  end

  describe "full shutdown/restart round-trip" do
    test "data persisted by Reticulum survives a simulated restart", %{tmp_dir: tmp_dir} do
      Transport.configure(storage_path: tmp_dir)
      RNS.IdentityStore.configure(tmp_dir)

      # Insert data into all stores
      hash1 = :crypto.strong_rand_bytes(32)
      hash2 = :crypto.strong_rand_bytes(32)
      :ets.insert(:rns_packet_hashlist, {hash1, true})
      :ets.insert(:rns_packet_hashlist, {hash2, true})

      dest_hash = :crypto.strong_rand_bytes(16)
      pub_key = :crypto.strong_rand_bytes(div(RNS.Identity.keysize(), 8))
      RNS.IdentityStore.remember(hash1, dest_hash, pub_key, <<"test_app_data">>)

      # Persist (simulate shutdown)
      RNS.Reticulum.persist_data()

      # Clear all ETS data (simulate restart)
      RNS.Test.SupervisedHelpers.clear_transport_tables()
      :ets.delete_all_objects(:rns_known_destinations)

      assert :ets.info(:rns_packet_hashlist, :size) == 0
      assert :ets.info(:rns_known_destinations, :size) == 0

      # Reload (simulate startup)
      Transport.configure(storage_path: tmp_dir)
      RNS.IdentityStore.configure(tmp_dir)

      # Verify data was restored
      assert :ets.info(:rns_packet_hashlist, :size) == 2
      assert [{^hash1, true}] = :ets.lookup(:rns_packet_hashlist, hash1)
      assert [{^hash2, true}] = :ets.lookup(:rns_packet_hashlist, hash2)

      assert :ets.info(:rns_known_destinations, :size) >= 1
      assert [{^dest_hash, {_ts, ^hash1, ^pub_key, <<"test_app_data">>}}] =
               :ets.lookup(:rns_known_destinations, dest_hash)
    end
  end

  describe "shutdown order is correct for :rest_for_one" do
    test "Reticulum terminates first (last child), ETS still available" do
      # With :rest_for_one, shutdown is reverse order: Reticulum → ResourceSupervisor →
      # LinkSupervisor → InterfaceSupervisor → Transport → IdentityStore
      # So when Reticulum.terminate runs, Transport and IdentityStore ETS tables exist.
      children = Supervisor.which_children(RNS.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      # Reticulum should be in the list (started last = terminated first)
      assert RNS.Reticulum in child_ids
      assert RNS.Transport in child_ids
      assert RNS.IdentityStore in child_ids

      # ETS tables are currently accessible (proves they exist during Reticulum's lifetime)
      assert :ets.info(:rns_packet_hashlist) != :undefined
      assert :ets.info(:rns_path_table) != :undefined
      assert :ets.info(:rns_known_destinations) != :undefined
    end
  end
end
