defmodule RNS.Interfaces.AutoInterfacePeer do
  @moduledoc """
  Spawned peer interface for AutoInterface.

  Each discovered peer gets an AutoInterfacePeer that handles
  unicast UDP data exchange.

  Matches `AutoInterfacePeer` class in `python/RNS/Interfaces/AutoInterface.py`.
  """

  use RNS.Interfaces.Interface

  require Logger

  defstruct default_fields() ++
              [
                addr: nil,
                ifname: nil,
                peer_addr: nil,
                addr_info: nil,
                owner_pid: nil
              ]

  @type t :: %__MODULE__{}

  @impl RNS.Interfaces.Interface
  def process_outgoing(_state, _data), do: {:ok, nil}

  @impl RNS.Interfaces.Interface
  def process_incoming(_state, _data), do: {:ok, nil}

  @impl RNS.Interfaces.Interface
  def detach(%__MODULE__{} = state) do
    Logger.info("The interface #{state} is being torn down.")
    :ok
  end

  def detach(_state), do: :ok

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{ifname: ifname, addr: addr}) do
      "AutoInterfacePeer[#{ifname}/#{addr}]"
    end
  end
end
