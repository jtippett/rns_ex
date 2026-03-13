defmodule RNS.IdentityStoreTest do
  use ExUnit.Case, async: false

  alias RNS.IdentityStore
  alias RNS.Test.SupervisedHelpers

  setup do
    # Save original state so we can restore it after the test
    original_state = :sys.get_state(RNS.IdentityStore)
    SupervisedHelpers.clear_identity_store_tables()

    tmpdir = System.tmp_dir!()
    storagepath = Path.join(tmpdir, "rns_test_idstore_#{:rand.uniform(100_000)}")
    File.mkdir_p!(storagepath)

    on_exit(fn ->
      # Restore original storagepath so other tests aren't affected
      :sys.replace_state(RNS.IdentityStore, fn _state -> original_state end)
      File.rm_rf!(storagepath)
    end)

    {:ok, storagepath: storagepath}
  end

  describe "configure/1" do
    test "sets the storage path", %{storagepath: storagepath} do
      assert :ok = IdentityStore.configure(storagepath)
      assert IdentityStore.storagepath() == storagepath
    end

    test "handles missing destinations file gracefully", %{storagepath: storagepath} do
      # No known_destinations file exists — should not crash
      assert :ok = IdentityStore.configure(storagepath)
    end

    test "loads known destinations from disk", %{storagepath: storagepath} do
      # Create a known_destinations file with msgpack data
      dest_hash = :crypto.strong_rand_bytes(16)
      pkt_hash = :crypto.strong_rand_bytes(32)
      # Identity keysize is 512 bits = 64 bytes for public key
      pub_key = :crypto.strong_rand_bytes(64)
      app_data = "test_app_data"
      timestamp = System.system_time(:second)

      destinations = %{dest_hash => [timestamp, pkt_hash, pub_key, app_data]}
      packed = Msgpax.pack!(destinations, iodata: false)
      File.write!(Path.join(storagepath, "known_destinations"), packed)

      assert :ok = IdentityStore.configure(storagepath)

      # Verify the destination was loaded into ETS
      case :ets.lookup(:rns_known_destinations, dest_hash) do
        [{^dest_hash, {ts, ph, pk, ad}}] ->
          assert ts == timestamp
          assert ph == pkt_hash
          assert pk == pub_key
          assert ad == app_data

        [] ->
          flunk("Known destination was not loaded from disk")
      end
    end

    test "filters out destinations with wrong hash length", %{storagepath: storagepath} do
      valid_hash = :crypto.strong_rand_bytes(16)
      invalid_hash = :crypto.strong_rand_bytes(8)
      pub_key = :crypto.strong_rand_bytes(64)
      timestamp = System.system_time(:second)

      destinations = %{
        valid_hash => [timestamp, <<0::256>>, pub_key, nil],
        invalid_hash => [timestamp, <<0::256>>, pub_key, nil]
      }

      packed = Msgpax.pack!(destinations, iodata: false)
      File.write!(Path.join(storagepath, "known_destinations"), packed)

      assert :ok = IdentityStore.configure(storagepath)

      # Valid hash should be loaded
      assert :ets.lookup(:rns_known_destinations, valid_hash) != []
      # Invalid hash should be filtered out
      assert :ets.lookup(:rns_known_destinations, invalid_hash) == []
    end
  end

  describe "save_known_destinations/0" do
    test "saves destinations to disk", %{storagepath: storagepath} do
      assert :ok = IdentityStore.configure(storagepath)

      # Insert a destination into ETS
      dest_hash = :crypto.strong_rand_bytes(16)
      pub_key = :crypto.strong_rand_bytes(64)
      pkt_hash = :crypto.strong_rand_bytes(32)
      entry = {System.system_time(:second), pkt_hash, pub_key, "app_data"}
      :ets.insert(:rns_known_destinations, {dest_hash, entry})

      assert :ok = IdentityStore.save_known_destinations()

      # Verify file was written
      file_path = Path.join(storagepath, "known_destinations")
      assert File.exists?(file_path)

      # Verify contents
      data = File.read!(file_path)
      loaded = Msgpax.unpack!(data)
      assert Map.has_key?(loaded, dest_hash)
    end

    test "returns error when no storage path is configured" do
      # Reset state to no storage path
      :sys.replace_state(RNS.IdentityStore, fn state ->
        %{state | storagepath: nil}
      end)

      assert {:error, :no_storagepath} = IdentityStore.save_known_destinations()
    end

    test "round-trips destinations through save and load", %{storagepath: storagepath} do
      assert :ok = IdentityStore.configure(storagepath)

      # Insert destinations
      dest_hash = :crypto.strong_rand_bytes(16)
      pub_key = :crypto.strong_rand_bytes(64)
      pkt_hash = :crypto.strong_rand_bytes(32)
      timestamp = System.system_time(:second)
      entry = {timestamp, pkt_hash, pub_key, "round_trip_data"}
      :ets.insert(:rns_known_destinations, {dest_hash, entry})

      # Save
      assert :ok = IdentityStore.save_known_destinations()

      # Clear ETS
      :ets.delete_all_objects(:rns_known_destinations)
      assert :ets.tab2list(:rns_known_destinations) == []

      # Reload
      assert :ok = IdentityStore.configure(storagepath)

      # Verify round-trip
      [{^dest_hash, {ts, ph, pk, ad}}] = :ets.lookup(:rns_known_destinations, dest_hash)
      assert ts == timestamp
      assert ph == pkt_hash
      assert pk == pub_key
      assert ad == "round_trip_data"
    end
  end
end
