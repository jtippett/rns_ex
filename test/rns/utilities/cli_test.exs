defmodule RNS.Utilities.CLITest do
  @moduledoc """
  Tests for the shared CLI startup module.

  Verifies that RNS.Utilities.CLI provides a unified startup path
  that replaces the per-utility ensure_application_started + start_reticulum
  pattern with proper Application environment configuration.
  """

  use ExUnit.Case, async: false

  alias RNS.Utilities.CLI

  # ── build_reticulum_opts/1 ──────────────────────────────────────────

  describe "build_reticulum_opts/1" do
    test "builds opts with logdest and configdir" do
      opts = CLI.build_reticulum_opts(logdest: :stdout, configdir: "/tmp/rns")
      assert Keyword.get(opts, :logdest) == :stdout
      assert Keyword.get(opts, :configdir) == "/tmp/rns"
    end

    test "strips nil values" do
      opts = CLI.build_reticulum_opts(logdest: :stdout, configdir: nil, verbosity: nil)
      assert Keyword.get(opts, :logdest) == :stdout
      refute Keyword.has_key?(opts, :configdir)
      refute Keyword.has_key?(opts, :verbosity)
    end

    test "includes verbosity when provided" do
      opts = CLI.build_reticulum_opts(logdest: :stdout, verbosity: 3)
      assert Keyword.get(opts, :verbosity) == 3
    end

    test "includes loglevel when provided" do
      opts = CLI.build_reticulum_opts(logdest: :stdout, loglevel: 5)
      assert Keyword.get(opts, :loglevel) == 5
    end

    test "empty opts returns empty list" do
      assert CLI.build_reticulum_opts([]) == []
    end
  end

  # ── ensure_started!/1 ──────────────────────────────────────────────

  describe "ensure_started!/1" do
    test "succeeds when application is already started" do
      # The app is started by test_helper.exs, so this should succeed
      assert :ok = CLI.ensure_started!()
    end

    test "Reticulum is running after ensure_started!" do
      CLI.ensure_started!()
      assert is_pid(GenServer.whereis(RNS.Reticulum))
    end

    test "Transport is running after ensure_started!" do
      CLI.ensure_started!()
      assert is_pid(GenServer.whereis(RNS.Transport))
    end

    test "IdentityStore is running after ensure_started!" do
      CLI.ensure_started!()
      assert is_pid(GenServer.whereis(RNS.IdentityStore))
    end

    test "accepts reticulum_opts via Application env" do
      # Store opts in app env before calling
      original = Application.get_env(:rns_ex, :reticulum_opts)
      Application.put_env(:rns_ex, :reticulum_opts, [logdest: :stdout])
      CLI.ensure_started!()
      assert is_pid(GenServer.whereis(RNS.Reticulum))
      # Restore
      if original, do: Application.put_env(:rns_ex, :reticulum_opts, original),
        else: Application.delete_env(:rns_ex, :reticulum_opts)
    end
  end

  # ── maybe_add_opt/3 ────────────────────────────────────────────────

  describe "maybe_add_opt/3" do
    test "adds non-nil value to keyword list" do
      result = CLI.maybe_add_opt([], :key, "value")
      assert Keyword.get(result, :key) == "value"
    end

    test "skips nil value" do
      result = CLI.maybe_add_opt([], :key, nil)
      assert result == []
    end

    test "adds to existing keyword list" do
      result = CLI.maybe_add_opt([existing: true], :key, "value")
      assert Keyword.get(result, :existing) == true
      assert Keyword.get(result, :key) == "value"
    end
  end

  # ── start_for_cli/1 ───────────────────────────────────────────────

  describe "start_for_cli/1" do
    test "sets Application env and starts app" do
      original = Application.get_env(:rns_ex, :reticulum_opts)
      result = CLI.start_for_cli(logdest: :stdout, configdir: nil)
      assert result == :ok
      assert is_pid(GenServer.whereis(RNS.Reticulum))
      # Restore
      if original, do: Application.put_env(:rns_ex, :reticulum_opts, original),
        else: Application.delete_env(:rns_ex, :reticulum_opts)
    end

    test "filters nil values before storing in Application env" do
      original = Application.get_env(:rns_ex, :reticulum_opts)
      CLI.start_for_cli(logdest: :stdout, configdir: nil, verbosity: nil)
      stored_opts = Application.get_env(:rns_ex, :reticulum_opts, [])
      refute Keyword.has_key?(stored_opts, :configdir)
      refute Keyword.has_key?(stored_opts, :verbosity)
      # Restore
      if original, do: Application.put_env(:rns_ex, :reticulum_opts, original),
        else: Application.delete_env(:rns_ex, :reticulum_opts)
    end
  end

  # ── No more ensure_application_started/0 in utilities ─────────────

  describe "utilities no longer have old startup helpers" do
    @utilities [
      RNS.Utilities.RNSD,
      RNS.Utilities.RNStatus,
      RNS.Utilities.RNPath,
      RNS.Utilities.RNProbe,
      RNS.Utilities.RNID,
      RNS.Utilities.RNCP,
      RNS.Utilities.RNX
    ]

    test "no utility exports ensure_application_started/0" do
      for mod <- @utilities do
        refute function_exported?(mod, :ensure_application_started, 0),
          "#{inspect(mod)} still exports ensure_application_started/0"
      end
    end

    test "no utility exports start_reticulum/1" do
      for mod <- @utilities do
        refute function_exported?(mod, :start_reticulum, 1),
          "#{inspect(mod)} still exports start_reticulum/1"
      end
    end
  end
end
