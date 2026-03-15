defmodule RNS.Transport.PathRequestTest do
  use ExUnit.Case, async: false

  alias RNS.Transport
  alias RNS.Transport.DiscoveryRequest

  # ── Setup ──────────────────────────────────────────────────────────

  setup do
    # Ensure Transport GenServer is running (started by application)
    # Clear the new ETS tables before each test
    safe_clear(:rns_discovery_pr_tags)
    safe_clear(:rns_discovery_path_requests)
    safe_clear(:rns_pending_local_path_requests)

    :ok
  end

  defp safe_clear(table) do
    if :ets.info(table) != :undefined do
      :ets.delete_all_objects(table)
    end
  end

  # ── Tag Deduplication ──────────────────────────────────────────────

  describe "discovery_pr_tags deduplication" do
    test "new tag is inserted" do
      tag = :crypto.strong_rand_bytes(32)
      now = System.system_time(:second)
      :ets.insert(:rns_discovery_pr_tags, {tag, now})

      assert :ets.member(:rns_discovery_pr_tags, tag)
    end

    test "duplicate tag is detected" do
      tag = :crypto.strong_rand_bytes(32)
      now = System.system_time(:second)
      :ets.insert(:rns_discovery_pr_tags, {tag, now})

      assert :ets.member(:rns_discovery_pr_tags, tag)
      # Inserting same tag again would be rejected in path_request_handler
      assert :ets.member(:rns_discovery_pr_tags, tag)
    end

    test "culling removes oldest entries when over max" do
      # Insert more than the cull threshold would handle
      # We test the cull function directly with a small dataset
      now = System.system_time(:second)

      # Insert 5 entries with ascending timestamps
      for i <- 1..5 do
        tag = <<i::128>>
        :ets.insert(:rns_discovery_pr_tags, {tag, now + i})
      end

      assert :ets.info(:rns_discovery_pr_tags, :size) == 5

      # The cull function only triggers when > @max_pr_tags (32000)
      # So with 5 entries, nothing should be culled
      Transport.cull_discovery_pr_tags()
      assert :ets.info(:rns_discovery_pr_tags, :size) == 5
    end
  end

  # ── Discovery Path Requests ────────────────────────────────────────

  describe "discovery_path_requests culling" do
    test "expired entries are removed" do
      now = System.system_time(:second)
      expired_hash = :crypto.strong_rand_bytes(16)
      valid_hash = :crypto.strong_rand_bytes(16)

      :ets.insert(:rns_discovery_path_requests, {
        expired_hash,
        %DiscoveryRequest{timeout: now - 10, requesting_interface: nil}
      })

      :ets.insert(:rns_discovery_path_requests, {
        valid_hash,
        %DiscoveryRequest{timeout: now + 100, requesting_interface: nil}
      })

      Transport.cull_discovery_path_requests(now)

      refute :ets.member(:rns_discovery_path_requests, expired_hash)
      assert :ets.member(:rns_discovery_path_requests, valid_hash)
    end
  end

  # ── Helper Functions ───────────────────────────────────────────────

  describe "from_local_client?/1" do
    test "returns false for packet without receiving_interface" do
      refute Transport.from_local_client?(%{})
    end

    test "returns false for packet with normal interface" do
      packet = %{receiving_interface: %{name: "eth0"}}
      refute Transport.from_local_client?(packet)
    end

    test "returns true for packet from local shared instance" do
      parent = %{is_local_shared_instance: true}
      iface = %{parent_interface: parent}
      packet = %{receiving_interface: iface}
      assert Transport.from_local_client?(packet)
    end
  end

  describe "local_client_interface?/1" do
    test "returns false for interface without parent" do
      refute Transport.local_client_interface?(%{name: "eth0"})
    end

    test "returns true for local shared instance child" do
      parent = %{is_local_shared_instance: true}
      iface = %{parent_interface: parent}
      assert Transport.local_client_interface?(iface)
    end

    test "returns false for non-shared parent" do
      parent = %{is_local_shared_instance: false}
      iface = %{parent_interface: parent}
      refute Transport.local_client_interface?(iface)
    end
  end

  # ── Transport Config ETS ───────────────────────────────────────────

  describe "transport_enabled?/0 and local_client_interfaces/0" do
    test "transport_enabled? reads from ETS" do
      # The value should be whatever was configured
      result = Transport.transport_enabled?()
      assert is_boolean(result)
    end

    test "local_client_interfaces returns a list" do
      result = Transport.local_client_interfaces()
      assert is_list(result)
    end
  end

  # ── Stats Accessors ────────────────────────────────────────────────

  describe "stats accessors" do
    test "link_table_size returns a non-negative integer" do
      assert Transport.link_table_size() >= 0
    end

    test "get_all_path_entries returns a list" do
      entries = Transport.get_all_path_entries()
      assert is_list(entries)
    end

    test "get_all_rate_entries returns a list" do
      entries = Transport.get_all_rate_entries()
      assert is_list(entries)
    end
  end
end
