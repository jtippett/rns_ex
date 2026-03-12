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

    test "InterfaceSupervisor is running as a DynamicSupervisor" do
      pid = Process.whereis(RNS.InterfaceSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
      assert DynamicSupervisor.count_children(RNS.InterfaceSupervisor) == %{
               active: 0,
               specs: 0,
               supervisors: 0,
               workers: 0
             }
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

    test "supervisor has exactly 3 children" do
      counts = Supervisor.count_children(RNS.Supervisor)
      assert counts[:active] == 3
    end

    test "all three DynamicSupervisors are children of the top-level supervisor" do
      children = Supervisor.which_children(RNS.Supervisor)
      child_pids = Enum.map(children, fn {_, pid, _, _} -> pid end)

      assert Process.whereis(RNS.InterfaceSupervisor) in child_pids
      assert Process.whereis(RNS.LinkSupervisor) in child_pids
      assert Process.whereis(RNS.ResourceSupervisor) in child_pids
    end
  end
end
