defmodule RNS.Application do
  @moduledoc """
  OTP Application for the Reticulum Network Stack.

  Starts the supervision tree with :rest_for_one strategy:
    1. Transport.Registry — Registry for pub/sub event subscriptions
    2. IdentityStore — ETS-backed known destinations (no dependencies)
    3. Transport — routing tables, ETS (reads from IdentityStore)
    4. InterfaceSupervisor — DynamicSupervisor for network interfaces
    5. LinkSupervisor — DynamicSupervisor for active links
    6. ResourceSupervisor — DynamicSupervisor for resource transfers
    7. TaskSupervisor — Task.Supervisor for fire-and-forget callbacks
    8. Reticulum — config, interface lifecycle, coordinator (last — depends on all above)

  With :rest_for_one, if IdentityStore crashes, everything below restarts.
  If Transport crashes, DynamicSupervisors and Reticulum restart.
  If Reticulum crashes, only Reticulum restarts.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # CLI utilities store Reticulum opts in Application env before starting
    reticulum_opts = Application.get_env(:rns_ex, :reticulum_opts, [])

    # Library consumers can set `config :rns_ex, start_network: false` to prevent
    # automatic network startup. This is useful when only crypto/identity/packet
    # functionality is needed, without starting interfaces or connecting to peers.
    start_network = Application.get_env(:rns_ex, :start_network, true)

    reticulum_opts =
      if start_network do
        reticulum_opts
      else
        Keyword.put(reticulum_opts, :skip_start, true)
      end

    children = [
      {Registry, keys: :duplicate, name: RNS.Transport.Registry},
      RNS.IdentityStore,
      RNS.Transport,
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.InterfaceSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.LinkSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: RNS.ResourceSupervisor},
      {Task.Supervisor, name: RNS.TaskSupervisor},
      {RNS.Reticulum, reticulum_opts}
    ]

    opts = [strategy: :rest_for_one, name: RNS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
