defmodule RNS.Application do
  @moduledoc """
  OTP Application for the Reticulum Network Stack.

  Starts the supervision tree with :rest_for_one strategy:
    1. IdentityStore — ETS-backed known destinations (no dependencies)
    2. Transport — routing tables, ETS (reads from IdentityStore)
    3. InterfaceSupervisor — DynamicSupervisor for network interfaces
    4. LinkSupervisor — DynamicSupervisor for active links
    5. ResourceSupervisor — DynamicSupervisor for resource transfers
    6. Reticulum — config, interface lifecycle, coordinator (last — depends on all above)

  With :rest_for_one, if IdentityStore crashes, everything below restarts.
  If Transport crashes, DynamicSupervisors and Reticulum restart.
  If Reticulum crashes, only Reticulum restarts.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # CLI utilities store Reticulum opts in Application env before starting
    reticulum_opts = Application.get_env(:rns_ex, :reticulum_opts, [])

    children = [
      RNS.IdentityStore,
      RNS.Transport,
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.InterfaceSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.LinkSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.ResourceSupervisor},
      {RNS.Reticulum, reticulum_opts}
    ]

    opts = [strategy: :rest_for_one, name: RNS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
