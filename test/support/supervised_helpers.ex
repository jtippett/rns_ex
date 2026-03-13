defmodule RNS.Test.SupervisedHelpers do
  @moduledoc """
  Helpers for tests that need fresh ETS state from supervised GenServers.

  Since RNS.IdentityStore and RNS.Transport are started by the application
  supervision tree, tests should clear their ETS tables rather than stopping
  and restarting the processes (which causes rest_for_one cascading restarts).
  """

  @transport_tables [
    :rns_destinations,
    :rns_interfaces,
    :rns_pending_links,
    :rns_active_links,
    :rns_packet_hashlist,
    :rns_receipts,
    :rns_announce_table,
    :rns_path_table,
    :rns_reverse_table,
    :rns_link_table,
    :rns_held_announces,
    :rns_tunnel_table,
    :rns_announce_rate_table,
    :rns_path_requests,
    :rns_path_states
  ]

  @identity_store_tables [
    :rns_known_destinations,
    :rns_known_ratchets
  ]

  @doc "Clears all Transport ETS tables for a fresh test state."
  def clear_transport_tables do
    Enum.each(@transport_tables, &safe_clear/1)
  end

  @doc "Clears all IdentityStore ETS tables for a fresh test state."
  def clear_identity_store_tables do
    Enum.each(@identity_store_tables, &safe_clear/1)
  end

  defp safe_clear(table) do
    case :ets.info(table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(table)
    end
  end
end
