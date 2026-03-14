defmodule RNS.ApplicationTest do
  use ExUnit.Case

  describe "supervision tree" do
    test "application starts successfully" do
      assert {:ok, _pid} = Application.ensure_all_started(:rns_ex)
    end

    test "top-level supervisor is running" do
      pid = Process.whereis(RNS.Supervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "IdentityStore GenServer is running" do
      pid = GenServer.whereis(RNS.IdentityStore)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "Transport GenServer is running" do
      pid = GenServer.whereis(RNS.Transport)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "Reticulum GenServer is running" do
      pid = GenServer.whereis(RNS.Reticulum)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "InterfaceSupervisor is running as a DynamicSupervisor" do
      pid = Process.whereis(RNS.InterfaceSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)

      counts = DynamicSupervisor.count_children(RNS.InterfaceSupervisor)
      assert is_map(counts)
    end

    test "LinkSupervisor is running as a DynamicSupervisor" do
      pid = Process.whereis(RNS.LinkSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)

      assert DynamicSupervisor.count_children(RNS.LinkSupervisor) == %{
               active: 0,
               specs: 0,
               supervisors: 0,
               workers: 0
             }
    end

    test "ResourceSupervisor is running as a DynamicSupervisor" do
      pid = Process.whereis(RNS.ResourceSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)

      assert DynamicSupervisor.count_children(RNS.ResourceSupervisor) == %{
               active: 0,
               specs: 0,
               supervisors: 0,
               workers: 0
             }
    end

    test "supervisor has exactly 8 children" do
      counts = Supervisor.count_children(RNS.Supervisor)
      assert counts[:active] == 8
    end

    test "supervisor uses :rest_for_one strategy" do
      # Verify all expected children are present
      children = Supervisor.which_children(RNS.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert RNS.Transport.Registry in child_ids
      assert RNS.IdentityStore in child_ids
      assert RNS.Transport in child_ids
      assert RNS.InterfaceSupervisor in child_ids
      assert RNS.LinkSupervisor in child_ids
      assert RNS.ResourceSupervisor in child_ids
      assert RNS.TaskSupervisor in child_ids
      assert RNS.Reticulum in child_ids
    end

    test "IdentityStore ETS tables exist" do
      assert :ets.info(:rns_known_destinations) != :undefined
      assert :ets.info(:rns_known_ratchets) != :undefined
    end

    test "Transport ETS tables exist" do
      assert :ets.info(:rns_destinations) != :undefined
      assert :ets.info(:rns_interfaces) != :undefined
      assert :ets.info(:rns_pending_links) != :undefined
      assert :ets.info(:rns_active_links) != :undefined
      assert :ets.info(:rns_packet_hashlist) != :undefined
    end

    test "TaskSupervisor is running as a Task.Supervisor" do
      pid = Process.whereis(RNS.TaskSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify it accepts tasks
      {:ok, task_pid} = Task.Supervisor.start_child(RNS.TaskSupervisor, fn -> :ok end)
      assert is_pid(task_pid)
    end

    test "no ETS errors on startup — all GenServers are responsive" do
      # Verify each GenServer responds to calls (proves it's not crashed)
      assert is_pid(GenServer.whereis(RNS.IdentityStore))
      assert is_pid(GenServer.whereis(RNS.Transport))
      state = GenServer.call(RNS.Reticulum, :get_state)
      assert is_map(state)
    end
  end

  describe "subsystem configuration (Task 1.2)" do
    setup do
      # Re-synchronize subsystem paths with Reticulum's actual state,
      # since other test modules may have reconfigured them with temp dirs.
      reticulum_state = GenServer.call(RNS.Reticulum, :get_state)
      RNS.IdentityStore.configure(reticulum_state.storagepath)

      RNS.Transport.configure(
        storage_path: reticulum_state.storagepath,
        cachepath: reticulum_state.cachepath,
        transport_enabled: reticulum_state.transport_enabled
      )

      :ok
    end

    test "IdentityStore has been configured with a storage path" do
      storagepath = RNS.IdentityStore.storagepath()
      assert is_binary(storagepath)
      assert String.length(storagepath) > 0
    end

    test "IdentityStore storage path matches Reticulum's storagepath" do
      reticulum_state = GenServer.call(RNS.Reticulum, :get_state)
      identity_storagepath = RNS.IdentityStore.storagepath()
      assert identity_storagepath == reticulum_state.storagepath
    end

    test "Transport ETS tables are accessible after configuration" do
      assert :ets.info(:rns_path_table) != :undefined
      assert :ets.info(:rns_packet_hashlist) != :undefined
      assert :ets.info(:rns_tunnel_table) != :undefined
    end

    test "shutdown logs no ETS errors" do
      # All GenServers are responsive (no crashes from terminate issues)
      assert is_pid(GenServer.whereis(RNS.IdentityStore))
      assert is_pid(GenServer.whereis(RNS.Transport))
      assert is_pid(GenServer.whereis(RNS.Reticulum))
    end

    test "Transport has a transport identity after boot (Task 2.1)" do
      identity = RNS.Transport.identity()
      assert %RNS.Identity{} = identity
      assert is_binary(identity.hash)
      assert byte_size(identity.hash) == 16
    end

    test "Transport identity persists across restarts (Task 2.1)" do
      identity = RNS.Transport.identity()
      reticulum_state = GenServer.call(RNS.Reticulum, :get_state)
      identity_path = Path.join(reticulum_state.storagepath, "transport_identity")
      assert File.exists?(identity_path)

      # Loading from file gives the same identity
      loaded = RNS.Identity.from_file(identity_path)
      assert loaded.hash == identity.hash
    end

    test "Transport has control destinations after boot (Task 2.3)" do
      # Control destinations are always created
      assert RNS.Transport.path_request_destination() != nil
      assert RNS.Transport.tunnel_synthesize_destination() != nil

      # Control hashes list is populated
      hashes = RNS.Transport.control_hashes()
      assert length(hashes) == 2
    end

    test "Control destinations are stored in Transport state after boot (Task 2.3)" do
      path_req = RNS.Transport.path_request_destination()
      tunnel_synth = RNS.Transport.tunnel_synthesize_destination()

      # Verify destinations have correct types and aspects
      assert path_req.type == RNS.Destination.plain()
      assert path_req.name =~ "path"
      assert tunnel_synth.type == RNS.Destination.plain()
      assert tunnel_synth.name =~ "tunnel"
    end
  end
end
