defmodule RNS.Application do
  @moduledoc """
  OTP Application for the Reticulum Network Stack.

  Starts the supervision tree with DynamicSupervisors for interfaces,
  links, and resources. GenServer children (IdentityStore, Transport,
  Reticulum) are added in later phases.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.InterfaceSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.LinkSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.ResourceSupervisor}
    ]

    opts = [strategy: :one_for_one, name: RNS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
