defmodule RNS.Reticulum.StatsTest do
  use ExUnit.Case, async: false

  alias RNS.Reticulum
  alias RNS.Transport

  # ── get_interface_stats ────────────────────────────────────────────

  describe "get_interface_stats/0" do
    test "returns a map with interfaces list" do
      stats = Reticulum.get_interface_stats()
      assert is_map(stats)
      assert is_list(stats.interfaces)
    end

    test "includes aggregate traffic stats" do
      stats = Reticulum.get_interface_stats()
      assert Map.has_key?(stats, :rxb)
      assert Map.has_key?(stats, :txb)
    end
  end

  # ── get_link_count ─────────────────────────────────────────────────

  describe "get_link_count/0" do
    test "returns a non-negative integer" do
      count = Reticulum.get_link_count()
      assert is_integer(count)
      assert count >= 0
    end
  end

  # ── get_path_table ─────────────────────────────────────────────────

  describe "get_path_table/1" do
    test "returns a list" do
      table = Reticulum.get_path_table()
      assert is_list(table)
    end

    test "returns empty list when path table is empty" do
      # Clear path table
      :ets.delete_all_objects(:rns_path_table)
      table = Reticulum.get_path_table()
      assert table == []
    end

    test "filters by max_hops when specified" do
      :ets.delete_all_objects(:rns_path_table)

      hash1 = :crypto.strong_rand_bytes(16)
      hash2 = :crypto.strong_rand_bytes(16)

      entry1 = %Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 2,
        expires: System.system_time(:second) + 3600,
        random_blobs: [],
        interface: nil,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      entry2 = %Transport.PathEntry{
        timestamp: System.system_time(:second),
        next_hop: :crypto.strong_rand_bytes(16),
        hops: 5,
        expires: System.system_time(:second) + 3600,
        random_blobs: [],
        interface: nil,
        packet_hash: :crypto.strong_rand_bytes(32)
      }

      Transport.put_path_entry(hash1, entry1)
      Transport.put_path_entry(hash2, entry2)

      # No filter — both returned
      assert length(Reticulum.get_path_table()) == 2

      # Filter to max 3 hops — only entry1
      filtered = Reticulum.get_path_table(3)
      assert length(filtered) == 1
      assert hd(filtered).hops == 2
    end
  end

  # ── get_rate_table ─────────────────────────────────────────────────

  describe "get_rate_table/0" do
    test "returns a list" do
      table = Reticulum.get_rate_table()
      assert is_list(table)
    end
  end
end
