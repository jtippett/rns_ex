defmodule RNS.SupervisedTasksTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for Task 4.1: verifying that fire-and-forget callbacks use
  Task.Supervisor instead of raw Task.start or spawn.
  """

  setup do
    RNS.Test.SupervisedHelpers.clear_transport_tables()
    :ok
  end

  describe "RNS.TaskSupervisor" do
    test "is running after application boot" do
      pid = Process.whereis(RNS.TaskSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "can execute supervised tasks" do
      parent = self()

      {:ok, task_pid} =
        Task.Supervisor.start_child(RNS.TaskSupervisor, fn ->
          send(parent, {:task_ran, self()})
        end)

      assert is_pid(task_pid)
      assert_receive {:task_ran, ^task_pid}, 1000
    end

    test "task crashes are handled by the supervisor (not propagated)" do
      # A crashing task should not crash the supervisor
      supervisor_pid = Process.whereis(RNS.TaskSupervisor)

      {:ok, _task_pid} =
        Task.Supervisor.start_child(RNS.TaskSupervisor, fn ->
          raise "intentional crash for testing"
        end)

      # Give time for the crash to propagate
      Process.sleep(50)

      # Supervisor should still be alive
      assert Process.alive?(supervisor_pid)
    end

    test "is listed in the supervision tree" do
      children = Supervisor.which_children(RNS.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert RNS.TaskSupervisor in child_ids
    end
  end

  describe "TaskSupervisor is used for callbacks" do
    test "announce handler callbacks use Task.Supervisor (source verification)" do
      source = File.read!(Path.join([__DIR__, "..", "..", "lib", "rns", "transport.ex"]))

      # Count Task.Supervisor.start_child calls in the announce handler section
      supervised_calls =
        Regex.scan(~r/Task\.Supervisor\.start_child\(RNS\.TaskSupervisor/, source)
        |> length()

      # There should be at least 3 (for 3/4/5-arity callbacks)
      assert supervised_calls >= 3,
             "Expected at least 3 Task.Supervisor.start_child calls in transport.ex, found #{supervised_calls}"
    end

    test "TaskSupervisor-started tasks actually execute callbacks" do
      parent = self()

      {:ok, _pid} =
        Task.Supervisor.start_child(RNS.TaskSupervisor, fn ->
          # Simulate what an announce handler callback does
          send(parent, {:callback_executed, :announce_handler})
        end)

      assert_receive {:callback_executed, :announce_handler}, 1000
    end
  end

  describe "PacketReceipt timeout callback uses TaskSupervisor" do
    test "timeout callback runs under TaskSupervisor" do
      parent = self()

      receipt = %RNS.PacketReceipt{
        hash: :crypto.strong_rand_bytes(32),
        status: RNS.PacketReceipt.sent(),
        sent_at: System.system_time(:second) - 100,
        timeout: 1,
        callbacks: %{
          delivery: nil,
          timeout: fn _receipt -> send(parent, :timeout_fired) end
        }
      }

      _updated = RNS.PacketReceipt.check_timeout(receipt)

      assert_receive :timeout_fired, 1000
    end
  end

  describe "no raw spawn or Task.start in production code" do
    test "transport.ex has no raw Task.start calls" do
      source = File.read!(Path.join([__DIR__, "..", "..", "lib", "rns", "transport.ex"]))

      # Find Task.start( but not Task.Supervisor.start_child(
      raw_task_starts =
        Regex.scan(~r/Task\.start\(/, source)
        |> length()

      assert raw_task_starts == 0,
             "Found #{raw_task_starts} raw Task.start calls in transport.ex — should use Task.Supervisor.start_child"
    end

    test "packet_receipt.ex has no raw Task.start calls" do
      source = File.read!(Path.join([__DIR__, "..", "..", "lib", "rns", "packet_receipt.ex"]))

      raw_task_starts =
        Regex.scan(~r/Task\.start\(/, source)
        |> length()

      assert raw_task_starts == 0,
             "Found #{raw_task_starts} raw Task.start calls in packet_receipt.ex"
    end

    test "buffer.ex has no raw Task.start calls" do
      source = File.read!(Path.join([__DIR__, "..", "..", "lib", "rns", "buffer.ex"]))

      raw_task_starts =
        Regex.scan(~r/Task\.start\(/, source)
        |> length()

      assert raw_task_starts == 0,
             "Found #{raw_task_starts} raw Task.start calls in buffer.ex"
    end

    test "rncp.ex has no raw spawn calls" do
      source = File.read!(Path.join([__DIR__, "..", "..", "lib", "rns", "utilities", "rncp.ex"]))

      # Match spawn( but not Port.open({:spawn or schedule_respawn
      raw_spawns =
        Regex.scan(~r/(?<!\{:)(?<!schedule_re)\bspawn\(fn/, source)
        |> length()

      assert raw_spawns == 0,
             "Found #{raw_spawns} raw spawn(fn calls in rncp.ex"
    end

    test "no raw spawn(fn in any lib/rns/ file" do
      lib_path = Path.join([__DIR__, "..", "..", "lib", "rns"])

      raw_spawns =
        Path.wildcard(Path.join(lib_path, "**/*.ex"))
        |> Enum.flat_map(fn file ->
          source = File.read!(file)

          # Match spawn(fn but not Port.open({:spawn or schedule_respawn
          case Regex.scan(~r/(?<!\{:)(?<!schedule_re)\bspawn\(fn/, source) do
            [] -> []
            matches -> [{file, length(matches)}]
          end
        end)

      assert raw_spawns == [],
             "Found raw spawn(fn calls in: #{inspect(raw_spawns)}"
    end

    test "no raw Task.start( in any lib/rns/ file" do
      lib_path = Path.join([__DIR__, "..", "..", "lib", "rns"])

      raw_starts =
        Path.wildcard(Path.join(lib_path, "**/*.ex"))
        |> Enum.flat_map(fn file ->
          source = File.read!(file)

          case Regex.scan(~r/(?<!\.)Task\.start\(/, source) do
            [] -> []
            matches -> [{file, length(matches)}]
          end
        end)

      assert raw_starts == [],
             "Found raw Task.start calls in: #{inspect(raw_starts)}"
    end
  end
end
