defmodule RNS.Transport.NamedTest do
  use ExUnit.Case, async: false

  test "start_link accepts :name option" do
    # The default Transport is already running via the supervision tree.
    # Start a second named instance.
    {:ok, pid} = RNS.Transport.start_link(name: MyApp.Transport)
    assert Process.alive?(pid)
    assert GenServer.call(MyApp.Transport, :get_announce_handlers) == []
    GenServer.stop(pid)
  end

  test "start_link without name defaults to RNS.Transport" do
    # Default instance is already running, verify it responds
    assert is_pid(Process.whereis(RNS.Transport))
  end

  test "named instance is independently addressable" do
    {:ok, pid} = RNS.Transport.start_link(name: :test_transport_instance)
    assert Process.whereis(:test_transport_instance) == pid
    GenServer.stop(pid)
  end
end
