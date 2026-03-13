defmodule RNS.Utilities.RNPKGTest do
  @moduledoc """
  Tests for the RNPKG (Reticulum Meta Package Manager) utility.

  Verifies argument parsing, version output, example config, and program
  setup match the Python rnpkg utility's behavior.
  """

  use ExUnit.Case, async: false

  alias RNS.Utilities.RNPKG

  # ── parse_args/1 ──────────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses empty args with defaults" do
      assert {:ok, opts} = RNPKG.parse_args([])
      assert opts.configdir == nil
      assert opts.verbosity == 0
      assert opts.quietness == 0
      assert opts.exampleconfig == false
      assert opts.version == false
    end

    test "parses --config option" do
      assert {:ok, opts} = RNPKG.parse_args(["--config", "/tmp/rns"])
      assert opts.configdir == "/tmp/rns"
    end

    test "parses verbose flags" do
      assert {:ok, opts} = RNPKG.parse_args(["-v", "-v"])
      assert opts.verbosity == 2
    end

    test "parses quiet flags" do
      assert {:ok, opts} = RNPKG.parse_args(["-q", "-q", "-q"])
      assert opts.quietness == 3
    end

    test "parses --version flag" do
      assert {:ok, opts} = RNPKG.parse_args(["--version"])
      assert opts.version == true
    end

    test "parses --exampleconfig flag" do
      assert {:ok, opts} = RNPKG.parse_args(["--exampleconfig"])
      assert opts.exampleconfig == true
    end

    test "returns error for unknown options" do
      assert {:error, msg} = RNPKG.parse_args(["--bogus"])
      assert msg =~ "unknown option"
    end

    test "returns error for unexpected arguments" do
      assert {:error, msg} = RNPKG.parse_args(["unexpected"])
      assert msg =~ "unexpected argument"
    end

    test "mixed verbose and quiet flags" do
      assert {:ok, opts} = RNPKG.parse_args(["-v", "-v", "-q"])
      assert opts.verbosity == 2
      assert opts.quietness == 1
    end
  end

  # ── example_rnpkg_config/0 ───────────────────────────────────────

  describe "example_rnpkg_config/0" do
    test "returns a non-empty config string" do
      config = RNPKG.example_rnpkg_config()
      assert is_binary(config)
      assert String.contains?(config, "example package manager configuration")
    end
  end

  # ── program_setup/1 ──────────────────────────────────────────────

  describe "program_setup/1" do
    test "starts the RNS application and returns :ok" do
      opts = %{configdir: nil, verbosity: 0, quietness: 0}
      assert :ok = RNPKG.program_setup(opts)
      assert is_pid(GenServer.whereis(RNS.Reticulum))
    end
  end

  # ── no old startup helpers ───────────────────────────────────────

  describe "no old startup helpers" do
    test "does not export ensure_application_started/0" do
      refute function_exported?(RNPKG, :ensure_application_started, 0)
    end

    test "does not export start_reticulum/1" do
      refute function_exported?(RNPKG, :start_reticulum, 1)
    end
  end
end
